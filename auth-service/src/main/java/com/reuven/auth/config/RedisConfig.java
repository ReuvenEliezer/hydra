package com.reuven.auth.config;

import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.data.redis.connection.RedisConnectionFactory;
import org.springframework.data.redis.core.StringRedisTemplate;

@Configuration
public class RedisConfig {

    /**
     * StringRedisTemplate (not the generic RedisTemplate) is exactly the right tool
     * here: every refresh-token key/value RefreshTokenService writes (or its Lua
     * scripts write) is already a plain UTF-8 string (token hashes, delimited
     * status-tagged slot values, UUIDs) - no object serialization, no extra
     * Jackson coupling.
     */
    @Bean
    public StringRedisTemplate stringRedisTemplate(RedisConnectionFactory connectionFactory) {
        return new StringRedisTemplate(connectionFactory);
    }
}
