package com.reuven.auth.controller;

import com.reuven.Headers;
import com.reuven.auth.dto.AuthResponse;
import com.reuven.auth.dto.LoginRequest;
import com.reuven.auth.exception.AuthErrorCodes;
import com.reuven.auth.ratelimit.ClientIpResolver;
import com.reuven.auth.ratelimit.RateLimiter;
import com.reuven.auth.service.AuthService;
import com.reuven.auth.service.CookieUtil;
import com.reuven.auth.service.JwtProvider;
import com.reuven.auth.service.RefreshTokenService;
import com.reuven.auth.service.RotationResult;
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
    private final RateLimiter rateLimiter;

    @PostMapping("/login")
    public ResponseEntity<AuthResponse> login(
            @RequestHeader(Headers.TENANT_ID) UUID tenantId,
            @Valid @RequestBody LoginRequest request,
            HttpServletRequest httpRequest) {

        rateLimiter.checkLoginIp(ClientIpResolver.resolve(httpRequest));
        rateLimiter.checkLoginUsername(request.username());

        AuthService.LoginResult result = authService.login(request, tenantId);
        ResponseCookie cookie = cookieUtil.buildRefreshCookie(result.rawRefreshToken());

        return ResponseEntity.ok()
                .header(HttpHeaders.SET_COOKIE, cookie.toString())
                .body(result.body());
    }

    /**
     * Reads the refresh token from its httpOnly cookie only - never from a request
     * body or header, so it's never accidentally logged, cached, or exposed to JS.
     * On success, both the access token (response body) and a rotated refresh
     * cookie are returned.
     */
    @PostMapping("/refresh")
    public ResponseEntity<AuthResponse> refresh(
            @CookieValue(name = CookieUtil.REFRESH_COOKIE_NAME, required = false) String refreshToken,
            HttpServletRequest httpRequest) {

        rateLimiter.checkRefreshIp(ClientIpResolver.resolve(httpRequest));

        if (refreshToken == null || refreshToken.isBlank()) {
            return unauthorizedClearingCookie(AuthErrorCodes.INVALID_REFRESH_TOKEN);
        }

        rateLimiter.checkRefreshToken(refreshToken);

        RotationResult rotation = refreshTokenService.rotate(refreshToken);
        String accessToken = jwtProvider.generateToken(rotation.userId(), rotation.tenantId(), rotation.roles());
        ResponseCookie cookie = cookieUtil.buildRefreshCookie(rotation.rawRefreshToken());

        return ResponseEntity.ok()
                .header(HttpHeaders.SET_COOKIE, cookie.toString())
                .body(new AuthResponse(rotation.userId(), accessToken));
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

    private ResponseEntity<AuthResponse> unauthorizedClearingCookie(String errorCode) {
        ResponseCookie expired = cookieUtil.buildExpiredCookie();
        return ResponseEntity.status(HttpStatus.UNAUTHORIZED)
                .header(HttpHeaders.SET_COOKIE, expired.toString())
                .body(new AuthResponse(null, null, errorCode));
    }
}
