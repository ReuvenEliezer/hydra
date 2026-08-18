package com.reuven.auth.config;

import com.reuven.auth.service.TenantHostParser;
import com.reuven.browseredge.ControlledDomainProperties;
import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.springframework.boot.context.properties.EnableConfigurationProperties;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

/**
 * Wires tenant resolution's configuration surface, mirroring
 * {@link com.reuven.browseredge.BrowserEdgeAutoConfiguration}: this service has no
 * {@code @ConfigurationPropertiesScan}, so a {@code @ConfigurationProperties} record that
 * nothing explicitly enables binds to nothing at all - and because an empty base-domain list
 * fails closed by design, that omission would look exactly like "no host resolves", with no
 * error anywhere to point at it.
 * <p>
 * The base-domain list itself comes from {@link ControlledDomainProperties}, owned by
 * {@code browser-edge-starter} and shared with origin-pattern validation, so tenant resolution
 * and the CORS policy read one list from one owner.
 * <p>
 * Building {@link TenantHostParser} here rather than annotating it {@code @Component} is what
 * keeps the parser a plain object over a {@code List<String>} - unit-testable on raw strings
 * with no Spring context (see {@code TenantHostParserTest}).
 */
@Slf4j
@Configuration
@RequiredArgsConstructor
@EnableConfigurationProperties(TenantResolutionProperties.class)
public class TenantResolutionConfig {

    private final ControlledDomainProperties controlledDomainProperties;

    @Bean
    public TenantHostParser tenantHostParser() {
        if (controlledDomainProperties.baseDomains().isEmpty()) {
            log.warn("hydra.tenant.base-domains is empty - every address will resolve to 'unknown' and no login can succeed");
        } else {
            log.info("Tenant resolution enabled for base domains {}", controlledDomainProperties.baseDomains());
        }
        return new TenantHostParser(controlledDomainProperties.baseDomains());
    }
}
