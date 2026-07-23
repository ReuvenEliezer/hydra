package com.reuven.auth.service;

import com.reuven.Role;

import java.util.List;
import java.util.UUID;

/**
 * Result of a successful {@link RefreshTokenService#rotate} call - either a brand-new
 * rotation, or an idempotent replay of an in-flight grace-window rotation (see
 * RefreshTokenService for why those two cases must return identical token material).
 */
public record RotationResult(String rawRefreshToken, UUID userId, UUID tenantId, List<Role> roles) {
}
