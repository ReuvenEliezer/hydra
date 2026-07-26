package com.reuven.ratelimit;

public class NoOpRateLimiterEngine implements RateLimiterEngine {

    @Override
    public void consume(String limitName, String identifier) {
        // Intentionally empty.
        // Rate limiting is disabled.
    }

    @Override
    public boolean enabled() {
        return false;
    }
}
