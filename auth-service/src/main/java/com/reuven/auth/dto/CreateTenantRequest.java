package com.reuven.auth.dto;

import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Pattern;
import jakarta.validation.constraints.Size;

/**
 * Input to tenant provisioning (FR-009).
 * <p>
 * The identifier is validated here rather than only in the service so that a malformed value
 * fails as a {@code 400} through the existing {@code MethodArgumentNotValidException} handler,
 * cleanly separated from the {@code 422} that a well-formed but unavailable identifier gets.
 * Those are different problems: one is a typo the caller can fix by editing the string, the
 * other means the string is fine but already spoken for.
 * <p>
 * The pattern is the RFC 1123 DNS label rule, and it is the SAME rule
 * {@code TenantHostParser} applies when reading a host - an identifier that could be created
 * but never parsed back out of an address would be a tenant nobody can reach.
 */
public record CreateTenantRequest(

        @NotBlank(message = "Tenant name cannot be blank")
        @Size(max = 100, message = "Tenant name cannot exceed 100 characters")
        String name,

        @NotBlank(message = "URL identifier cannot be blank")
        @Size(max = 63, message = "URL identifier cannot exceed 63 characters")
        @Pattern(
                regexp = "^[a-z0-9]([a-z0-9-]*[a-z0-9])?$",
                message = "URL identifier must be lowercase letters, digits, and hyphens, "
                        + "and cannot start or end with a hyphen")
        String urlIdentifier) {
}
