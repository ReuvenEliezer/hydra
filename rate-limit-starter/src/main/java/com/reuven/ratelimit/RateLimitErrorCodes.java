package com.reuven.ratelimit;

/**
 * Machine-readable error code for the 429 response body, shared across every service so
 * clients (and cross-service tests) can match on one constant regardless of which
 * service rejected the request.
 */
public final class RateLimitErrorCodes {

    public static final String RATE_LIMIT_EXCEEDED = "rate_limit_exceeded";

    private RateLimitErrorCodes() {
    }
}
