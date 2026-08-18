package com.reuven.browseredge;

import lombok.extern.slf4j.Slf4j;
import org.springframework.boot.autoconfigure.AutoConfiguration;
import org.springframework.boot.context.properties.EnableConfigurationProperties;
import org.springframework.context.annotation.Bean;
import org.springframework.http.HttpHeaders;
import org.springframework.http.HttpMethod;
import org.springframework.web.cors.CorsConfiguration;
import org.springframework.web.cors.CorsConfigurationSource;
import org.springframework.web.cors.UrlBasedCorsConfigurationSource;

import java.util.List;

/**
 * Single activation point for the browser origin policy (Principle II). Discovered through
 * {@code META-INF/spring/org.springframework.boot.autoconfigure.AutoConfiguration.imports}, so no
 * consuming service needs a {@code @ComponentScan}, {@code @EnableConfigurationProperties}, or
 * {@code @Import} - the same mechanism {@code RateLimitAutoConfiguration} uses.
 * <p>
 * Contributes a {@code CorsConfigurationSource} bean with the same type and bean name as the
 * beans it replaces, so {@code http.cors(Customizer.withDefaults())} in each service's
 * {@code SecurityCommons} resolves it unchanged.
 * <p>
 * Validates the configured policy in this bean's factory method, so an unsafe policy fails
 * context refresh before the service binds its port (research R4): an origin pattern outside the
 * controlled-domain set, a base domain that is a public suffix, or base domains spanning more
 * than one registrable domain are all fatal. An empty pattern list is the deliberate exception -
 * it is safe but useless, so it only warns (data-model.md &sect;4).
 */
@Slf4j
@AutoConfiguration
@EnableConfigurationProperties({BrowserOriginProperties.class, ControlledDomainProperties.class})
public class BrowserEdgeAutoConfiguration {

    @Bean
    public CorsConfigurationSource corsConfigurationSource(BrowserOriginProperties browserOriginProperties,
                                                             ControlledDomainProperties controlledDomainProperties) {
        OriginPatternValidator validator = new OriginPatternValidator(controlledDomainProperties.baseDomains());

        List<String> allowedOriginPatterns = browserOriginProperties.allowedOriginPatterns();
        if (allowedOriginPatterns.isEmpty()) {
            log.warn("hydra.cors.allowed-origin-patterns is empty - all cross-origin browser requests will be rejected");
        } else {
            allowedOriginPatterns.forEach(validator::validateOriginPattern);
            log.info("CORS enabled for origin patterns {} (credentials allowed, Retry-After exposed)", allowedOriginPatterns);
        }

        CorsConfiguration config = new CorsConfiguration();
        config.setAllowedOriginPatterns(allowedOriginPatterns);
        config.setAllowedMethods(List.of(
                HttpMethod.GET.name(),
                HttpMethod.POST.name(),
                HttpMethod.OPTIONS.name()));
        config.setAllowedHeaders(List.of(
                HttpHeaders.AUTHORIZATION,
                HttpHeaders.CONTENT_TYPE,
                HttpHeaders.ACCEPT));
        config.setExposedHeaders(List.of(HttpHeaders.RETRY_AFTER));
        config.setAllowCredentials(true);
        config.setMaxAge(browserOriginProperties.maxAge());

        UrlBasedCorsConfigurationSource source = new UrlBasedCorsConfigurationSource();
        source.registerCorsConfiguration("/**", config);
        return source;
    }
}
