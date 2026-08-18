package com.reuven.browseredge;

import org.junit.jupiter.api.Test;
import org.springframework.boot.autoconfigure.AutoConfigurations;
import org.springframework.boot.test.context.runner.ApplicationContextRunner;
import org.springframework.web.cors.CorsConfigurationSource;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * The four startup outcomes of data-model.md &sect;4. Each assertion runs a real
 * {@code ApplicationContext} refresh, since the validation under test happens in the bean factory
 * method and would not be exercised by unit-testing {@link OriginPatternValidator} alone.
 */
class BrowserEdgeAutoConfigurationTest {

    private final ApplicationContextRunner contextRunner = new ApplicationContextRunner()
            .withConfiguration(AutoConfigurations.of(BrowserEdgeAutoConfiguration.class));

    @Test
    void validConfigRefreshes() {
        contextRunner
                .withPropertyValues(
                        "hydra.cors.allowed-origin-patterns=https://*.hydra.example.com",
                        "hydra.tenant.base-domains=hydra.example.com")
                .run(context -> assertThat(context).hasSingleBean(CorsConfigurationSource.class));
    }

    @Test
    void emptyPatternListRefreshesWithWarning() {
        contextRunner
                .withPropertyValues("hydra.tenant.base-domains=hydra.example.com")
                .run(context -> assertThat(context).hasSingleBean(CorsConfigurationSource.class));
    }

    @Test
    void overBroadPatternFailsRefreshNamingThePattern() {
        contextRunner
                .withPropertyValues(
                        "hydra.cors.allowed-origin-patterns=https://*.evil.com",
                        "hydra.tenant.base-domains=hydra.example.com")
                .run(context -> assertThat(context).hasFailed()
                        .getFailure()
                        .rootCause()
                        .isInstanceOf(InvalidOriginPolicyException.class)
                        .hasMessageContaining("*.evil.com"));
    }

    @Test
    void publicSuffixBaseDomainFailsRefreshNamingTheDomain() {
        contextRunner
                .withPropertyValues(
                        "hydra.cors.allowed-origin-patterns=https://*.com",
                        "hydra.tenant.base-domains=com")
                .run(context -> assertThat(context).hasFailed()
                        .getFailure()
                        .rootCause()
                        .isInstanceOf(InvalidOriginPolicyException.class)
                        .hasMessageContaining("com"));
    }
}
