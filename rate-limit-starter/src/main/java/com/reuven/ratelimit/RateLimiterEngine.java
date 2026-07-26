package com.reuven.ratelimit;

/**
 * Backend contract for actually enforcing a rate limit. {@link RateLimiterAspect} depends
 * only on this interface, never on Bucket4j/Redis/anything concrete - each service supplies
 * its own implementation as a bean (e.g. a Bucket4j+Redis-backed one for production, an
 * in-memory one for a slice test).
 *
 * <p>{@link com.reuven.ratelimit.RateLimitAutoConfiguration} only activates
 * {@link RateLimiterAspect} once a bean of this type exists, so services that haven't
 * adopted rate limiting yet are unaffected by depending on infra-shared.
 */
public interface RateLimiterEngine {

    /**
     * @param limitName key into the service's own rate-limit config (capacity/window)
     * @param identifier the concrete subject being limited (an IP, a username, a token hash, ...)
     * @throws RateLimitExceededException if {@code identifier}'s budget for {@code limitName} is exhausted
     */
    void consume(String limitName, String identifier);

    boolean enabled();

}
