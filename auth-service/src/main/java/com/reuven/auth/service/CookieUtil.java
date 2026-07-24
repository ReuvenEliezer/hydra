package com.reuven.auth.service;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.http.ResponseCookie;
import org.springframework.stereotype.Component;

import java.time.Duration;

/**
 * Builds the httpOnly refresh-token cookie. Path is intentionally scoped to
 * /api/v1/auth (not "/") so the cookie is never sent on ordinary API calls - only on
 * the refresh/logout requests that actually need it, minimizing its exposure surface.
 * <p>
 * {@code secure} is configurable because Secure cookies are silently dropped by
 * browsers over plain HTTP, which would break local/test runs against the HTTP
 * connector; it must be true in any real deployment (enforced via the prod profile).
 */
@Component
public class CookieUtil {

    public static final String REFRESH_COOKIE_NAME = "refresh_token";
    private static final String COOKIE_PATH = "/api/v1/auth";
    private static final String SAME_SITE_STRICT = "Strict";

    private final Duration refreshTtl;
    private final boolean secure;

    public CookieUtil(
            @Value("${refresh-token.ttl:P30D}") Duration refreshTtl,
            @Value("${refresh-token.cookie.secure:true}") boolean secure) {
        this.refreshTtl = refreshTtl;
        this.secure = secure;
    }

    public ResponseCookie buildRefreshCookie(String rawToken) {
        return ResponseCookie.from(REFRESH_COOKIE_NAME, rawToken)
                .httpOnly(true)
                .secure(secure)
                .sameSite(SAME_SITE_STRICT)
                .path(COOKIE_PATH)
                .maxAge(refreshTtl)
                .build();
    }

    /** Clears the cookie client-side (logout / invalid token responses). */
    public ResponseCookie buildExpiredCookie() {
        return ResponseCookie.from(REFRESH_COOKIE_NAME, "")
                .httpOnly(true)
                .secure(secure)
                .sameSite(SAME_SITE_STRICT)
                .path(COOKIE_PATH)
                .maxAge(0)
                .build();
    }
}
