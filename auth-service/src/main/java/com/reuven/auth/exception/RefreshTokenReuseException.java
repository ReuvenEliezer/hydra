package com.reuven.auth.exception;

/**
 * A refresh token that was already rotated away (and is outside the grace window)
 * was presented again. Per RFC 6749 best practices, this revokes the entire token
 * family - the rest of the rotation chain is now considered compromised.
 */
public class RefreshTokenReuseException extends RuntimeException {
    public RefreshTokenReuseException(String message) {
        super(message);
    }
}
