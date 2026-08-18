package com.reuven.auth.exception;

/**
 * The address names a real tenant, but that tenant is not {@code ACTIVE}.
 * <p>
 * Handled as {@code 403} with {@link AuthErrorCodes#TENANT_INACTIVE}, which separates "we know
 * which organization you mean, and it is switched off" from both an unrecognized address
 * ({@code 400}) and wrong credentials ({@code 401}). All three are distinct on purpose: they call
 * for three different actions from the person seeing them (FR-005).
 */
public class InactiveTenantException extends RuntimeException {

    public InactiveTenantException(String message) {
        super(message);
    }
}
