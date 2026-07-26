package com.reuven.ratelimit;

import com.redis.testcontainers.RedisContainer;
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
import org.testcontainers.junit.jupiter.Container;
import org.testcontainers.junit.jupiter.Testcontainers;

import java.time.Duration;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.TimeUnit;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatCode;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.assertj.core.api.Assertions.catchThrowableOfType;

/**
 * Exercises {@link Bucket4jRateLimiterEngine} directly against a real Redis container -
 * no Spring context, proving the actual atomic Redis behavior rather than a mock's
 * assumptions about it. Lives here (not in a consuming service) since this is the
 * engine's own contract, independent of who calls it.
 */
@Testcontainers
class Bucket4jRateLimiterEngineTest {

    private static final RateLimitProperties.Limit CAPACITY_3 =
            new RateLimitProperties.Limit(3, Duration.ofMinutes(1));

    @Container
    static RedisContainer redis = new RedisContainer("redis:8.8-alpine").withReuse(true);

    private static RedisClient redisClient;
    private static StatefulRedisConnection<byte[], byte[]> connection;
    private static ProxyManager<byte[]> proxyManager;

    private SimpleMeterRegistry meterRegistry;
    private Bucket4jRateLimiterEngine engine;

    @BeforeEach
    void setUp() {
        if (redisClient == null) {
            redisClient = RedisClient.create(redis.getRedisURI());
            connection = redisClient.connect(ByteArrayCodec.INSTANCE);
            proxyManager = LettuceBasedProxyManager.builderFor(connection).build();
        }
        meterRegistry = new SimpleMeterRegistry();
        RateLimitProperties properties = new RateLimitProperties(
                true, false,
                Map.of(
                        "login-ip", CAPACITY_3,
                        "login-username", CAPACITY_3,
                        "refresh-ip", CAPACITY_3,
                        "refresh-token", CAPACITY_3));
        engine = new Bucket4jRateLimiterEngine(proxyManager, properties, meterRegistry);
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
        assertThatCode(() -> engine.consume("login-ip", "1.2.3.4")).doesNotThrowAnyException();
        assertThatCode(() -> engine.consume("login-ip", "1.2.3.4")).doesNotThrowAnyException();
        assertThatCode(() -> engine.consume("login-ip", "1.2.3.4")).doesNotThrowAnyException();

        RateLimitExceededException ex = catchThrowableOfType(
                RateLimitExceededException.class, () -> engine.consume("login-ip", "1.2.3.4"));

        assertThat(ex).isNotNull();
        assertThat(ex.retryAfter()).isPositive();
    }

    @Test
    @DisplayName("per-IP and per-username limits are independent - exhausting one doesn't affect the other")
    void perIpAndPerUsernameAreIndependent() {
        for (int i = 0; i < 3; i++) {
            engine.consume("login-ip", "9.9.9.9");
        }
        assertThatThrownBy(() -> engine.consume("login-ip", "9.9.9.9")).isInstanceOf(RateLimitExceededException.class);

        // A different dimension entirely (login-username) must still pass, since it
        // consults a completely separate bucket/key from login-ip.
        assertThatCode(() -> engine.consume("login-username", "someone-else"))
                .doesNotThrowAnyException();
    }

    @Test
    @DisplayName("different identifiers within the same dimension do not affect each other")
    void differentIdentifiersAreIsolated() {
        for (int i = 0; i < 3; i++) {
            engine.consume("login-username", "alice");
        }
        assertThatThrownBy(() -> engine.consume("login-username", "alice")).isInstanceOf(RateLimitExceededException.class);

        // "bob" has never been charged - must have his full budget.
        assertThatCode(() -> engine.consume("login-username", "bob")).doesNotThrowAnyException();
    }

    @Test
    @DisplayName("keys are namespaced by limit name and identifier only - callers control hashing, not this class")
    void keysAreNamespacedByLimitAndIdentifier() {
        String tokenHash = "deadbeefcafe"; // caller's responsibility to hash before calling consume()
        engine.consume("refresh-token", tokenHash);

        List<byte[]> keys = connection.sync().keys("*");
        List<String> keyStrings = keys.stream().map(String::new).toList();

        assertThat(keyStrings).anyMatch(k -> k.equals("ratelimit:refresh-token:" + tokenHash));
    }

    @Test
    @DisplayName("disabled flag bypasses enforcement entirely, even far beyond capacity")
    void disabledBypassesEnforcement() {
        RateLimitProperties disabled = new RateLimitProperties(
                false, false,
                Map.of("login-ip", new RateLimitProperties.Limit(1, Duration.ofMinutes(1))));
        Bucket4jRateLimiterEngine disabledEngine = new Bucket4jRateLimiterEngine(proxyManager, disabled, meterRegistry);

        assertThatCode(() -> {
            for (int i = 0; i < 20; i++) {
                disabledEngine.consume("login-ip", "irrelevant-when-disabled");
            }
        }).doesNotThrowAnyException();
    }

    @Test
    @DisplayName("unknown limit name fails fast with a clear message, not a silent NPE")
    void unknownLimitNameFailsFast() {
        assertThatThrownBy(() -> engine.consume("no-such-limit", "whoever"))
                .isInstanceOf(IllegalStateException.class)
                .hasMessageContaining("no-such-limit");
    }

    @Test
    @DisplayName("metrics: allowed/rejected counters increment correctly")
    void metricsAreRecorded() {
        engine.consume("login-ip", "5.5.5.5");
        engine.consume("login-ip", "5.5.5.5");
        engine.consume("login-ip", "5.5.5.5");
        try {
            engine.consume("login-ip", "5.5.5.5");
        } catch (RateLimitExceededException ignored) {
            // expected on the 4th call
        }

        double allowed = meterRegistry.counter("ratelimit.allowed", "limit", "login-ip").count();
        double rejected = meterRegistry.counter("ratelimit.rejected", "limit", "login-ip").count();

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
                    engine.consume("login-ip", "race-condition-target-ip");
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
