package com.reuven.auth.config;

import com.reuven.auth.service.JwtAuthenticationFilter;
import lombok.extern.slf4j.Slf4j;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.context.annotation.Profile;
import org.springframework.security.config.Customizer;
import org.springframework.security.config.annotation.method.configuration.EnableMethodSecurity;
import org.springframework.security.config.annotation.web.builders.HttpSecurity;
import org.springframework.security.config.annotation.web.configuration.EnableWebSecurity;
import org.springframework.security.config.annotation.web.configurers.AbstractHttpConfigurer;
import org.springframework.security.config.annotation.web.configurers.AuthorizeHttpRequestsConfigurer;
import org.springframework.security.config.http.SessionCreationPolicy;
import org.springframework.security.crypto.bcrypt.BCryptPasswordEncoder;
import org.springframework.security.crypto.password.PasswordEncoder;
import org.springframework.security.web.SecurityFilterChain;
import org.springframework.security.web.authentication.UsernamePasswordAuthenticationFilter;

import java.security.KeyFactory;
import java.security.interfaces.RSAPrivateKey;
import java.security.spec.PKCS8EncodedKeySpec;
import java.util.Base64;

@Slf4j
@Configuration
@EnableWebSecurity
@EnableMethodSecurity // This enables @PreAuthorize support across the application
public class SecurityConfig {

    @Bean
    @Profile("!local")
    public SecurityFilterChain securityFilterChain(HttpSecurity http, JwtAuthenticationFilter jwtAuthFilter) throws Exception {
        return applyCommonSecurity(http, jwtAuthFilter)
                .authorizeHttpRequests(authRules())
                .build();
    }

    public static HttpSecurity applyCommonSecurity(HttpSecurity http, JwtAuthenticationFilter jwtAuthFilter) throws Exception {
        return http
                .csrf(AbstractHttpConfigurer::disable)
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
//                .exceptionHandling(ex -> ex
//                        .authenticationEntryPoint(new HttpStatusEntryPoint(HttpStatus.UNAUTHORIZED))
//                )
                .sessionManagement(session -> session.sessionCreationPolicy(SessionCreationPolicy.STATELESS))
                .addFilterBefore(jwtAuthFilter, UsernamePasswordAuthenticationFilter.class);
    }

    public static Customizer<AuthorizeHttpRequestsConfigurer<HttpSecurity>.AuthorizationManagerRequestMatcherRegistry> authRules() {
        return auth -> auth
                // 1. Open endpoints
                .requestMatchers("/api/v1/auth/login").permitAll()

                // 2. Tenant admin registration - Super Admin only
                .requestMatchers("/api/v1/admin/*/register-admin").hasAuthority("ROLE_SUPER_ADMIN")

                // 3. Regular user registration - Admin or Super Admin
                // Matching AdminController:
                .requestMatchers("/api/v1/admin/register-user").hasAnyAuthority("ROLE_SUPER_ADMIN", "ROLE_ADMIN")

                .requestMatchers("/.well-known/jwks.json").permitAll()
                .requestMatchers("/actuator/health").permitAll()

                // 4. Other requests require authentication
                .anyRequest().authenticated();
    }

    // Adding missing imports that were missing in your code snippet
    @Bean
    public RSAPrivateKey jwtPrivateKey(@Value("${jwt.private-key}") String privateKeyContent) throws Exception {
        String privateKeyPEM = privateKeyContent
                .replace("-----BEGIN PRIVATE KEY-----", "")
                .replace("-----END PRIVATE KEY-----", "")
                .replaceAll("\\s", "");

        byte[] encoded = Base64.getDecoder().decode(privateKeyPEM);
        PKCS8EncodedKeySpec keySpec = new PKCS8EncodedKeySpec(encoded);
        KeyFactory keyFactory = KeyFactory.getInstance("RSA");
        return (RSAPrivateKey) keyFactory.generatePrivate(keySpec);
    }

    @Bean
    public PasswordEncoder passwordEncoder() {
        return new BCryptPasswordEncoder(12);
    }
}
