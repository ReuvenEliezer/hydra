-- refresh_rotate.lua
--
-- Atomically validates and rotates a presented refresh token. This entire
-- operation - claim old token, mint new one, update the family pointer, open
-- the replay grace window, tombstone the old slot - happens as a single Redis
-- Lua script. Redis executes scripts to completion before processing anything
-- else, so there is no interleaving between concurrent rotate calls and no
-- window in which a crash could leave the token store half-migrated: either
-- every write below lands, or (on a mid-script crash before commit) none of
-- them do.
--
-- Token slot values (KEYS[1]/KEYS[2]) are one of:
--   'A'<SEP>userId<SEP>tenantId<SEP>familyId<SEP>rolesCsv   (active)
--   'R'<SEP>familyId                                        (rotated tombstone,
--                                                             kept for reuse detection)
--
-- The grace pointer's value carries familyId alongside the raw token
-- (familyId<SEP>newRawToken) so that ANY caller replaying a rotation - even
-- one whose own candidate new-hash guess is irrelevant - can resolve the
-- *actual* winning token via the family pointer, rather than via its own
-- (potentially wrong/discarded) KEYS[2]. KEYS[2]/ARGV[1]/ARGV[2] are only
-- ever written to if THIS call turns out to be the winner.
--
-- GETDEL is the race-prevention primitive: whichever concurrent caller's script
-- invocation actually runs first is the only one that can observe status 'A'
-- and atomically clear it in the same command. Every other caller - genuinely
-- concurrent (e.g. two browser tabs) or a delayed retry - finds the slot
-- already gone or already a tombstone and falls deterministically into the
-- grace-replay or reuse path below. There is no code path in which two callers
-- both observe 'A'.
--
-- KEYS[1] = rt:tok:{oldHash}     token slot for the presented token
-- KEYS[2] = rt:tok:{newHash}     token slot for the candidate replacement token
-- KEYS[3] = rt:grace:{oldHash}   grace-replay pointer
--
-- ARGV[1] = newHash              hash of the candidate replacement token
-- ARGV[2] = newRawToken          the candidate replacement token itself (pre-generated
--                                 by the caller; only consumed if this call wins the race)
-- ARGV[3] = ttlMillis             refresh-token TTL, in milliseconds
-- ARGV[4] = graceTtlMillis        grace-window TTL, in milliseconds
--
-- Returns one SEP-joined string, first field is the outcome tag:
--   'ROTATED'<SEP>userId<SEP>tenantId<SEP>rolesCsv<SEP>newRawToken
--   'REPLAY' <SEP>userId<SEP>tenantId<SEP>rolesCsv<SEP>newRawToken   (idempotent replay)
--   'REUSE'  <SEP>familyId                                          (family was just revoked)
--   'INVALID'

local SEP = string.char(1)

local function split(str)
    local out = {}
    local start = 1
    while true do
        local i = string.find(str, SEP, start, true)
        if not i then
            table.insert(out, string.sub(str, start))
            break
        end
        table.insert(out, string.sub(str, start, i - 1))
        start = i + 1
    end
    return out
end

-- Resolves a replay purely from the grace pointer's own payload - never from
-- the replaying caller's KEYS[2], which may be a candidate hash that was
-- never actually written (discarded because this call lost the race).
local function replayFrom(graceVal)
    local gp = split(graceVal)
    local familyId, newRawToken = gp[1], gp[2]

    local familyKey = 'rt:family:' .. familyId
    local activeHash = redis.call('GET', familyKey)
    if not activeHash then
        -- Concurrent full revoke (logout / reuse-elsewhere / admin bulk revoke)
        -- landed between rotation and this replay. Conservatively invalid.
        return 'INVALID'
    end

    local newMetaRaw = redis.call('GET', 'rt:tok:' .. activeHash)
    if not newMetaRaw then
        return 'INVALID'
    end

    local np = split(newMetaRaw) -- {status, userId, tenantId, familyId, rolesCsv}
    return 'REPLAY' .. SEP .. np[2] .. SEP .. np[3] .. SEP .. np[5] .. SEP .. newRawToken
end

local ttlRemaining = redis.call('PTTL', KEYS[1])
local val = redis.call('GETDEL', KEYS[1])

if val then
    local parts = split(val)
    local status = parts[1]

    if status == 'A' then
        -- Winner: this is the one and only caller that gets to rotate.
        local userId, tenantId, familyId, rolesCsv = parts[2], parts[3], parts[4], parts[5]
        local familyKey = 'rt:family:' .. familyId
        local newValue = 'A' .. SEP .. userId .. SEP .. tenantId .. SEP .. familyId .. SEP .. rolesCsv
        local graceValue = familyId .. SEP .. ARGV[2]

        redis.call('SET', KEYS[2], newValue, 'PX', ARGV[3])
        redis.call('SET', familyKey, ARGV[1], 'PX', ARGV[3])
        redis.call('SET', KEYS[3], graceValue, 'PX', ARGV[4])
        -- Tombstone the old slot (instead of leaving it deleted) so a reuse
        -- attempt after the grace window closes can still be detected and
        -- traced back to its family.
        redis.call('SET', KEYS[1], 'R' .. SEP .. familyId, 'PX', ARGV[3])

        return 'ROTATED' .. SEP .. userId .. SEP .. tenantId .. SEP .. rolesCsv .. SEP .. ARGV[2]
    end

    if status == 'R' then
        -- This caller's GETDEL just claimed a tombstone that the true winner
        -- already wrote - i.e. this is a second (or third...) concurrent
        -- caller arriving after rotation already happened.
        local familyId = parts[2]
        local graceVal = redis.call('GET', KEYS[3])

        if graceVal then
            -- Still within the grace window: restore the tombstone we just
            -- consumed (preserving its remaining TTL) so any further
            -- concurrent replay can still find it, then hand back the exact
            -- same token pair the winner already minted.
            if ttlRemaining and ttlRemaining > 0 then
                redis.call('SET', KEYS[1], val, 'PX', ttlRemaining)
            end
            return replayFrom(graceVal)
        end

        -- Grace window has closed: a token that was legitimately rotated away
        -- is being presented again. That is reuse - revoke the whole family.
        local familyKey = 'rt:family:' .. familyId
        local activeHash = redis.call('GET', familyKey)
        if activeHash then
            redis.call('DEL', 'rt:tok:' .. activeHash)
            redis.call('DEL', familyKey)
        end
        return 'REUSE' .. SEP .. familyId
    end

    return 'INVALID'
end

-- Nothing under the old hash at all. Could still be a legitimate replay if the
-- tombstone above was already claimed and restored by an earlier concurrent
-- call, then consumed again here - grace pointer is the source of truth for
-- replay regardless of tombstone state, since GET (not GETDEL) never destroys it.
local graceVal = redis.call('GET', KEYS[3])
if graceVal then
    return replayFrom(graceVal)
end

return 'INVALID'
