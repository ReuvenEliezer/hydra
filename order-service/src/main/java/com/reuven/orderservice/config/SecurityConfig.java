package com.reuven.orderservice.config;

import lombok.extern.slf4j.Slf4j;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.http.HttpStatus;
import org.springframework.security.config.Customizer;
import org.springframework.security.config.annotation.method.configuration.EnableMethodSecurity;
import org.springframework.security.config.annotation.web.builders.HttpSecurity;
import org.springframework.security.config.annotation.web.configuration.EnableWebSecurity;
import org.springframework.security.config.annotation.web.configurers.AbstractHttpConfigurer;
import org.springframework.security.config.http.SessionCreationPolicy;
import org.springframework.security.oauth2.jwt.JwtDecoder;
import org.springframework.security.oauth2.jwt.NimbusJwtDecoder;
import org.springframework.security.oauth2.server.resource.authentication.JwtAuthenticationConverter;
import org.springframework.security.oauth2.server.resource.authentication.JwtGrantedAuthoritiesConverter;
import org.springframework.security.web.SecurityFilterChain;
import org.springframework.security.web.authentication.HttpStatusEntryPoint;

@Slf4j
@Configuration
@EnableWebSecurity
@EnableMethodSecurity // Enables the use of @PreAuthorize("hasAuthority('...')")
public class SecurityConfig {

    @Bean
    public SecurityFilterChain securityFilterChain(HttpSecurity http, JwtAuthenticationConverter jwtAuthenticationConverter) {
        return http
                .csrf(AbstractHttpConfigurer::disable)
                .sessionManagement(s -> s.sessionCreationPolicy(SessionCreationPolicy.STATELESS))
//                .exceptionHandling(ex -> ex
//                        .authenticationEntryPoint(new HttpStatusEntryPoint(HttpStatus.UNAUTHORIZED))
//                )
                .exceptionHandling(ex -> ex
                        .authenticationEntryPoint((req, res, e) -> {
                            log.error("Auth error: {}", e.getMessage(), e);
                            res.sendError(401, "Unauthorized");
                        })
                        .accessDeniedHandler((req, res, e) -> {
                            log.error("Access denied: {}", e.getMessage(), e);
                            res.sendError(403, "Forbidden");
                        })
                )
                .authorizeHttpRequests(auth -> auth
                        .requestMatchers("/actuator/health").permitAll()
                        .anyRequest().authenticated()
                )
                // This is where the magic happens - Spring becomes a Resource Server
                .oauth2ResourceServer(oauth2 -> oauth2
                        .jwt(jwt -> jwt.jwtAuthenticationConverter(jwtAuthenticationConverter)))
//                .oauth2ResourceServer(oauth2 -> oauth2.jwt(Customizer.withDefaults()))
                .build();
    }


    @Bean
    public JwtAuthenticationConverter jwtAuthenticationConverter() {
        JwtGrantedAuthoritiesConverter converter = new JwtGrantedAuthoritiesConverter();
        converter.setAuthoritiesClaimName("roles");
        // ROLE_ already comes from the token
        converter.setAuthorityPrefix(""); // ROLE_ prefix already in the claim
//         Very important: because you use hasRole, Spring looks for the prefix ROLE_
//        converter.setAuthorityPrefix(""); // Don't add anything! The value in the token is already complete.
        JwtAuthenticationConverter jwtConverter = new JwtAuthenticationConverter();
        jwtConverter.setJwtGrantedAuthoritiesConverter(converter);
        return jwtConverter;
    }

    // This explicitly creates the bean that Spring is looking for
//    @Bean //use application.yaml for configuration instead of this bean
//    public JwtDecoder jwtDecoder(
//            @Value("${spring.security.oauth2.resourceserver.jwt.jwk-set-uri}") String jwkSetUri
//    ) {
//        // Option A: Using a JWK Set URI
//        try {
//            return NimbusJwtDecoder.withJwkSetUri(
//                    jwkSetUri
////                    "http://localhost:8083/.well-known/jwks.json"
//            ).build();
//        } catch (Exception e) {
//            // This will print the actual reason the decoder failed
//            log.error("Failed to create JwtDecoder: {}", e.getMessage());
//            throw e;
//        }
//    }
}