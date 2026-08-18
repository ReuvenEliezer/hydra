package com.reuven.integration.edge;

import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Tag;
import org.junit.jupiter.api.Test;
import org.testcontainers.Testcontainers;
import org.testcontainers.containers.GenericContainer;

import java.util.List;

import static com.reuven.integration.edge.EdgeConformanceFixture.ORIGIN;
import static com.reuven.integration.edge.EdgeConformanceFixture.RECOGNIZED_TENANT_HOST;
import static com.reuven.integration.edge.EdgeConformanceFixture.SECOND_RECOGNIZED_TENANT_HOST;

/**
 * Executes the [transparent-edge contract](../../../../../../../../specs/002-cors-edge-hardening/contracts/transparent-edge-contract.md)
 * against a base URL, defaulting to the transparent nginx stand-in from {@link StandInProxies}.
 * <p>
 * Pointing this at a real candidate edge instead - {@code -Dedge.base-url=https://your-edge} -
 * requires zero new test code (SC-010): stand up the edge in front of the auth-service instance
 * this class starts (its port is logged at startup as {@code local.server.port}), or, more
 * practically, run this suite's own in-process service behind the real edge under test and pass
 * its externally-reachable URL.
 */
@Tag("edge-conformance")
@DisplayName("Transparent edge: all five clauses pass")
class TransparentEdgeConformanceTest {

    private static EdgeConformanceFixture fixture;
    private static GenericContainer<?> transparentEdge;
    private static String baseUrl;

    @BeforeAll
    static void startFixtureAndEdge() {
        fixture = EdgeConformanceFixture.start();

        String override = System.getProperty("edge.base-url");
        if (override != null && !override.isBlank()) {
            baseUrl = override;
            return;
        }

        Testcontainers.exposeHostPorts(fixture.authPort);
        transparentEdge = StandInProxies.transparent(fixture.authPort);
        transparentEdge.start();
        baseUrl = "http://" + transparentEdge.getHost() + ":" + transparentEdge.getMappedPort(80);
    }

    @AfterAll
    static void stopFixtureAndEdge() {
        if (transparentEdge != null) {
            transparentEdge.stop();
        }
        if (fixture != null) {
            fixture.stop();
        }
    }

    @Test
    @DisplayName("Clause 1: Host reaches the service unmodified, so a known tenant resolves")
    void hostIsPreserved() throws Exception {
        EdgeConformanceAssertions.assertHostPreserved(baseUrl, RECOGNIZED_TENANT_HOST, "recognized");
    }

    @Test
    @DisplayName("Clause 2 / FR-009: exactly one Access-Control-Allow-Origin, echoing the caller")
    void exactlyOneCorsHeaderEchoingOrigin() throws Exception {
        EdgeConformanceAssertions.assertExactlyOneCorsHeaderEchoingOrigin(baseUrl, RECOGNIZED_TENANT_HOST, ORIGIN);
    }

    @Test
    @DisplayName("Clause 3: an unauthenticated OPTIONS preflight is never 401")
    void preflightNeverUnauthorized() throws Exception {
        EdgeConformanceAssertions.assertPreflightNeverUnauthorized(baseUrl, RECOGNIZED_TENANT_HOST, ORIGIN);
    }

    @Test
    @DisplayName("Clause 1 addendum: X-Forwarded-Host is never honoured as a substitute for Host")
    void forwardedHostIsNotHonoured() throws Exception {
        EdgeConformanceAssertions.assertForwardedHostNotHonoured(baseUrl, "unclaimed.localhost", RECOGNIZED_TENANT_HOST);
    }

    @Test
    @DisplayName("FR-008: a disallowed-origin CORS rejection is distinguishable from an auth failure")
    void disallowedOriginRejectionIsNotConfusedWithAuthFailure() throws Exception {
        EdgeConformanceAssertions.assertDisallowedOriginRejectionIsNot401(baseUrl, RECOGNIZED_TENANT_HOST, "http://evil.example.com");
    }

    @Test
    @DisplayName("Clause 5: a second tenant resolves through the same edge with zero new configuration")
    void noPerTenantConfigurationNeeded() throws Exception {
        EdgeConformanceAssertions.assertNoPerTenantConfigurationNeeded(
                baseUrl, List.of(RECOGNIZED_TENANT_HOST, SECOND_RECOGNIZED_TENANT_HOST), "recognized");
    }
}
