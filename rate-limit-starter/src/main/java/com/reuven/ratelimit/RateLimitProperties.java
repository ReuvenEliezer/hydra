package com.reuven.ratelimit;

import org.springframework.boot.context.properties.ConfigurationProperties;
import org.springframework.boot.context.properties.bind.DefaultValue;

import java.time.Duration;
import java.util.Map;

/**
 * Externalized rate-limit configuration - see application.yaml's {@code rate-limit}
 * block, which is the source of truth for capacity/window values (every leaf value
 * there already has its own {@code ${ENV_VAR:default}} fallback).
 *
 * <p>Map-based rather than one field per endpoint: adding a new protected endpoint is
 * "add a {@code @RateLimited(limit = "orders-create", ...)} annotation + a
 * {@code rate-limit.limits.orders-create} entry here" - no new Java type, no code
 * change in this class. {@link #require} centralizes the missing-config failure mode
 * (a typo'd {@code limit()} name in an annotation fails fast at first use with a
 * clear message, not a silent NPE deep in Bucket4j).
 */
@ConfigurationProperties(prefix = "rate-limit")
public record RateLimitProperties(
        @DefaultValue("true") boolean enabled,
        @DefaultValue("false") boolean failOpen,
        Map<String, Limit> limits) {

    /** capacity requests per window, e.g. 5 requests per PT1M. */
    public record Limit(
            @DefaultValue("5") long capacity,
            @DefaultValue("PT1M") Duration window) {
    }

    public Limit require(String limitName) {
        Limit limit = limits == null ? null : limits.get(limitName);
        if (limit == null) {
            throw new IllegalStateException(
                    "No rate-limit config for '" + limitName + "' - add rate-limit.limits."
                            + limitName + " to application.yaml, or check the limit() name on the @RateLimited annotation");
        }
        return limit;
    }
}
