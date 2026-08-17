package com.reuven.auth.service;

import java.util.List;
import java.util.Locale;
import java.util.Optional;
import java.util.regex.Pattern;

/**
 * Extracts a Tenant URL Identifier from a request's {@code Host} header (FR-015).
 * <p>
 * A plain object over a list of base domains, with no Spring types: the whole resolution rule is
 * a string transformation, so it is testable on raw strings with no servlet and no application
 * context (see {@code TenantHostParserTest}). The bean is built in
 * {@code TenantResolutionConfig}.
 * <p>
 * Every step below can only ever narrow the result. An empty {@link Optional} means the address
 * names no tenant, which callers turn into {@code unknown} - never into a default or guessed
 * tenant (FR-006).
 */
public class TenantHostParser {

    /** RFC 1123 DNS label: lowercase alphanumerics and inner hyphens, no leading or trailing hyphen. */
    public static final Pattern IDENTIFIER_PATTERN = Pattern.compile("^[a-z0-9]([a-z0-9-]*[a-z0-9])?$");

    private static final int MAX_IDENTIFIER_LENGTH = 63;

    private final List<String> baseDomains;

    public TenantHostParser(List<String> baseDomains) {
        this.baseDomains = List.copyOf(baseDomains);
    }

    public Optional<String> extractIdentifier(String hostHeader) {
        if (hostHeader == null || hostHeader.isBlank()) {
            return Optional.empty();
        }

        String host = stripPort(hostHeader.trim().toLowerCase(Locale.ROOT));
        // One trailing dot is the fully-qualified form of the same name (`acme.localhost.`), not
        // a different address, so it is stripped rather than rejected.
        if (host.endsWith(".")) {
            host = host.substring(0, host.length() - 1);
        }
        if (host.isEmpty()) {
            return Optional.empty();
        }

        for (String baseDomain : baseDomains) {
            // The label boundary is what stops base domain `acme.example.com` from matching
            // `xacme.example.com`, which is a different name owned by someone else entirely.
            String suffix = "." + baseDomain;
            if (!host.endsWith(suffix)) {
                continue;
            }
            String prefix = host.substring(0, host.length() - suffix.length());
            // Exactly one label may precede the base domain. Zero (the bare base domain) names no
            // tenant; two or more (`a.b.hydra.example.com`) is not an address this system issues,
            // and treating its last label as the tenant would resolve names we never handed out.
            if (prefix.isEmpty() || prefix.indexOf('.') >= 0) {
                continue;
            }
            if (prefix.length() > MAX_IDENTIFIER_LENGTH || !IDENTIFIER_PATTERN.matcher(prefix).matches()) {
                continue;
            }
            return Optional.of(prefix);
        }
        return Optional.empty();
    }

    /**
     * Removes the port, including the bracketed IPv6 authority form {@code [::1]:8083}. A
     * bracketed literal is returned as an empty host: it can never end with a base domain, and
     * letting the brackets through would only produce a label that fails the pattern anyway -
     * being explicit here keeps that outcome intentional rather than incidental.
     */
    private static String stripPort(String host) {
        if (host.startsWith("[")) {
            return "";
        }
        int colon = host.indexOf(':');
        return colon >= 0 ? host.substring(0, colon) : host;
    }
}
