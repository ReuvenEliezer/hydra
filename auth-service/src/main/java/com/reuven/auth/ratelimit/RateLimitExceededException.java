package com.reuven.auth.ratelimit;

import java.time.Duration;

/**
 * Thrown by {@link RateLimiter} when a request exceeds its configured limit.
 * Carries how long the caller should wait before retrying, so
 * {@code GlobalExceptionHandler} can set a {@code Retry-After} header.
 */
public class RateLimitExceededException extends RuntimeException {

    private final Duration retryAfter;

    public RateLimitExceededException(Duration retryAfter) {
        super("Too many requests. Please try again later.");
        this.retryAfter = retryAfter;
    }

    public Duration retryAfter() {
        return retryAfter;
    }
}
