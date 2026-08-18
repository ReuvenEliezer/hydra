package com.reuven.auth.exception;

/**
 * Machine-readable error codes returned in {@link com.reuven.ErrorResponse#message()}, for the
 * failures a client must be able to tell apart programmatically rather than by reading prose.
 * <p>
 * Two different code paths often need to agree on the same code for the same logical failure:
 * {@code AuthController} returns {@link #INVALID_REFRESH_TOKEN} directly when the refresh cookie
 * is missing entirely (never reaching the service layer), while {@link GlobalExceptionHandler}
 * returns the same code when {@code RefreshTokenService} throws for a present-but-invalid token.
 * A client distinguishing these cases by string needs both call sites to agree, so both reference
 * these constants instead of each hand-typing the string.
 * <p>
 * The tenant codes exist for the same reason from the other direction: {@code @hydra/ui} maps
 * each to its own message, and collapsing either into "invalid credentials" would tell a user at
 * an address that does not resolve to go check their password.
 */
public final class AuthErrorCodes {

    public static final String INVALID_REFRESH_TOKEN = "invalid_refresh_token";
    public static final String REFRESH_TOKEN_REUSE_DETECTED = "refresh_token_reuse_detected";

    /** The request's {@code Host} names no tenant. Distinct from bad credentials (FR-004). */
    public static final String UNKNOWN_TENANT_ADDRESS = "unknown_tenant_address";

    /** The request's {@code Host} names a tenant that is not {@code ACTIVE} (FR-005). */
    public static final String TENANT_INACTIVE = "tenant_inactive";

    private AuthErrorCodes() {}
}
