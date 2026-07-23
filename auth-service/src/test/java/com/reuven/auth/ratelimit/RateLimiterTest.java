package com.reuven.auth.ratelimit;

import io.github.bucket4j.distributed.proxy.ProxyManager;
import io.github.bucket4j.redis.lettuce.cas.LettuceBasedProxyManager;
import io.lettuce.core.RedisClient;
import io.lettuce.core.api.StatefulRedisConnection;
import io.lettuce.core.codec.ByteArrayCodec;
import io.micrometer.core.instrument.simple.SimpleMeterRegistry;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.testcontainers.containers.GenericContainer;
import org.testcontainers.junit.jupiter.Container;
import org.testcontainers.junit.jupiter.Testcontainers;
import org.testcontainers.utility.DockerImageName;

import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.util.List;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.TimeUnit;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatCode;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.assertj.core.api.Assertions.catchThrowableOfType;

/**
 * Exercises {@link RateLimiter} directly against a real redis:7.4-alpine container - no
 * Spring context, mirroring RefreshTokenServiceTest's approach for the same reasons
 * (fast, and proves the actual atomic Redis behavior rather than a mock's assumptions
 * about it).
 */
@Testcontainers
class RateLimiterTest {

    @Container
    static GenericContainer<?> redis = new GenericContainer<>(DockerImageName.parse("redis:7.4-alpine"))
            .withExposedPorts(6379);

    private static RedisClient redisClient;
    private static StatefulRedisConnection<byte[], byte[]> connection;
    private static ProxyManager<byte[]> proxyManager;

    private SimpleMeterRegistry meterRegistry;
    private RateLimiter rateLimiter;

    @BeforeEach
    void setUp() {
        if (redisClient == null) {
            String uri = "redis://" + redis.getHost() + ":" + redis.getMappedPort(6379);
            redisClient = RedisClient.create(uri);
            connection = redisClient.connect(ByteArrayCodec.INSTANCE);
            proxyManager = LettuceBasedProxyManager.builderFor(connection).build();
        }
        meterRegistry = new SimpleMeterRegistry();
        RateLimitProperties properties = new RateLimitProperties(
                true,
                new RateLimitProperties.Login(
                        new RateLimitProperties.Limit(3, Duration.ofMinutes(1)),
                        new RateLimitProperties.Limit(3, Duration.ofMinutes(1))),
                new RateLimitProperties.Refresh(
                        new RateLimitProperties.Limit(3, Duration.ofMinutes(1)),
                        new RateLimitProperties.Limit(3, Duration.ofMinutes(1))));
        rateLimiter = new RateLimiter(proxyManager, properties, meterRegistry);
    }

    @AfterEach
    void flushRedis() {
        connection.sync().flushall();
    }

    @AfterAll
    static void closeConnection() {
        if (connection != null) connection.close();
        if (redisClient != null) redisClient.shutdown();
    }

    @Test
    @DisplayName("allows up to capacity, then rejects with a positive retry-after")
    void allowsUpToCapacityThenRejects() {
        assertThatCode(() -> rateLimiter.checkLoginIp("1.2.3.4")).doesNotThrowAnyException();
        assertThatCode(() -> rateLimiter.checkLoginIp("1.2.3.4")).doesNotThrowAnyException();
        assertThatCode(() -> rateLimiter.checkLoginIp("1.2.3.4")).doesNotThrowAnyException();

        RateLimitExceededException ex = catchThrowableOfType(
                RateLimitExceededException.class, () -> rateLimiter.checkLoginIp("1.2.3.4"));

        assertThat(ex).isNotNull();
        assertThat(ex.retryAfter()).isPositive();
    }

    @Test
    @DisplayName("per-IP and per-username limits are independent - exhausting one doesn't affect the other")
    void perIpAndPerUsernameAreIndependent() {
        for (int i = 0; i < 3; i++) {
            rateLimiter.checkLoginIp("9.9.9.9");
        }
        assertThatThrownBy(() -> rateLimiter.checkLoginIp("9.9.9.9")).isInstanceOf(RateLimitExceededException.class);

        // A different username from the SAME now-exhausted IP dimension must still pass,
        // since checkLoginUsername consults an entirely separate bucket/key.
        assertThatCode(() -> rateLimiter.checkLoginUsername("someone-else"))
                .doesNotThrowAnyException();
    }

    @Test
    @DisplayName("different identifiers within the same dimension do not affect each other")
    void differentIdentifiersAreIsolated() {
        for (int i = 0; i < 3; i++) {
            rateLimiter.checkLoginUsername("alice");
        }
        assertThatThrownBy(() -> rateLimiter.checkLoginUsername("alice")).isInstanceOf(RateLimitExceededException.class);

        // "bob" has never been charged - must have his full budget.
        assertThatCode(() -> rateLimiter.checkLoginUsername("bob")).doesNotThrowAnyException();
    }

    @Test
    @DisplayName("refresh token identity is hashed, not stored as the literal raw token")
    void refreshTokenIsHashedNotStoredRaw() {
        String rawToken = "super-secret-raw-refresh-token-value";
        rateLimiter.checkRefreshToken(rawToken);

        List<byte[]> keys = connection.sync().keys("*");
        List<String> keyStrings = keys.stream().map(String::new).toList();

        assertThat(keyStrings).anyMatch(k -> k.startsWith("ratelimit:refresh:token:"));
        assertThat(keyStrings).noneMatch(k -> k.contains(rawToken));
    }

    @Test
    @DisplayName("disabled flag bypasses enforcement entirely, even far beyond capacity")
    void disabledBypassesEnforcement() {
        RateLimitProperties disabled = new RateLimitProperties(
                false,
                new RateLimitProperties.Login(
                        new RateLimitProperties.Limit(1, Duration.ofMinutes(1)),
                        new RateLimitProperties.Limit(1, Duration.ofMinutes(1))),
                new RateLimitProperties.Refresh(
                        new RateLimitProperties.Limit(1, Duration.ofMinutes(1)),
                        new RateLimitProperties.Limit(1, Duration.ofMinutes(1))));
        RateLimiter disabledLimiter = new RateLimiter(proxyManager, disabled, meterRegistry);

        assertThatCode(() -> {
            for (int i = 0; i < 20; i++) {
                disabledLimiter.checkLoginIp("irrelevant-when-disabled");
            }
        }).doesNotThrowAnyException();
    }

    @Test
    @DisplayName("metrics: allowed/rejected counters increment correctly")
    void metricsAreRecorded() {
        rateLimiter.checkLoginIp("5.5.5.5");
        rateLimiter.checkLoginIp("5.5.5.5");
        rateLimiter.checkLoginIp("5.5.5.5");
        try {
            rateLimiter.checkLoginIp("5.5.5.5");
        } catch (RateLimitExceededException ignored) {
            // expected on the 4th call
        }

        double allowed = meterRegistry.counter("auth.ratelimit.allowed", "endpoint", "login", "dimension", "ip").count();
        double rejected = meterRegistry.counter("auth.ratelimit.rejected", "endpoint", "login", "dimension", "ip").count();

        assertThat(allowed).isEqualTo(3.0);
        assertThat(rejected).isEqualTo(1.0);
    }

    @Test
    @DisplayName("20 threads racing the same key: exactly capacity succeed, the rest are rejected - no race condition")
    void concurrentRequestsToSameKey_exactlyCapacitySucceed() throws InterruptedException {
        int threadCount = 20;
        int capacity = 3;
        ExecutorService pool = Executors.newFixedThreadPool(threadCount);
        List<Future<Boolean>> futures = new java.util.ArrayList<>();

        for (int i = 0; i < threadCount; i++) {
            futures.add(pool.submit(() -> {
                try {
                    rateLimiter.checkLoginIp("race-condition-target-ip");
                    return true;
                } catch (RateLimitExceededException e) {
                    return false;
                }
            }));
        }

        pool.shutdown();
        assertThat(pool.awaitTermination(30, TimeUnit.SECONDS)).isTrue();

        long succeeded = futures.stream().map(f -> {
            try {
                return f.get();
            } catch (Exception e) {
                throw new RuntimeException(e);
            }
        }).filter(Boolean::booleanValue).count();

        assertThat(succeeded)
                .as("exactly the configured capacity must succeed, regardless of thread interleaving")
                .isEqualTo(capacity);
    }
}
