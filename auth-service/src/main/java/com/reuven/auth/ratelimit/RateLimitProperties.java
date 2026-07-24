package com.reuven.auth.ratelimit;

import org.springframework.boot.context.properties.ConfigurationProperties;
import org.springframework.boot.context.properties.bind.DefaultValue;

import java.time.Duration;

/**
 * Externalized rate-limit configuration - see application.yaml's {@code rate-limit}
 * block, which is the actual source of truth for capacity/window values (every leaf
 * value there already has its own {@code ${ENV_VAR:default}} fallback). The
 * {@code @DefaultValue} annotations on the scalar leaves below are only a defensive
 * second layer in case this properties type is ever bound in a context that doesn't
 * load that yaml (e.g. a narrow slice test) - they mirror the same example defaults
 * from the requirements (5/min for login, 20/min for refresh).
 */
@ConfigurationProperties(prefix = "rate-limit")
public record RateLimitProperties(
        @DefaultValue("true") boolean enabled,
        Login login,
        Refresh refresh) {

    public record Login(Limit perIp, Limit perUsername) {
    }

    public record Refresh(Limit perIp, Limit perToken) {
    }

    /** capacity requests per window, e.g. 5 requests per PT1M. */
    public record Limit(
            @DefaultValue("5") long capacity,
            @DefaultValue("PT1M") Duration window) {
    }
}
