package com.reuven.auth.config;

import com.reuven.auth.service.JwtAuthenticationFilter;
import lombok.RequiredArgsConstructor;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.context.annotation.Profile;
import org.springframework.security.authentication.AuthenticationManager;
import org.springframework.security.authentication.ProviderManager;
import org.springframework.security.authentication.dao.DaoAuthenticationProvider;
import org.springframework.security.config.annotation.method.configuration.EnableMethodSecurity;
import org.springframework.security.config.annotation.web.builders.HttpSecurity;
import org.springframework.security.config.annotation.web.configuration.EnableWebSecurity;
import org.springframework.security.core.userdetails.UserDetailsService;
import org.springframework.security.crypto.bcrypt.BCryptPasswordEncoder;
import org.springframework.security.crypto.password.PasswordEncoder;
import org.springframework.security.web.SecurityFilterChain;

@Configuration
@EnableWebSecurity
@EnableMethodSecurity // This enables @PreAuthorize support across the application
@RequiredArgsConstructor
public class SecurityConfig {

    private final SecurityCommons securityCommons;

    @Bean
    @Profile("!local")
    public SecurityFilterChain securityFilterChain(HttpSecurity http,
                                                   JwtAuthenticationFilter jwtAuthFilter) throws Exception {
        return securityCommons.applyCommonSecurity(http, jwtAuthFilter)
                .authorizeHttpRequests(securityCommons.authRules())
                .build();
    }

    /**
     * Exposes a DaoAuthenticationProvider-backed AuthenticationManager as a bean.
     *
     * The login flow in {@link com.reuven.auth.service.AuthService} deliberately does NOT
     * delegate to this bean: the multi-tenant lookup requires tenantId as a parameter
     * ({@code findWithRolesByTenantIdAndUsername(tenantId, username)}), which
     * {@link org.springframework.security.core.userdetails.UserDetailsService#loadUserByUsername}
     * cannot accommodate without a thread-local hack.
     *
     * This bean exists for:
     * 1. Spring Security test utilities ({@code @WithMockUser}, MockMvc security slices)
     * 2. Future non-tenant auth providers (service-to-service, admin CLI)
     * 3. Method-security tests that need a real AuthenticationManager wired in
     */
//    @Bean
//    public AuthenticationManager authenticationManager(UserDetailsService userDetailsService,
//                                                       PasswordEncoder passwordEncoder) {
//        DaoAuthenticationProvider provider = new DaoAuthenticationProvider(userDetailsService);
////        provider.setUserDetailsPasswordService(userDetailsService);
//        provider.setPasswordEncoder(passwordEncoder);
//        return new ProviderManager(provider);
//    }

    @Bean
    public PasswordEncoder passwordEncoder() {
        return new BCryptPasswordEncoder(12);
    }
}
