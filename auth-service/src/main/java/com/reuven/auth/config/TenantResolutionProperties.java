package com.reuven.auth.config;

import org.springframework.boot.context.properties.ConfigurationProperties;

import java.util.List;
import java.util.Locale;

/**
 * Per-environment inputs to tenant resolution that are not shared with the browser origin policy.
 * <p>
 * {@code reservedIdentifiers} is the platform word list an operator may not claim at
 * provisioning time. It deliberately lives in configuration rather than in
 * {@code reserved_tenant_identifiers}: those rows are per-tenant allocations, while these are
 * a policy that differs per environment and must be changeable without a data migration.
 * <p>
 * The controlled base-domain allow-list itself - the host suffix a request must end with, on a
 * label boundary, for the single label in front of it to be treated as a Tenant URL Identifier -
 * has moved to {@code browser-edge-starter}'s {@code ControlledDomainProperties}, since the
 * origin-pattern validator in {@code BrowserEdgeAutoConfiguration} reads the same list. See that
 * module rather than this record for base-domain configuration.
 * <p>
 * Lowercased on binding, so configuration casing can never let a reserved word through in a
 * different case.
 */
@ConfigurationProperties(prefix = "hydra.tenant")
public record TenantResolutionProperties(List<String> reservedIdentifiers) {

    public TenantResolutionProperties {
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
