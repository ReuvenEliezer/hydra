package com.reuven.browseredge;

import com.google.common.net.InternetDomainName;

import java.util.LinkedHashSet;
import java.util.List;
import java.util.Set;

/**
 * The controlled-domain rule (data-model.md &sect;3) and the single-registrable-domain check
 * (research R6, FR-017) behind FR-010 and FR-018.
 * <p>
 * A plain object over {@code List<String>}, constructor-injected, so it is unit-testable with no
 * Spring context - the same pattern {@code TenantHostParser} uses. Base domains are validated
 * once, at construction; individual origin patterns are validated on demand via
 * {@link #validateOriginPattern(String)}, since they come from a different configuration key and
 * fail independently.
 */
public class OriginPatternValidator {

    private final List<String> baseDomains;

    public OriginPatternValidator(List<String> baseDomains) {
        validateBaseDomains(baseDomains);
        this.baseDomains = List.copyOf(baseDomains);
    }

    /**
     * @throws InvalidOriginPolicyException if the pattern is not an exact match or single-label
     *                                       wildcard match of a configured base domain
     */
    public void validateOriginPattern(String pattern) {
        if (!isValid(pattern)) {
            throw new InvalidOriginPolicyException(
                    "hydra.cors.allowed-origin-patterns contains '" + pattern
                            + "', which is not a controlled domain under hydra.tenant.base-domains " + baseDomains
                            + " - it must exactly match a configured base domain, or be a single-label wildcard "
                            + "of one (e.g. https://*.hydra.example.com)");
        }
    }

    private boolean isValid(String pattern) {
        if (pattern == null || pattern.isBlank()) {
            return false;
        }
        String host = stripSchemeAndPort(pattern);
        if (host.equals("*")) {
            return false;
        }
        if (host.startsWith("*.")) {
            String remainder = host.substring(2);
            return !remainder.isEmpty() && !remainder.contains("*") && baseDomains.contains(remainder);
        }
        return baseDomains.contains(host);
    }

    private static String stripSchemeAndPort(String pattern) {
        String host = pattern;
        int schemeIndex = host.indexOf("://");
        if (schemeIndex >= 0) {
            host = host.substring(schemeIndex + 3);
        }
        int slashIndex = host.indexOf('/');
        if (slashIndex >= 0) {
            host = host.substring(0, slashIndex);
        }
        int colonIndex = host.indexOf(':');
        if (colonIndex >= 0) {
            host = host.substring(0, colonIndex);
        }
        return host;
    }

    /**
     * Rejects a base domain that is itself a public suffix (FR-018) - checked with Guava rather
     * than a label-count rule, because {@code localhost} is a legitimate single-label base domain
     * (research R3) - and rejects a set of base domains spanning more than one registrable domain
     * (FR-017, research R6): every individual origin pattern can be valid under FR-010 while the
     * pairing is still genuinely cross-site.
     */
    private static void validateBaseDomains(List<String> baseDomains) {
        Set<String> registrableDomains = new LinkedHashSet<>();
        for (String baseDomain : baseDomains) {
            InternetDomainName domainName = InternetDomainName.from(baseDomain);
            if (domainName.isPublicSuffix()) {
                throw new InvalidOriginPolicyException(
                        "hydra.tenant.base-domains contains '" + baseDomain
                                + "', which is a public suffix - declaring it as a controlled base domain "
                                + "would authorize an arbitrarily broad set of origins");
            }
            registrableDomains.add(registrableDomainOf(domainName, baseDomain));
        }
        if (registrableDomains.size() > 1) {
            throw new InvalidOriginPolicyException(
                    "hydra.tenant.base-domains " + baseDomains
                            + " span more than one registrable domain (" + registrableDomains
                            + ") - only a single-registrable-domain deployment is supported, "
                            + "since a page under one and an API under another would be genuinely cross-site");
        }
    }

    private static String registrableDomainOf(InternetDomainName domainName, String baseDomain) {
        return domainName.isUnderPublicSuffix() ? domainName.topPrivateDomain().toString() : baseDomain;
    }
}
