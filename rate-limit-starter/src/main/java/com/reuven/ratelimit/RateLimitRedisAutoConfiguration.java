package com.reuven.ratelimit;

import io.github.bucket4j.distributed.ExpirationAfterWriteStrategy;
import io.github.bucket4j.distributed.proxy.ProxyManager;
import io.github.bucket4j.redis.lettuce.cas.LettuceBasedProxyManager;
import io.lettuce.core.RedisClient;
import io.lettuce.core.api.StatefulRedisConnection;
import io.lettuce.core.codec.ByteArrayCodec;
import org.springframework.boot.autoconfigure.AutoConfiguration;
import org.springframework.boot.autoconfigure.condition.ConditionalOnBean;
import org.springframework.boot.autoconfigure.condition.ConditionalOnMissingBean;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.boot.data.redis.autoconfigure.DataRedisAutoConfiguration;
import org.springframework.context.annotation.Bean;
import org.springframework.data.redis.connection.RedisConnectionFactory;
import org.springframework.data.redis.connection.lettuce.LettuceConnectionFactory;

import java.time.Duration;
import java.util.Objects;

/**
 * Wires the Redis-backed {@link ProxyManager} that {@link Bucket4jRateLimiterEngine}
 * consumes. Split out from the engine itself so the engine stays a plain
 * {@code @Service} with a constructor-injected {@code ProxyManager<byte[]>} - easy to
 * unit test against an in-memory/embedded one without dragging Lettuce connection
 * lifecycle into the test. Imported unconditionally by {@link RateLimitAutoConfiguration};
 * this class carries its own {@code @ConditionalOnBean(RedisConnectionFactory.class)} so
 * a service with no Redis on the classpath (order-service, today) never has this
 * config's {@code @Bean} methods invoked at all, rather than failing at startup on a
 * missing {@code RedisConnectionFactory} parameter.
 */
@AutoConfiguration(after = DataRedisAutoConfiguration.class)
@ConditionalOnBean(RedisConnectionFactory.class)
@ConditionalOnProperty(
        prefix = "rate-limit",
        name = "enabled",
        havingValue = "true",
        matchIfMissing = true
)
public class RateLimitRedisAutoConfiguration {

    /**
     * Owned separately from {@link #rateLimitProxyManager}, and with an explicit
     * {@code destroyMethod}, because {@code LettuceBasedProxyManager} does not take
     * ownership of a connection it didn't open itself - per bucket4j-redis's contract,
     * the caller that creates the connection is responsible for closing it. Without
     * this as its own bean, the connection opened here would leak on every context
     * shutdown/restart (e.g. once per test class in the integration suite).
     */
    @Bean(destroyMethod = "close")
    @ConditionalOnMissingBean(StatefulRedisConnection.class)
    public StatefulRedisConnection<byte[], byte[]> rateLimitRedisConnection(RedisConnectionFactory connectionFactory) {
        if (!(connectionFactory instanceof LettuceConnectionFactory lettuceConnectionFactory)) {
            throw new IllegalStateException(
                    "Rate limiting requires the Lettuce Redis driver (spring-boot-starter-data-redis's default); "
                            + "got " + connectionFactory.getClass().getName());
        }

        RedisClient redisClient = (RedisClient) lettuceConnectionFactory.getNativeClient();
        Objects.requireNonNull(redisClient, "Lettuce NativeClient must not be null");

        return redisClient.connect(ByteArrayCodec.INSTANCE);
    }

    @Bean
    @ConditionalOnMissingBean(ProxyManager.class)
    public ProxyManager<byte[]> rateLimitProxyManager(StatefulRedisConnection<byte[], byte[]> rateLimitRedisConnection) {
        return LettuceBasedProxyManager.builderFor(rateLimitRedisConnection)
                .withExpirationStrategy(ExpirationAfterWriteStrategy.basedOnTimeForRefillingBucketUpToMax(Duration.ofMinutes(10)))
                .build();
    }
}