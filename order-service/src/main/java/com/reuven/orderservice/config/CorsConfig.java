package com.reuven.orderservice.config;

import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.jspecify.annotations.NonNull;
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
 * Deliberately narrower than auth-service's: order-service never reads
 * {@code X-Tenant-ID} - the tenant is derived server-side from the JWT {@code tenantId}
 * claim - so that header is not in the allowed set. Accepting it here would imply a
 * request-controlled tenant that this service does not honour, which is precisely the
 * confusion a cross-tenant access attempt would exploit.
 * <p>
 * {@code allowCredentials(true)} is set for consistency with the auth-service policy and
 * for future cookie-bearing endpoints; today's order calls authenticate with a bearer
 * token. {@code Retry-After} is exposed because it is not a CORS-safelisted response
 * header, and the client cannot render a rate-limit countdown it cannot read.
 */
@Slf4j
@Configuration
@RequiredArgsConstructor
@EnableConfigurationProperties(CorsProperties.class)
public class CorsConfig {

    private final CorsProperties corsProperties;

    @Bean
    public CorsConfigurationSource corsConfigurationSource() {
        List<String> allowedOriginPatterns = corsProperties.allowedOriginPatterns();
        if (allowedOriginPatterns.isEmpty()) {
            log.warn("hydra.cors.allowed-origin-patterns is empty - all cross-origin browser requests will be rejected");
        } else {
            log.info("CORS enabled for origin patterns {} (credentials allowed, Retry-After exposed)", allowedOriginPatterns);
        }

        CorsConfiguration config = createConfig(allowedOriginPatterns);

        UrlBasedCorsConfigurationSource source = new UrlBasedCorsConfigurationSource();
        source.registerCorsConfiguration("/**", config);
        return source;
    }

    private @NonNull CorsConfiguration createConfig(List<String> allowedOriginPatterns) {
        CorsConfiguration config = new CorsConfiguration();
        config.setAllowedOriginPatterns(allowedOriginPatterns);
        config.setAllowedMethods(List.of(
                HttpMethod.GET.name(),
                HttpMethod.POST.name(),
                HttpMethod.PATCH.name(),
                HttpMethod.DELETE.name(),
                HttpMethod.OPTIONS.name()));
        config.setAllowedHeaders(List.of(
                HttpHeaders.AUTHORIZATION,
                HttpHeaders.CONTENT_TYPE,
                HttpHeaders.ACCEPT));
        config.setExposedHeaders(List.of(HttpHeaders.RETRY_AFTER));
        config.setAllowCredentials(true);
        config.setMaxAge(corsProperties.maxAge());
        return config;
    }
}
