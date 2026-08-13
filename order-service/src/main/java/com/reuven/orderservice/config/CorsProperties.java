package com.reuven.orderservice.config;

import org.springframework.boot.context.properties.ConfigurationProperties;

import java.time.Duration;
import java.util.List;

/**
 * Browser CORS settings for the order-service HTTP API.
 * <p>
 * {@code allowedOrigins} MUST be explicit origins - never {@code "*"} and never a
 * wildcard pattern, since the browser sends credentialed requests and the CORS spec
 * forbids the wildcard origin in that case.
 * <p>
 * An empty/absent list fails closed - no cross-origin caller is allowed - rather than
 * silently opening the API to every origin.
 */
@ConfigurationProperties(prefix = "hydra.cors")
public record CorsProperties(List<String> allowedOrigins, Duration maxAge) {

    private static final Duration DEFAULT_MAX_AGE = Duration.ofMinutes(30);

    public CorsProperties {
        allowedOrigins = allowedOrigins == null ? List.of() : List.copyOf(allowedOrigins);
        maxAge = maxAge == null ? DEFAULT_MAX_AGE : maxAge;
    }
}
