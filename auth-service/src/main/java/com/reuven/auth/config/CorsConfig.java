package com.reuven.auth.config;

import com.reuven.Headers;
import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.springframework.boot.context.properties.EnableConfigurationProperties;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.http.HttpHeaders;
import org.springframework.http.HttpMethod;
import org.springframework.web.cors.CorsConfiguration;
import org.springframework.web.cors.CorsConfigurationSource;
import org.springframework.web.cors.UrlBasedCorsConfigurationSource;

import java.util.List;

/**
 * CORS policy for browser clients (the {@code @hydra/ui} package and any app embedding it).
 * <p>
 * Picked up automatically by {@code http.cors(...)} in {@link SecurityCommons}, so the same
 * policy applies to every filter chain regardless of profile.
 * <p>
 * Two settings here are load-bearing for the front-end and easy to break by "tidying up":
 * <ul>
 *   <li>{@code allowCredentials(true)} - without it the browser refuses to attach the
 *       httpOnly refresh cookie to {@code /api/v1/auth/refresh}, so every session silently
 *       dies at access-token expiry instead of rotating.</li>
 *   <li>{@code exposedHeaders(Retry-After)} - {@code Retry-After} is NOT a CORS-safelisted
 *       response header. Without exposing it, {@code response.headers.get("Retry-After")}
 *       reads {@code null} cross-origin and the client cannot tell the user how long to wait
 *       after a 429 from the rate limiter.</li>
 * </ul>
 */
@Slf4j
@Configuration
@RequiredArgsConstructor
@EnableConfigurationProperties(CorsProperties.class)
public class CorsConfig {

    private final CorsProperties corsProperties;

    @Bean
    public CorsConfigurationSource corsConfigurationSource() {
        List<String> allowedOrigins = corsProperties.allowedOrigins();
        if (allowedOrigins.isEmpty()) {
            log.warn("hydra.cors.allowed-origins is empty - all cross-origin browser requests will be rejected");
        } else {
            log.info("CORS enabled for origins {} (credentials allowed, Retry-After exposed)", allowedOrigins);
        }

        CorsConfiguration config = new CorsConfiguration();
        config.setAllowedOrigins(allowedOrigins);
        config.setAllowedMethods(List.of(
                HttpMethod.GET.name(),
                HttpMethod.POST.name(),
                HttpMethod.OPTIONS.name()));
        config.setAllowedHeaders(List.of(
                HttpHeaders.AUTHORIZATION,
                HttpHeaders.CONTENT_TYPE,
                HttpHeaders.ACCEPT,
                Headers.TENANT_ID));
        config.setExposedHeaders(List.of(HttpHeaders.RETRY_AFTER));
        config.setAllowCredentials(true);
        config.setMaxAge(corsProperties.maxAge());

        UrlBasedCorsConfigurationSource source = new UrlBasedCorsConfigurationSource();
        source.registerCorsConfiguration("/**", config);
        return source;
    }
}
