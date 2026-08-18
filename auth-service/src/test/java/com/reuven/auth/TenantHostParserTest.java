package com.reuven.auth;

import com.reuven.auth.service.TenantHostParser;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.CsvSource;
import org.junit.jupiter.params.provider.NullAndEmptySource;
import org.junit.jupiter.params.provider.ValueSource;

import java.util.List;
import java.util.Optional;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * The resolution rule (FR-015) as a table. No Spring context and no servlet: the parser is a
 * plain object over a list of base domains precisely so its every boundary can be pinned here
 * rather than inferred from an integration test that only exercises the happy path.
 */
class TenantHostParserTest {

    private static final TenantHostParser PARSER =
            new TenantHostParser(List.of("localhost", "hydra.example.com"));

    @ParameterizedTest(name = "[{index}] Host \"{0}\" resolves to \"{1}\"")
    @CsvSource({
            "acme.localhost,             acme",
            "acme.hydra.example.com,     acme",
            // Case and port are not part of the address's identity, so neither may change the answer.
            "ACME.LocalHost:5173,        acme",
            "ACME.HYDRA.EXAMPLE.COM,     acme",
            // A single trailing dot is the fully-qualified form of the same name.
            "acme.localhost.,            acme",
            "acme.localhost.:8083,       acme",
            // Any single label in front of a CONFIGURED base domain is a candidate identifier -
            // this one exists to make the boundary explicit against the `acme.evil.com` case below.
            "notacme.localhost,          notacme",
            "a1-b2.localhost,            a1-b2",
    })
    @DisplayName("hosts that name a tenant")
    void extractsIdentifier(String host, String expected) {
        assertThat(PARSER.extractIdentifier(host)).contains(expected);
    }

    @ParameterizedTest(name = "[{index}] Host \"{0}\" names no tenant")
    @ValueSource(strings = {
            // Bare base domain: no label to be a tenant.
            "localhost",
            "hydra.example.com",
            "localhost:8083",
            // Two or more labels: not an address this system issues.
            "a.b.hydra.example.com",
            "a.b.localhost",
            // Unconfigured base domain - the label-boundary match must not reach outside the list.
            "acme.evil.com",
            "acme.hydra.example.com.evil.com",
            // Suffix match without a label boundary: a different name owned by someone else.
            "xhydra.example.com",
            // Bare IP addresses, v4 and the bracketed v6 authority form.
            "127.0.0.1:8083",
            "127.0.0.1",
            "[::1]:8083",
            "[::1]",
            // Labels that are not valid RFC 1123 DNS labels.
            "-acme.localhost",
            "acme-.localhost",
            "acme_corp.localhost",
            "  ",
    })
    @DisplayName("hosts that resolve to unknown")
    void rejectsHost(String host) {
        assertThat(PARSER.extractIdentifier(host)).isEmpty();
    }

    @ParameterizedTest
    @NullAndEmptySource
    @DisplayName("an absent Host resolves to unknown rather than throwing")
    void rejectsAbsentHost(String host) {
        assertThat(PARSER.extractIdentifier(host)).isEmpty();
    }

    @Test
    @DisplayName("an empty base-domain list fails closed - no host resolves")
    void emptyBaseDomainsResolvesNothing() {
        TenantHostParser parser = new TenantHostParser(List.of());

        assertThat(parser.extractIdentifier("acme.localhost")).isEmpty();
    }

    @Test
    @DisplayName("a label longer than the 63-character DNS limit names no tenant")
    void rejectsOverlongLabel() {
        String label = "a".repeat(64);

        Optional<String> result = PARSER.extractIdentifier(label + ".localhost");

        assertThat(result).isEmpty();
    }
}
