package com.reuven;

/**
 * The JWT claim names auth-service (the issuer) and any consuming service
 * (order-service, and any future one) both depend on as their wire contract.
 * Previously each side hand-typed {@code "tenantId"} and {@code "roles"}
 * independently - auth-service in JwtProvider, order-service in its
 * JwtAuthenticationConverter and every controller method that reads the
 * tenant claim. Renaming a claim on the issuing side would silently break
 * every consumer with no compiler help. Both sides now reference the same
 * constant.
 */
public final class JwtClaimNames {

    public static final String TENANT_ID = "tenantId";
    public static final String ROLES = "roles";

    private JwtClaimNames() {}
}
