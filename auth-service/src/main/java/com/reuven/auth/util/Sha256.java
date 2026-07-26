package com.reuven.auth.util;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.Base64;

/**
 * SHA-256 + URL-safe-Base64 hashing, used wherever a secret (a refresh token) needs to
 * be turned into a stable, non-reversible identifier - as a Redis key, never logged or
 * stored in its raw form. One implementation shared by {@code RefreshTokenService} and
 * {@code AuthController} (before handing the hash to {@code RateLimiterEngine.consume})
 * rather than each hand-rolling the same digest+encode logic.
 */
public final class Sha256 {

    public static String hash(String value) {
        try {
            MessageDigest digest = MessageDigest.getInstance("SHA-256");
            byte[] hash = digest.digest(value.getBytes(StandardCharsets.UTF_8));
            return Base64.getUrlEncoder().withoutPadding().encodeToString(hash);
        } catch (NoSuchAlgorithmException e) {
            throw new IllegalStateException("SHA-256 not available", e);
        }
    }

    private Sha256() {}
}
