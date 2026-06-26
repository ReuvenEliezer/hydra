package com.reuven.auth.service;

import com.reuven.auth.dto.CustomUserDetails;
import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.security.web.authentication.WebAuthenticationDetailsSource;
import org.springframework.stereotype.Component;
import org.springframework.web.filter.OncePerRequestFilter;

import java.io.IOException;

@Slf4j
@Component
@RequiredArgsConstructor
public class JwtAuthenticationFilter extends OncePerRequestFilter {

    private final JwtProvider jwtProvider;
    // We will use the specific class so we can call loadUserById
    private final CustomUserDetailsService userDetailsService;

    @Override
    protected void doFilterInternal(HttpServletRequest request,
                                    HttpServletResponse response,
                                    FilterChain filterChain) throws ServletException, IOException {

        String header = request.getHeader("Authorization");

        if (header != null && header.startsWith("Bearer ")) {
            String token = header.substring(7);
            try {
                // 1. Extract data from the token
                String publicUserId = jwtProvider.extractSubject(token);
                if (publicUserId != null && SecurityContextHolder.getContext().getAuthentication() == null) {

                    // 2. Load user details from the DB
                    CustomUserDetails userDetails = userDetailsService.loadUserByUsername(publicUserId);

                    // 3. Security: Ensure the tenant in the token matches the tenant in the DB
                    // For Super Admin, the tenantId in the token might be null/empty
                    String tokenTenantId = jwtProvider.extractTenantId(token);
                    if (tokenTenantId != null && !tokenTenantId.equals(userDetails.getTenantId().toString())) {
                        throw new SecurityException("Tenant mismatch detected!");
                    }

                    // 4. Create an Authentication object with our CustomUserDetails
                    UsernamePasswordAuthenticationToken authentication =
                            new UsernamePasswordAuthenticationToken(
                                    userDetails,
                                    null,
                                    userDetails.getAuthorities()
                            );

                    authentication.setDetails(new WebAuthenticationDetailsSource().buildDetails(request));
                    SecurityContextHolder.getContext().setAuthentication(authentication);
                }
            } catch (SecurityException e) {
                log.warn("JWT validation failed: {}", e.getMessage());
                response.sendError(HttpServletResponse.SC_UNAUTHORIZED, "Invalid or expired token");
                return;
            } catch (Exception e) {
                log.error("Unexpected error in JWT filter", e);
                response.sendError(HttpServletResponse.SC_UNAUTHORIZED, "Authentication error");
                return;
            }
        }

        filterChain.doFilter(request, response);
    }
}