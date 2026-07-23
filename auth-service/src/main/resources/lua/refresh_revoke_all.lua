-- refresh_revoke_all.lua
--
-- Administrative "log out everywhere": revokes every session/family belonging
-- to a user. Bounded by the number of concurrent sessions the user actually
-- has (rt:user:{userId} is a session index, not a token-history index - it
-- was never part of the unbounded-growth problem the token/family redesign
-- solves), so an O(sessions) loop here is the right and only reasonable shape.
--
-- KEYS[1] = rt:user:{userId}
--
-- Returns the number of families revoked, as a string.

local familyIds = redis.call('SMEMBERS', KEYS[1])
local count = 0

for _, familyId in ipairs(familyIds) do
    local familyKey = 'rt:family:' .. familyId
    local activeHash = redis.call('GET', familyKey)
    if activeHash then
        redis.call('DEL', 'rt:tok:' .. activeHash)
        count = count + 1
    end
    redis.call('DEL', familyKey)
end

redis.call('DEL', KEYS[1])

return tostring(count)
