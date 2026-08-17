package com.reuven.auth.controller;

import com.reuven.auth.dto.AuthResponse;
import com.reuven.auth.dto.LoginRequest;
import com.reuven.auth.exception.AuthErrorCodes;
import com.reuven.auth.exception.InactiveTenantException;
import com.reuven.auth.exception.UnknownTenantAddressException;
import com.reuven.auth.service.AuthService;
import com.reuven.auth.service.CookieUtil;
import com.reuven.auth.service.JwtProvider;
import com.reuven.auth.service.RefreshTokenService;
import com.reuven.auth.service.RotationResult;
import com.reuven.auth.service.TenantResolution;
import com.reuven.auth.service.TenantResolutionService;
import com.reuven.auth.util.Sha256;
import com.reuven.ratelimit.RateLimited;
import com.reuven.ratelimit.RateLimiterEngine;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import jakarta.validation.Valid;
import lombok.RequiredArgsConstructor;
import org.springframework.http.HttpHeaders;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseCookie;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;

import java.util.UUID;

@RestController
@RequestMapping("/api/v1/auth")
@RequiredArgsConstructor
public class AuthController {

    private final AuthService authService;
    private final RefreshTokenService refreshTokenService;
    private final JwtProvider jwtProvider;
    private final CookieUtil cookieUtil;
    private final RateLimiterEngine rateLimiterEngine;
    private final TenantResolutionService tenantResolutionService;

    /**
     * The tenant comes from the address this request was made to, and from nothing else - there is
     * no header, body field, query parameter, or path segment a caller can use to name one.
     * <p>
     * Resolution runs <em>after</em> the rate-limit dimensions above (an unresolvable address must
     * not be a way to bypass throttling) and <em>before</em> any credential lookup. The ordering is
     * what guarantees FR-006: with no tenant, there is nothing to guess with, so no login can be
     * attributed to a default. Both failures are distinct from {@code 401} because they call for a
     * different action from the person seeing them - check the address, not the password.
     */
    @PostMapping("/login")
    @RateLimited(limit = "login-ip", key = "T(com.reuven.ratelimit.ClientIpResolver).resolve(#httpRequest)")
    @RateLimited(limit = "login-username", key = "#request.username()?.toLowerCase()")
    public AuthResponse login(
            @Valid @RequestBody LoginRequest request,
            HttpServletRequest httpRequest,
            HttpServletResponse httpResponse) {

        TenantResolution resolution = tenantResolutionService.resolve(httpRequest);
        UUID tenantId = switch (resolution.status()) {
            case RECOGNIZED -> resolution.tenantId();
            case INACTIVE -> throw new InactiveTenantException(
                    "Login attempted for a tenant that is not active");
            case UNKNOWN -> throw new UnknownTenantAddressException(
                    "Request address does not resolve to a tenant");
        };

        AuthService.LoginResult result = authService.login(request, tenantId);
        ResponseCookie cookie = cookieUtil.buildRefreshCookie(result.rawRefreshToken());

        httpResponse.addHeader(HttpHeaders.SET_COOKIE, cookie.toString());
        return result.body();
    }

    /**
     * Reads the refresh token from its httpOnly cookie only - never from a request
     * body or header, so it's never accidentally logged, cached, or exposed to JS.
     * On success, both the access token (response body) and a rotated refresh
     * cookie are returned.
     */
    @PostMapping("/refresh")
    @RateLimited(limit = "refresh-ip", key = "T(com.reuven.ratelimit.ClientIpResolver).resolve(#httpRequest)")
    public AuthResponse refresh(
            @CookieValue(name = CookieUtil.REFRESH_COOKIE_NAME, required = false) String refreshToken,
            HttpServletRequest httpRequest,
            HttpServletResponse httpResponse) {

        if (refreshToken == null || refreshToken.isBlank()) {
            ResponseCookie expired = cookieUtil.buildExpiredCookie();
            httpResponse.setStatus(HttpServletResponse.SC_UNAUTHORIZED);
            httpResponse.addHeader(HttpHeaders.SET_COOKIE, expired.toString());
            return new AuthResponse(null, null, AuthErrorCodes.INVALID_REFRESH_TOKEN);
        }

        // Can't be a static @RateLimited: there's nothing to hash until we know the
        // cookie is present, so the aspect has no key to evaluate up front. Explicit
        // call to the same engine every declarative check ultimately reaches - the
        // aspect stays a dumb, generic gate rather than growing an "is this endpoint
        // special" branch.
        rateLimiterEngine.consume("refresh-token", Sha256.hash(refreshToken));

        RotationResult rotation = refreshTokenService.rotate(refreshToken);
        String accessToken = jwtProvider.generateToken(rotation.userId(), rotation.tenantId(), rotation.username(), rotation.roles());
        ResponseCookie cookie = cookieUtil.buildRefreshCookie(rotation.rawRefreshToken());

        httpResponse.addHeader(HttpHeaders.SET_COOKIE, cookie.toString());
        return new AuthResponse(rotation.userId(), accessToken);
    }

    @PostMapping("/logout")
    @ResponseStatus(HttpStatus.NO_CONTENT)
    public void logout(
            @CookieValue(name = CookieUtil.REFRESH_COOKIE_NAME, required = false) String refreshToken,
            HttpServletResponse response) {

        if (refreshToken != null && !refreshToken.isBlank()) {
            refreshTokenService.logout(refreshToken);
        }
        response.addHeader(HttpHeaders.SET_COOKIE, cookieUtil.buildExpiredCookie().toString());
    }

}
