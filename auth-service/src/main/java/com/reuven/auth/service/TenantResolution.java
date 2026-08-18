package com.reuven.auth.service;

import java.util.UUID;

/**
 * The outcome of resolving one request's {@code Host} to a tenant.
 * <p>
 * <strong>{@code tenantId} is internal-only.</strong> It exists here because {@code AuthService}
 * needs a tenant to look a user up in, and it is stripped at the web boundary: the public
 * {@code GET /api/v1/tenant} response has no field that could carry it, in any state. That
 * asymmetry - internal type carries the UUID, public DTO cannot - is the mechanism behind SC-006,
 * so adding a UUID-bearing field to {@code TenantResolutionResponse} would defeat it.
 * <p>
 * {@code displayName} is likewise carried in every non-unknown state internally, but is published
 * only on {@link Status#RECOGNIZED} - FR-014 authorizes showing the organization's name at an
 * address that actually works, not at one that is switched off.
 */
public record TenantResolution(Status status, UUID tenantId, String displayName) {

    public enum Status {
        /** Identifier extracted, tenant found, status {@code ACTIVE}. */
        RECOGNIZED,
        /** Tenant found at this address, but it is not {@code ACTIVE}. */
        INACTIVE,
        /** No identifier in the host, or no tenant claiming it. */
        UNKNOWN
    }

    public static TenantResolution recognized(UUID tenantId, String displayName) {
        return new TenantResolution(Status.RECOGNIZED, tenantId, displayName);
    }

    public static TenantResolution inactive(UUID tenantId, String displayName) {
        return new TenantResolution(Status.INACTIVE, tenantId, displayName);
    }

    public static TenantResolution unknown() {
        return new TenantResolution(Status.UNKNOWN, null, null);
    }

    public boolean isRecognized() {
        return status == Status.RECOGNIZED;
    }
}
