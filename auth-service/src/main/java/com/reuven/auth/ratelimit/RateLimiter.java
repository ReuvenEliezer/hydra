package com.reuven.auth.ratelimit;

import com.reuven.auth.util.Sha256;
import io.github.bucket4j.Bandwidth;
import io.github.bucket4j.BucketConfiguration;
import io.github.bucket4j.ConsumptionProbe;
import io.github.bucket4j.distributed.proxy.ProxyManager;
import io.micrometer.core.instrument.MeterRegistry;
import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.springframework.stereotype.Service;

import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.util.function.Supplier;

/**
 * Enforces the rate limits described in features/rate-limited/REQUIREMENTS.md.
 *
 * <p>Login and refresh each have two independent dimensions - callers invoke both
 * of an endpoint's check methods (e.g. {@link #checkLoginIp} then
 * {@link #checkLoginUsername}), and a request exceeding EITHER one is rejected.
 * Each dimension has its own separate Bucket4j token bucket in Redis, so e.g. one
 * attacker's IP being throttled never affects a different, unrelated username's
 * remaining budget (and vice versa). Methods are split per-dimension rather than
 * bundled per-endpoint so callers can sequence them - e.g. {@code /auth/refresh}
 * with no cookie at all still charges the per-IP bucket without needing a token
 * to hash.
 *
 * <p>Thread-safety and cross-instance correctness both come from the same place:
 * every {@code tryConsume} call is a single atomic Redis operation performed
 * through {@link ProxyManager} (Bucket4j's Lettuce-based CAS implementation) -
 * there is no in-process locking to reason about, and any number of auth-service
 * instances behind a load balancer share the exact same bucket state.
 */
@Slf4j
@Service
@RequiredArgsConstructor
public class RateLimiter {

    private final ProxyManager<byte[]> proxyManager;
    private final RateLimitProperties properties;
    private final MeterRegistry meterRegistry;

    /**
     * @param clientIp the resolved client IP (see {@link ClientIpResolver})
     * @throws RateLimitExceededException if the per-IP login limit is exceeded
     */
    public void checkLoginIp(String clientIp) {
        enforce("login", "ip", clientIp, properties.login().perIp());
    }

    /**
     * @param username as submitted in the login request body, pre-authentication
     * @throws RateLimitExceededException if the per-username login limit is exceeded
     */
    public void checkLoginUsername(String username) {
        enforce("login", "username", username.toLowerCase(), properties.login().perUsername());
    }

    /**
     * @param clientIp the resolved client IP (see {@link ClientIpResolver})
     * @throws RateLimitExceededException if the per-IP refresh limit is exceeded
     */
    public void checkRefreshIp(String clientIp) {
        enforce("refresh", "ip", clientIp, properties.refresh().perIp());
    }

    /**
     * @param rawRefreshToken the token exactly as presented (hashed before use as a
     *                        Redis key - never stored or logged in raw form)
     * @throws RateLimitExceededException if the per-token refresh limit is exceeded
     */
    public void checkRefreshToken(String rawRefreshToken) {
        enforce("refresh", "token", Sha256.hash(rawRefreshToken), properties.refresh().perToken());
    }

    private void enforce(String endpoint, String dimension, String identifier, RateLimitProperties.Limit limit) {
        if (!properties.enabled()) {
            return;
        }

        byte[] key = ("ratelimit:" + endpoint + ":" + dimension + ":" + identifier).getBytes(StandardCharsets.UTF_8);
        Supplier<BucketConfiguration> configSupplier = () -> bucketConfiguration(limit);

        ConsumptionProbe probe = proxyManager.builder()
                .build(key, configSupplier)
                .tryConsumeAndReturnRemaining(1);

        meterRegistry.summary("auth.ratelimit.remaining", "endpoint", endpoint, "dimension", dimension)
                .record(probe.getRemainingTokens());

        if (probe.isConsumed()) {
            meterRegistry.counter("auth.ratelimit.allowed", "endpoint", endpoint, "dimension", dimension).increment();
            return;
        }

        meterRegistry.counter("auth.ratelimit.rejected", "endpoint", endpoint, "dimension", dimension).increment();
        Duration retryAfter = Duration.ofNanos(probe.getNanosToWaitForRefill());
        log.warn("rate_limit_exceeded endpoint={} dimension={} capacity={} window={} retryAfterSeconds={}",
                endpoint, dimension, limit.capacity(), limit.window(), retryAfter.toSeconds());
        throw new RateLimitExceededException(retryAfter);
    }

    private static BucketConfiguration bucketConfiguration(RateLimitProperties.Limit limit) {
        return BucketConfiguration.builder()
                .addLimit(Bandwidth.builder()
                        .capacity(limit.capacity())
                        .refillIntervally(limit.capacity(), limit.window())
                        .build())
                .build();
    }
}
