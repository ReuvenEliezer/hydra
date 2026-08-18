package com.reuven.integration.edge;

import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Tag;
import org.junit.jupiter.api.Test;
import org.testcontainers.Testcontainers;
import org.testcontainers.containers.GenericContainer;

import static com.reuven.integration.edge.EdgeConformanceFixture.ORIGIN;
import static com.reuven.integration.edge.EdgeConformanceFixture.RECOGNIZED_TENANT_HOST;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

/**
 * Runs the same clause assertions {@link TransparentEdgeConformanceTest} runs, against the
 * deliberately hostile stand-in, and requires them to FAIL (research R5, SC-009).
 * <p>
 * This is not redundant polish: a conformance suite that only ever meets a correct edge cannot
 * distinguish "the edge is transparent" from "the assertions no longer work", and would keep
 * passing forever after a refactor silently broke it. If either test below stops failing, the
 * conformance suite itself has a defect.
 */
@Tag("edge-conformance")
@DisplayName("Hostile edge: the suite detects and fails on each violation")
class HostileEdgeDetectionTest {

    private static EdgeConformanceFixture fixture;
    private static GenericContainer<?> hostileEdge;
    private static String baseUrl;

    @BeforeAll
    static void startFixtureAndHostileEdge() {
        fixture = EdgeConformanceFixture.start();

        Testcontainers.exposeHostPorts(fixture.authPort);
        hostileEdge = StandInProxies.hostile(fixture.authPort);
        hostileEdge.start();
        baseUrl = "http://" + hostileEdge.getHost() + ":" + hostileEdge.getMappedPort(80);
    }

    @AfterAll
    static void stopFixtureAndHostileEdge() {
        if (hostileEdge != null) {
            hostileEdge.stop();
        }
        if (fixture != null) {
            fixture.stop();
        }
    }

    @Test
    @DisplayName("Clause 1 violation is caught: a rewritten Host makes every tenant resolve to unknown")
    void hostRewriteIsDetected() {
        assertThatThrownBy(() ->
                EdgeConformanceAssertions.assertHostPreserved(baseUrl, RECOGNIZED_TENANT_HOST, "recognized"))
                .isInstanceOf(AssertionError.class);
    }

    @Test
    @DisplayName("Clause 2 violation is caught: the edge's injected header duplicates the service's own")
    void injectedCorsHeaderIsDetected() {
        assertThatThrownBy(() ->
                EdgeConformanceAssertions.assertExactlyOneCorsHeaderEchoingOrigin(baseUrl, RECOGNIZED_TENANT_HOST, ORIGIN))
                .isInstanceOf(AssertionError.class);
    }
}
