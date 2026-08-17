package com.reuven.orderservice.config;

import org.springframework.boot.context.properties.ConfigurationProperties;

import java.time.Duration;
import java.util.List;

/**
 * Browser CORS settings for the order-service HTTP API.
 * <p>
 * {@code allowedOriginPatterns} holds origin PATTERNS, not literal origins: the app now runs on
 * per-tenant subdomains, so every tenant is its own browser origin and a literal list would need
 * an entry (and a deployment) per tenant. A pattern is not {@code "*"} - Spring matches the
 * request's {@code Origin} and echoes back that one specific origin, which is what keeps
 * credentialed requests legal where the literal wildcard the CORS spec forbids would not.
 * <p>
 * Keep the patterns as narrow as the deployment allows ({@code https://*.hydra.example.com}, not
 * {@code https://*}) - the wildcard is meant to cover one label of a domain you control.
 * <p>
 * An empty/absent list fails closed - no cross-origin caller is allowed - rather than
 * silently opening the API to every origin.
 */
@ConfigurationProperties(prefix = "hydra.cors")
public record CorsProperties(List<String> allowedOriginPatterns, Duration maxAge) {

    private static final Duration DEFAULT_MAX_AGE = Duration.ofMinutes(30);

    public CorsProperties {
        allowedOriginPatterns = allowedOriginPatterns == null ? List.of() : List.copyOf(allowedOriginPatterns);
        maxAge = maxAge == null ? DEFAULT_MAX_AGE : maxAge;
    }
}
