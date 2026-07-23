package com.reuven.auth.exception;

/**
 * Machine-readable error codes returned in {@link ErrorResponse#message()} for the
 * refresh-token flow specifically. Two different code paths need to agree on the same
 * code for the same logical failure: {@code AuthController} returns one directly when
 * the refresh cookie is missing entirely (never reaches the service layer), while
 * {@link GlobalExceptionHandler} returns the other when {@code RefreshTokenService}
 * throws for a present-but-invalid token. A client distinguishing these cases by
 * string needs both call sites to agree, so both reference these constants instead
 * of each hand-typing the string.
 */
public final class AuthErrorCodes {

    public static final String INVALID_REFRESH_TOKEN = "invalid_refresh_token";
    public static final String REFRESH_TOKEN_REUSE_DETECTED = "refresh_token_reuse_detected";

    private AuthErrorCodes() {}
}
