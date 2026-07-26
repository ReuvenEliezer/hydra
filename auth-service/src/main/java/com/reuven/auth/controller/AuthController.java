package com.reuven.auth.controller;

import com.reuven.Headers;
import com.reuven.auth.dto.AuthResponse;
import com.reuven.auth.dto.LoginRequest;
import com.reuven.auth.exception.AuthErrorCodes;
import com.reuven.auth.service.AuthService;
import com.reuven.auth.service.CookieUtil;
import com.reuven.auth.service.JwtProvider;
import com.reuven.auth.service.RefreshTokenService;
import com.reuven.auth.service.RotationResult;
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

    @PostMapping("/login")
    @RateLimited(limit = "login-ip", key = "T(com.reuven.ratelimit.ClientIpResolver).resolve(#httpRequest)")
    @RateLimited(limit = "login-username", key = "#request.username()?.toLowerCase()")
    public AuthResponse login(
            @RequestHeader(Headers.TENANT_ID) UUID tenantId,
            @Valid @RequestBody LoginRequest request,
            HttpServletRequest httpRequest,
            HttpServletResponse httpResponse) {

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
        String accessToken = jwtProvider.generateToken(rotation.userId(), rotation.tenantId(), rotation.roles());
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
