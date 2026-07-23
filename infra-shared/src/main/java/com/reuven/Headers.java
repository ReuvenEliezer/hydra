package com.reuven;

/**
 * Custom HTTP header names that are part of the API contract between
 * auth-service and its callers (including other services and integration
 * tests). Kept here rather than hand-typed at each call site, the same
 * reasoning as {@link JwtClaimNames}: this string crosses module boundaries
 * (auth-service's controller, its own tests, and integration-tests), so a
 * rename anywhere needs the compiler to catch every other spot.
 */
public final class Headers {

    public static final String TENANT_ID = "X-Tenant-ID";

    private Headers() {}
}
