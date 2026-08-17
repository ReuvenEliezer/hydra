package com.reuven.auth.config;

import org.springframework.boot.context.properties.ConfigurationProperties;

import java.time.Duration;
import java.util.List;

/**
 * Browser CORS settings for the auth-service HTTP API.
 * <p>
 * {@code allowedOriginPatterns} holds origin PATTERNS, not literal origins - every tenant now
 * signs in at its own subdomain, so each is its own browser origin and a fixed list would need a
 * new entry (and a deployment) per tenant. A pattern is not {@code "*"}: Spring matches the
 * request's {@code Origin} against it and echoes back that one specific origin, which is exactly
 * what keeps {@code allowCredentials(true)} legal. That distinction is load-bearing - the refresh
 * flow sends its httpOnly cookie with {@code credentials: "include"}, and the CORS spec forbids
 * the literal wildcard on credentialed requests, which browsers surface as an unexplainable
 * "failed to fetch" rather than a readable error.
 * <p>
 * Keep the patterns as narrow as the deployment allows ({@code https://*.hydra.example.com}, not
 * {@code https://*}): the wildcard covers one label of a domain you control, and widening it hands
 * that echo-the-origin behavior to anyone.
 * <p>
 * An empty/absent list therefore still fails closed - no cross-origin caller is allowed - rather
 * than silently opening the API to every origin.
 */
@ConfigurationProperties(prefix = "hydra.cors")
public record CorsProperties(List<String> allowedOriginPatterns, Duration maxAge) {

    private static final Duration DEFAULT_MAX_AGE = Duration.ofMinutes(30);

    public CorsProperties {
        allowedOriginPatterns = allowedOriginPatterns == null ? List.of() : List.copyOf(allowedOriginPatterns);
        maxAge = maxAge == null ? DEFAULT_MAX_AGE : maxAge;
    }
}
