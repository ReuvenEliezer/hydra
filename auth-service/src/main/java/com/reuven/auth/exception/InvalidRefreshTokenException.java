package com.reuven.auth.exception;

/**
 * Presented refresh token doesn't exist in the active set and isn't within
 * its grace-window replay either. Distinct from {@link RefreshTokenReuseException}:
 * this is "never valid / fully expired", not "valid once, presented twice".
 */
public class InvalidRefreshTokenException extends RuntimeException {
    public InvalidRefreshTokenException(String message) {
        super(message);
    }
}
