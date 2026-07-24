package com.reuven.auth.service;

import com.reuven.auth.dto.CustomUserDetails;
import com.reuven.auth.exception.InvalidTokenException;
import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.springframework.http.HttpHeaders;
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

    private static final String BEARER_PREFIX = "Bearer ";

    private final JwtProvider jwtProvider;

    /**
     * Validates the Bearer token and populates the SecurityContext entirely from
     * JWT claims — zero DB calls on the hot path. The token's RS256 signature
     * already guarantees that userId/tenantId/roles haven't been tampered with,
     * so there is no value in re-loading the user from the DB on every request.
     *
     * If a DB round-trip is needed for a specific endpoint (e.g. to check account
     * lock status), that logic belongs in the endpoint's own service layer, not here.
     */
    @Override
    protected void doFilterInternal(HttpServletRequest request,
                                    HttpServletResponse response,
                                    FilterChain filterChain) throws ServletException, IOException {

        String header = request.getHeader(HttpHeaders.AUTHORIZATION);

        if (header == null || !header.startsWith(BEARER_PREFIX)) {
            filterChain.doFilter(request, response);
            return;
        }

        String token = header.substring(BEARER_PREFIX.length());
        try {
            if (SecurityContextHolder.getContext().getAuthentication() == null) {
                //Security: Ensure the tenant in the token matches the tenant in the DB
                // For Super Admin, the tenantId in the token might be null/empty

                TokenClaims claims = jwtProvider.extractTokenClaims(token);
                // Load user details from the DB -
                /**
                 * Option 1: Load user details from the database on every request.
                 *
                 * Pros:
                 *   - Always uses the latest user state (roles, permissions, account status).
                 *   - No cache invalidation complexity.
                 *
                 * Cons:
                 *   - Additional database call on every authenticated request.
                 *   - Higher latency and database load.
                 *
                 * Option 2: Reconstruct the user from JWT claims (current implementation).
                 *
                 * Pros:
                 *   - No database lookup.
                 *   - Lowest latency and scales well.
                 *
                 * Cons:
                 *   - User changes (roles, account disabled, etc.) are not reflected until the JWT expires.
                 *   - JWT must contain all required information.
                 *
                 * Option 3: Cache user details in memory (e.g. Caffeine).
                 *
                 * Pros:
                 *   - Significantly reduces database load while allowing periodic refresh.
                 *   - Faster than querying the database on every request.
                 *
                 * Cons:
                 *   - Cache invalidation/expiration must be handled correctly.
                 *   - Changes are not reflected immediately unless the cache is explicitly evicted.
                 */
//                CustomUserDetails userDetails = userDetailsService.loadUserByUsername(publicUserId);
                CustomUserDetails userDetails = CustomUserDetails.fromTokenClaims(claims);

                //Create an Authentication object with our CustomUserDetails
                UsernamePasswordAuthenticationToken authentication =
                        new UsernamePasswordAuthenticationToken(
                                userDetails,
                                null,
                                userDetails.getAuthorities()
                        );
                authentication.setDetails(new WebAuthenticationDetailsSource().buildDetails(request));
                SecurityContextHolder.getContext().setAuthentication(authentication);
            }
        } catch (InvalidTokenException e) {
            log.warn("JWT validation failed for request [{}]: {}", request.getRequestURI(), e.getMessage());
            response.sendError(HttpServletResponse.SC_UNAUTHORIZED, "Invalid or expired token");
            return;
        }

        filterChain.doFilter(request, response);
    }
}
