package com.reuven.ratelimit;

import io.github.bucket4j.Bandwidth;
import io.github.bucket4j.BucketConfiguration;
import io.github.bucket4j.ConsumptionProbe;
import io.github.bucket4j.distributed.proxy.ProxyManager;
import io.lettuce.core.RedisException;
import io.micrometer.core.instrument.MeterRegistry;
import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;

import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.util.function.Supplier;

/**
 * Default {@link RateLimiterEngine}: distributed, Redis-backed token buckets via
 * Bucket4j. Every {@code tryConsume} is a single atomic Redis operation through
 * {@link ProxyManager} (Bucket4j's Lettuce-based CAS implementation) - no in-process
 * locking to reason about, and any number of instances of a service behind a load
 * balancer share the exact same bucket state. Auto-configured for any service that
 * pulls in this module and has a {@code RedisConnectionFactory} bean; override by
 * defining your own {@link RateLimiterEngine} bean (e.g. in-memory, for a slice test).
 *
 * <p><b>Backend-failure policy:</b> a Redis outage is a distinct failure mode from "the
 * caller exceeded their budget", and the two must not be conflated. Controlled by
 * {@code rate-limit.fail-open}:
 * <ul>
 *   <li>{@code false} (default) - fail CLOSED. Redis being unreachable rejects the
 *   request with 429, same as a real limit breach. Matches this codebase's
 *   fail-closed security posture for auth-adjacent guardrails; the trade-off is that a
 *   Redis outage can block legitimate login/refresh traffic entirely.</li>
 *   <li>{@code true} - fail OPEN. Requests are allowed through unthrottled while Redis
 *   is unavailable, trading brute-force protection for availability. Only sensible if
 *   there's a compensating control (e.g. WAF-level throttling) upstream during the outage.</li>
 * </ul>
 * Either way this is a deliberate, observable choice (counted via {@code ratelimit.engine.failure})
 * rather than whatever an uncaught {@link RedisException} happens to do by accident.
 */
@Slf4j
@RequiredArgsConstructor
public class Bucket4jRateLimiterEngine implements RateLimiterEngine {

    private final ProxyManager<byte[]> proxyManager;
    private final RateLimitProperties properties;
    private final MeterRegistry meterRegistry;

    @Override
    public void consume(String limitName, String identifier) {
        if (!properties.enabled()) {
            return;
        }

        RateLimitProperties.Limit limit = properties.require(limitName);
        byte[] key = ("ratelimit:" + limitName + ":" + identifier).getBytes(StandardCharsets.UTF_8);

        ConsumptionProbe probe;
        try {
            Supplier<BucketConfiguration> configSupplier = () -> bucketConfiguration(limit);
            probe = proxyManager.builder()
                    .build(key, configSupplier)
                    .tryConsumeAndReturnRemaining(1);
        } catch (RedisException redisFailure) {
            meterRegistry.counter("ratelimit.engine.failure", "limit", limitName).increment();
            log.error("rate_limit_backend_unavailable limit={} failOpen={}", limitName, properties.failOpen(), redisFailure);
            if (properties.failOpen()) {
                return;
            }
            throw new RateLimitExceededException(Duration.ofSeconds(1));
        }

        meterRegistry.summary("ratelimit.remaining", "limit", limitName).record(probe.getRemainingTokens());

        if (probe.isConsumed()) {
            meterRegistry.counter("ratelimit.allowed", "limit", limitName).increment();
            return;
        }

        meterRegistry.counter("ratelimit.rejected", "limit", limitName).increment();
        Duration retryAfter = Duration.ofNanos(probe.getNanosToWaitForRefill());
        log.warn("rate_limit_exceeded limit={} capacity={} window={} retryAfterSeconds={}",
                limitName, limit.capacity(), limit.window(), retryAfter.toSeconds());
        throw new RateLimitExceededException(retryAfter);
    }

    @Override
    public boolean enabled() {
        return true; //properties.enabled();
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
