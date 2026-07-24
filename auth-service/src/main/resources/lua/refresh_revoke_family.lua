-- refresh_revoke_family.lua
--
-- Revokes the family that a presented token (active or already-rotated)
-- belongs to. O(1): the family key is a single pointer to the current active
-- hash, not a set of every hash the family ever had, so revocation is exactly
-- two deletes plus the presented slot's own delete - no unbounded fan-out.
--
-- KEYS[1] = rt:tok:{hash}   token slot for the presented token
--
-- Returns '1' if a family was found and revoked, '0' if the presented hash is
-- unknown (silent no-op - logout on an already-invalid token is not an error).

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

local val = redis.call('GET', KEYS[1])
if not val then
    return '0'
end

local parts = split(val)
-- Active:    {'A', userId, tenantId, familyId, rolesCsv}
-- Tombstone: {'R', familyId}
local familyId = (parts[1] == 'A') and parts[4] or parts[2]

local familyKey = 'rt:family:' .. familyId
local activeHash = redis.call('GET', familyKey)
if activeHash then
    redis.call('DEL', 'rt:tok:' .. activeHash)
end
redis.call('DEL', familyKey)
redis.call('DEL', KEYS[1])

return '1'
