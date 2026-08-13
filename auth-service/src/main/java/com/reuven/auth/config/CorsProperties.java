package com.reuven.auth.config;

import org.springframework.boot.context.properties.ConfigurationProperties;

import java.time.Duration;
import java.util.List;

/**
 * Browser CORS settings for the auth-service HTTP API.
 * <p>
 * {@code allowedOrigins} MUST be explicit origins - never {@code "*"} and never a
 * wildcard pattern. The refresh-token flow sends the httpOnly cookie with
 * {@code credentials: "include"}, and the CORS spec forbids the wildcard origin on
 * credentialed requests: browsers reject the response outright, which would surface
 * as an unexplainable "failed to fetch" in the UI rather than a readable error.
 * <p>
 * An empty/absent list therefore fails closed - no cross-origin caller is allowed -
 * rather than silently opening the API to every origin.
 */
@ConfigurationProperties(prefix = "hydra.cors")
public record CorsProperties(List<String> allowedOrigins, Duration maxAge) {

    private static final Duration DEFAULT_MAX_AGE = Duration.ofMinutes(30);

    public CorsProperties {
        allowedOrigins = allowedOrigins == null ? List.of() : List.copyOf(allowedOrigins);
        maxAge = maxAge == null ? DEFAULT_MAX_AGE : maxAge;
    }
}
