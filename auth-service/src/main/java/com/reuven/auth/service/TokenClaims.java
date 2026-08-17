package com.reuven.auth.service;

import com.reuven.Role;

import java.util.List;
import java.util.UUID;

/**
 * Typed value object extracted from a validated JWT.
 * Keeps nimbus-jose types isolated inside JwtProvider — nothing outside
 * the service package needs to import JWTClaimsSet.
 */
public record TokenClaims(UUID userId, UUID tenantId, String username, List<Role> roles) {}
