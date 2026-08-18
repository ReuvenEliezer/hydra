package com.reuven.auth.exception;

/**
 * The address a request was made to names no tenant, so there is nothing to authenticate against.
 * <p>
 * Raised before any credential lookup, which is what guarantees no login can be attributed to a
 * guessed or default tenant (FR-006). Handled as {@code 400} with
 * {@link AuthErrorCodes#UNKNOWN_TENANT_ADDRESS} - deliberately not {@code 401}, because the
 * problem is the address, not the credentials, and telling the user otherwise sends them to
 * re-type a password that was never read (FR-004).
 */
public class UnknownTenantAddressException extends RuntimeException {

    public UnknownTenantAddressException(String message) {
        super(message);
    }
}
