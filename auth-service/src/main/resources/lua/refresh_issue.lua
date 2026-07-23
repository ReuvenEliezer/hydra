-- refresh_issue.lua
--
-- Issues a brand-new refresh token family at login. Single atomic round trip
-- instead of four sequential Java-side calls (SET active, SADD+EXPIRE family,
-- SADD+EXPIRE user) - either the whole session is created, or none of it is.
--
-- KEYS[1] = rt:tok:{hash}        token slot (status-tagged)
-- KEYS[2] = rt:family:{familyId} pointer to the current active hash
-- KEYS[3] = rt:user:{userId}     set of familyIds belonging to this user (session index)
--
-- ARGV[1] = userId
-- ARGV[2] = tenantId
-- ARGV[3] = familyId
-- ARGV[4] = rolesCsv
-- ARGV[5] = hash (of the newly issued raw token)
-- ARGV[6] = ttlMillis (refresh-token TTL, in milliseconds)

local SEP = string.char(1)

local value = 'A' .. SEP .. ARGV[1] .. SEP .. ARGV[2] .. SEP .. ARGV[3] .. SEP .. ARGV[4]

redis.call('SET', KEYS[1], value, 'PX', ARGV[6])
redis.call('SET', KEYS[2], ARGV[5], 'PX', ARGV[6])
redis.call('SADD', KEYS[3], ARGV[3])
redis.call('PEXPIRE', KEYS[3], ARGV[6])

return 'OK'
