package com.reuven.ratelimit;

import jakarta.servlet.http.HttpServletRequest;

/**
 * Resolves the "real" client IP for rate-limiting purposes.
 *
 * <p>Honors {@code X-Forwarded-For} (the first, left-most address - the original client,
 * per RFC 7239 / de-facto convention) when present, falling back to
 * {@link HttpServletRequest#getRemoteAddr()} for direct connections. Assumes a reverse
 * proxy/load balancer sits in front of every service and either sets or strips/overwrites
 * this header itself.
 */
public final class ClientIpResolver {

    public static final String X_FORWARDED_FOR = "X-Forwarded-For";

    public static String resolve(HttpServletRequest request) {
        String forwarded = request.getHeader(X_FORWARDED_FOR);
        if (forwarded != null && !forwarded.isBlank()) {
            return forwarded.split(",")[0].trim();
        }
        return request.getRemoteAddr();
    }

    private ClientIpResolver() {}
}
