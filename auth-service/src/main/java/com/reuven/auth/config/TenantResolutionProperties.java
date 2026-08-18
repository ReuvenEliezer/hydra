package com.reuven.auth.config;

import org.springframework.boot.context.properties.ConfigurationProperties;

import java.util.List;
import java.util.Locale;

/**
 * Per-environment inputs to tenant resolution from the request {@code Host} header.
 * <p>
 * {@code baseDomains} is the allow-list a host must end with, on a label boundary, for the
 * single label in front of it to be treated as a Tenant URL Identifier ({@code localhost}
 * locally, {@code hydra.example.com} in production). An empty list fails closed - every host
 * resolves to {@code unknown} - matching {@link CorsProperties}' posture rather than guessing
 * a default tenant.
 * <p>
 * {@code reservedIdentifiers} is the platform word list an operator may not claim at
 * provisioning time. It deliberately lives in configuration rather than in
 * {@code reserved_tenant_identifiers}: those rows are per-tenant allocations, while these are
 * a policy that differs per environment and must be changeable without a data migration.
 * <p>
 * Both lists are lowercased on binding, so configuration casing can never cause a resolution
 * miss or let a reserved word through in a different case.
 */
@ConfigurationProperties(prefix = "hydra.tenant")
public record TenantResolutionProperties(List<String> baseDomains, List<String> reservedIdentifiers) {

    public TenantResolutionProperties {
        baseDomains = normalize(baseDomains);
        reservedIdentifiers = normalize(reservedIdentifiers);
    }

    private static List<String> normalize(List<String> values) {
        return values == null
                ? List.of()
                : values.stream()
                .filter(value -> value != null && !value.isBlank())
                .map(value -> value.trim().toLowerCase(Locale.ROOT))
                .toList();
    }
}
