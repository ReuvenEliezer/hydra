package com.reuven.auth.config;

import com.reuven.auth.service.JwtAuthenticationFilter;
import jakarta.servlet.http.HttpServlet;
import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.springframework.boot.web.servlet.ServletRegistrationBean;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.context.annotation.Profile;
import org.springframework.security.config.annotation.method.configuration.EnableMethodSecurity;
import org.springframework.security.config.annotation.web.builders.HttpSecurity;
import org.springframework.security.config.annotation.web.configuration.EnableWebSecurity;
import org.springframework.security.config.annotation.web.configurers.HeadersConfigurer;
import org.springframework.security.web.SecurityFilterChain;

@Slf4j
@Configuration
@Profile("local")
@EnableWebSecurity
@EnableMethodSecurity // This enables @PreAuthorize support across the application
@RequiredArgsConstructor
public class H2ConsoleConfig {

    private final SecurityCommons securityCommons;

    @Bean
    public SecurityFilterChain securityFilterChain(HttpSecurity http,
                                                   JwtAuthenticationFilter jwtAuthFilter) throws Exception {
        return securityCommons.applyCommonSecurity(http, jwtAuthFilter)
                .headers(headers -> headers
                        .frameOptions(HeadersConfigurer.FrameOptionsConfig::disable)
                )
                .authorizeHttpRequests(auth -> {
                    // 1. Specific rule for H2
                    auth.requestMatchers("/h2-console/**").permitAll();

                    // 2. Your common rules (from the Customizer)
                    securityCommons.authRules().customize(auth);
                })
                .build();
    }

    @Bean
    public ServletRegistrationBean<HttpServlet> h2ConsoleServletRegistration() {
        try {
            // H2 Servlet supports Jakarta in newer versions
            Class<?> clazz = Class.forName("org.h2.server.web.JakartaWebServlet");
            HttpServlet servlet = (HttpServlet) clazz.getDeclaredConstructor().newInstance();
            return new ServletRegistrationBean<>(servlet, "/h2-console/*");
        } catch (Exception e) {
            log.error("Could not register H2 console servlet", e);
            throw new RuntimeException("Could not register H2 console servlet", e);
        }
    }
}
