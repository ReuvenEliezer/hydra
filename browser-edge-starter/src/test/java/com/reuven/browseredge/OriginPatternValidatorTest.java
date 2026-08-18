package com.reuven.browseredge;

import org.junit.jupiter.api.Test;

import java.util.List;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.assertj.core.api.Assertions.assertThatCode;

/**
 * Covers every row of data-model.md &sect;3, including the {@code localhost} case that must be
 * accepted and the {@code base-domains: com} case that must be rejected even though its pattern
 * is well-formed against it (research R3).
 */
class OriginPatternValidatorTest {

    @Test
    void acceptsWildcardUnderLocalhost() {
        OriginPatternValidator validator = new OriginPatternValidator(List.of("localhost"));

        assertThatCode(() -> validator.validateOriginPattern("http://*.localhost:5173"))
                .doesNotThrowAnyException();
    }

    @Test
    void acceptsWildcardUnderProductionBaseDomain() {
        OriginPatternValidator validator = new OriginPatternValidator(List.of("hydra.example.com"));

        assertThatCode(() -> validator.validateOriginPattern("https://*.hydra.example.com"))
                .doesNotThrowAnyException();
    }

    @Test
    void acceptsExactMatchWithNoWildcard() {
        OriginPatternValidator validator = new OriginPatternValidator(List.of("hydra.example.com"));

        assertThatCode(() -> validator.validateOriginPattern("https://hydra.example.com"))
                .doesNotThrowAnyException();
    }

    @Test
    void rejectsWildcardUnderUncontrolledDomain() {
        OriginPatternValidator validator = new OriginPatternValidator(List.of("hydra.example.com"));

        assertThatThrownBy(() -> validator.validateOriginPattern("https://*.evil.com"))
                .isInstanceOf(InvalidOriginPolicyException.class)
                .hasMessageContaining("*.evil.com");
    }

    @Test
    void rejectsBareWildcardMatchingAnyDomain() {
        OriginPatternValidator validator = new OriginPatternValidator(List.of("hydra.example.com"));

        assertThatThrownBy(() -> validator.validateOriginPattern("https://*"))
                .isInstanceOf(InvalidOriginPolicyException.class);
    }

    @Test
    void rejectsBaseDomainThatIsAPublicSuffix() {
        assertThatThrownBy(() -> new OriginPatternValidator(List.of("com")))
                .isInstanceOf(InvalidOriginPolicyException.class)
                .hasMessageContaining("com");
    }

    @Test
    void baseDomainThatIsAPublicSuffixIsRejectedEvenWithAWellFormedPattern() {
        // The pattern https://*.com is well-formed relative to base domain "com", so only
        // checking patterns against the list would let this configuration error authorize an
        // arbitrarily broad origin. The rejection must happen at construction, on the base
        // domain itself.
        assertThatThrownBy(() -> new OriginPatternValidator(List.of("com")))
                .isInstanceOf(InvalidOriginPolicyException.class);
    }

    @Test
    void rejectsBaseDomainsSpanningMultipleRegistrableDomains() {
        assertThatThrownBy(() -> new OriginPatternValidator(List.of("hydra.example.com", "otherapp.io")))
                .isInstanceOf(InvalidOriginPolicyException.class)
                .hasMessageContaining("hydra.example.com")
                .hasMessageContaining("otherapp.io");
    }

    @Test
    void acceptsMultipleBaseDomainsUnderTheSameRegistrableDomain() {
        assertThatCode(() -> new OriginPatternValidator(List.of("hydra.example.com", "admin.example.com")))
                .doesNotThrowAnyException();
    }

    @Test
    void emptyBaseDomainListConstructsWithoutError() {
        assertThatCode(() -> new OriginPatternValidator(List.of())).doesNotThrowAnyException();
    }
}
