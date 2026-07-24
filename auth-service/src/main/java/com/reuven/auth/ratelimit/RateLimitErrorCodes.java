package com.reuven.auth.ratelimit;

/**
 * Machine-readable error code for the 429 response body, per features/rate-limited/REQUIREMENTS.md.
 */
public final class RateLimitErrorCodes {

    public static final String RATE_LIMIT_EXCEEDED = "rate_limit_exceeded";

    private RateLimitErrorCodes() {}
}
