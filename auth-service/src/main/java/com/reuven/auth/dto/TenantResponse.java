package com.reuven.auth.dto;

import java.util.UUID;

/**
 * The result of provisioning a tenant.
 * <p>
 * This one deliberately DOES carry the tenant UUID, unlike the public
 * {@link TenantResolutionResponse}. The difference is the audience, not inconsistency: this
 * endpoint is {@code SUPER_ADMIN}-only and its caller is an operator who already works in
 * tenant UUIDs - {@code POST /api/v1/admin/{tenantId}/register-admin} is the very next call
 * they make. The UUID prohibition applies to what an anonymous browser can read, which is the
 * public lookup, not to authenticated admin surfaces.
 */
public record TenantResponse(UUID id, String name, String urlIdentifier) {
}
