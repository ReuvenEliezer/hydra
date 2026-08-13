package com.reuven.auth.config;

import com.reuven.Role;
import com.reuven.auth.service.JwtAuthenticationFilter;
import lombok.extern.slf4j.Slf4j;
import org.springframework.http.HttpMethod;
import org.springframework.http.HttpStatus;
import org.springframework.security.config.annotation.web.builders.HttpSecurity;
import org.springframework.security.config.annotation.web.configurers.AbstractHttpConfigurer;
import org.springframework.security.config.annotation.web.configurers.AuthorizeHttpRequestsConfigurer;
import org.springframework.security.config.http.SessionCreationPolicy;
import org.springframework.security.web.authentication.UsernamePasswordAuthenticationFilter;
import org.springframework.stereotype.Component;
import org.springframework.security.config.Customizer;

/**
 * Shared security configuration applied to every {@link org.springframework.security.web.SecurityFilterChain}
 * regardless of profile (prod, local). Extracted from static methods in {@link SecurityConfig}
 * to allow proper Spring-managed injection and avoid the static-method anti-pattern.
 */
@Slf4j
@Component
public class SecurityCommons {

    /**
     * Applies the baseline security posture: CORS from the shared
     * {@link org.springframework.web.cors.CorsConfigurationSource} bean, CSRF off
     * (stateless JWT API), STATELESS session, and the JWT filter wired before the
     * standard UsernamePasswordAuthenticationFilter. Custom entry points return
     * structured JSON-compatible status codes without leaking stack traces.
     * <p>
     * CORS is applied here rather than in each chain so the {@code local} (H2 console)
     * and {@code !local} chains can never drift apart on it - a browser client that
     * works in one profile and mysteriously fails in the other is exactly the bug this
     * placement prevents.
     */
    public HttpSecurity applyCommonSecurity(HttpSecurity http,
                                            JwtAuthenticationFilter jwtAuthFilter) throws Exception {
        return http
                .cors(Customizer.withDefaults())
                .csrf(AbstractHttpConfigurer::disable)
                .exceptionHandling(ex -> ex
                        .authenticationEntryPoint((req, res, e) -> {
                            log.warn("Unauthorized access attempt on [{}]: {}", req.getRequestURI(), e.getMessage());
                            res.sendError(HttpStatus.UNAUTHORIZED.value(), HttpStatus.UNAUTHORIZED.getReasonPhrase());
                        })
                        .accessDeniedHandler((req, res, e) -> {
                            log.warn("Access denied on [{}]: {}", req.getRequestURI(), e.getMessage());
                            res.sendError(HttpStatus.FORBIDDEN.value(), HttpStatus.FORBIDDEN.getReasonPhrase());
                        })
                )
                .sessionManagement(s -> s.sessionCreationPolicy(SessionCreationPolicy.STATELESS))
                .addFilterBefore(jwtAuthFilter, UsernamePasswordAuthenticationFilter.class);
    }

    /**
     * Authorization rules shared across all profiles.
     * Any profile-specific overrides (e.g. H2 console) are added by the caller
     * before delegating to this customizer.
     */
    public Customizer<AuthorizeHttpRequestsConfigurer<HttpSecurity>.AuthorizationManagerRequestMatcherRegistry> authRules() {
        return auth -> auth
                // Preflight carries no credentials by design, so it can never authenticate.
                // Spring's CorsFilter normally short-circuits it before authorization runs;
                // this rule is the explicit backstop so a filter-order change can't turn every
                // cross-origin call into a 401 on the OPTIONS that precedes it.
                .requestMatchers(HttpMethod.OPTIONS, "/**").permitAll()
                .requestMatchers("/api/v1/auth/login").permitAll()
                .requestMatchers("/api/v1/auth/refresh").permitAll()
                .requestMatchers("/api/v1/auth/logout").permitAll()
                .requestMatchers("/.well-known/jwks.json").permitAll()
                .requestMatchers("/actuator/health").permitAll()
                .requestMatchers("/api/v1/admin/*/register-admin").hasAuthority(Role.SUPER_ADMIN.authority())
                .requestMatchers("/api/v1/admin/register-user").hasAnyAuthority(Role.SUPER_ADMIN.authority(), Role.ADMIN.authority())
                .anyRequest().authenticated();
    }
}
