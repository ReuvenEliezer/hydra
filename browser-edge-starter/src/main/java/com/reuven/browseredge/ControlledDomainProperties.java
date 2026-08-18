package com.reuven.browseredge;

import org.springframework.boot.context.properties.ConfigurationProperties;

import java.util.List;
import java.util.Locale;

/**
 * The controlled tenant-domain set: the allow-list a request {@code Host} must end with, on a
 * label boundary, for the single label in front of it to be treated as a Tenant URL Identifier
 * ({@code localhost} locally, {@code hydra.example.com} in production).
 * <p>
 * Shared by tenant resolution (auth-service's {@code TenantHostParser}) and origin-pattern
 * validation ({@link OriginPatternValidator}) in this module, so both concerns read one list from
 * one owner - the drift that duplication would otherwise invite is structurally impossible rather
 * than merely discouraged.
 * <p>
 * Normalized on binding (trim, blank-filter, lowercase with {@link Locale#ROOT}) so configuration
 * casing can never cause a resolution miss. An empty list is legal and fails closed - every host
 * resolves to {@code unknown}, and every origin pattern is invalid.
 */
@ConfigurationProperties(prefix = "hydra.tenant")
public record ControlledDomainProperties(List<String> baseDomains) {

    public ControlledDomainProperties {
        baseDomains = normalize(baseDomains);
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
