package com.reuven.integration.edge;

import org.apache.hc.client5.http.classic.methods.HttpGet;
import org.apache.hc.client5.http.classic.methods.HttpOptions;
import org.apache.hc.client5.http.impl.classic.CloseableHttpClient;
import org.apache.hc.client5.http.impl.classic.HttpClients;
import org.apache.hc.core5.http.ClassicHttpResponse;
import org.apache.hc.core5.http.Header;
import org.apache.hc.core5.http.ParseException;
import org.apache.hc.core5.http.io.entity.EntityUtils;

import java.io.IOException;
import java.util.List;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * The five clauses of [contracts/transparent-edge-contract.md](../../../../../../../../specs/002-cors-edge-hardening/contracts/transparent-edge-contract.md),
 * as reusable assertions against a base URL. {@link TransparentEdgeConformanceTest} runs these
 * expecting them to pass; {@link HostileEdgeDetectionTest} runs the same methods against the
 * hostile stand-in expecting them to fail (research R5) - a suite that only ever meets a correct
 * edge cannot distinguish "the edge is transparent" from "the assertions no longer work".
 * <p>
 * A plain HTTP client (Apache httpclient5, already a dependency of this module) is used rather
 * than {@code java.net.http.HttpClient}, which refuses to let a caller set the {@code Host}
 * header at all - exactly the header Clause 1 needs to control.
 */
final class EdgeConformanceAssertions {

    private static final String TENANT_ENDPOINT = "/api/v1/tenant";
    private static final String LOGIN_ENDPOINT = "/api/v1/auth/login";

    private EdgeConformanceAssertions() {
    }

    /**
     * Clause 1 - Preserve Host. Resolution depends entirely on the {@code Host} the service
     * observes, so a matching status is only possible if the edge forwarded it unmodified.
     */
    static void assertHostPreserved(String baseUrl, String tenantHost, String expectedStatus) throws IOException, ParseException {
        try (CloseableHttpClient client = HttpClients.createDefault()) {
            HttpGet get = new HttpGet(baseUrl + TENANT_ENDPOINT);
            get.setHeader("Host", tenantHost);
            try (ClassicHttpResponse response = client.executeOpen(null, get, null)) {
                String body = EntityUtils.toString(response.getEntity());
                assertThat(body)
                        .as("GET %s through %s with Host: %s", TENANT_ENDPOINT, baseUrl, tenantHost)
                        .contains("\"status\":\"" + expectedStatus + "\"");
            }
        }
    }

    /**
     * Clause 2 - Emit no cross-origin headers, and the echoed-origin assertion (FR-009): exactly
     * one {@code Access-Control-Allow-Origin}, naming the single requesting origin, never a
     * literal {@code *}. An edge that also emits CORS headers produces two instances of the same
     * header name, which is what a browser rejects outright.
     */
    static void assertExactlyOneCorsHeaderEchoingOrigin(String baseUrl, String tenantHost, String origin) throws IOException {
        try (CloseableHttpClient client = HttpClients.createDefault()) {
            HttpGet get = new HttpGet(baseUrl + TENANT_ENDPOINT);
            get.setHeader("Host", tenantHost);
            get.setHeader("Origin", origin);
            try (ClassicHttpResponse response = client.executeOpen(null, get, null)) {
                EntityUtils.consume(response.getEntity());
                Header[] headers = response.getHeaders("Access-Control-Allow-Origin");
                assertThat(headers)
                        .as("Access-Control-Allow-Origin header instances through %s", baseUrl)
                        .hasSize(1);
                assertThat(headers[0].getValue())
                        .as("the echoed origin must name the caller, never a literal wildcard")
                        .isEqualTo(origin)
                        .isNotEqualTo("*");
            }
        }
    }

    /**
     * Clause 3 - Pass preflight through unauthenticated: an {@code OPTIONS} preflight to a
     * credential-bearing endpoint must never answer {@code 401}, with or without an edge in the
     * path (FR-005). The service's explicit {@code OPTIONS /**} permit-all backstop is what this
     * proves survives an edge in front of it.
     */
    static void assertPreflightNeverUnauthorized(String baseUrl, String tenantHost, String origin) throws IOException {
        try (CloseableHttpClient client = HttpClients.createDefault()) {
            HttpOptions options = new HttpOptions(baseUrl + LOGIN_ENDPOINT);
            options.setHeader("Host", tenantHost);
            options.setHeader("Origin", origin);
            options.setHeader("Access-Control-Request-Method", "POST");
            try (ClassicHttpResponse response = client.executeOpen(null, options, null)) {
                EntityUtils.consume(response.getEntity());
                assertThat(response.getCode())
                        .as("unauthenticated OPTIONS preflight through %s must never be 401", baseUrl)
                        .isNotEqualTo(401);
            }
        }
    }

    /**
     * Clause 1 addendum: {@code X-Forwarded-Host} must never be honoured as a substitute for
     * {@code Host} - 003 explicitly rejected forwarded-header semantics, so a client-settable
     * header claiming a known tenant must still resolve to {@code unknown} when the real
     * {@code Host} does not name one.
     */
    static void assertForwardedHostNotHonoured(String baseUrl, String unrelatedHost, String claimedTenantHost) throws IOException, ParseException {
        try (CloseableHttpClient client = HttpClients.createDefault()) {
            HttpGet get = new HttpGet(baseUrl + TENANT_ENDPOINT);
            get.setHeader("Host", unrelatedHost);
            get.setHeader("X-Forwarded-Host", claimedTenantHost);
            try (ClassicHttpResponse response = client.executeOpen(null, get, null)) {
                String body = EntityUtils.toString(response.getEntity());
                assertThat(body)
                        .as("X-Forwarded-Host must not substitute for Host")
                        .contains("\"status\":\"unknown\"");
            }
        }
    }

    /**
     * FR-008: an origin-policy rejection must be distinguishable from an authentication or
     * authorization failure in service logs and in the response the client sees. Spring's CORS
     * processor answers a preflight from a disallowed origin with {@code 403}, never the
     * {@code 401} an unauthenticated request gets - the two failure modes must not collapse into
     * the same status.
     */
    static void assertDisallowedOriginRejectionIsNot401(String baseUrl, String tenantHost, String disallowedOrigin) throws IOException {
        try (CloseableHttpClient client = HttpClients.createDefault()) {
            HttpOptions options = new HttpOptions(baseUrl + LOGIN_ENDPOINT);
            options.setHeader("Host", tenantHost);
            options.setHeader("Origin", disallowedOrigin);
            options.setHeader("Access-Control-Request-Method", "POST");
            try (ClassicHttpResponse response = client.executeOpen(null, options, null)) {
                EntityUtils.consume(response.getEntity());
                assertThat(response.getCode())
                        .as("a disallowed-origin preflight must read as a CORS rejection, not an auth failure")
                        .isNotEqualTo(401);
            }
        }
    }

    /** Every base-domain host resolves through the same edge with zero per-tenant configuration (Clause 5). */
    static void assertNoPerTenantConfigurationNeeded(String baseUrl, List<String> tenantHosts, String expectedStatus) throws IOException, ParseException {
        for (String tenantHost : tenantHosts) {
            assertHostPreserved(baseUrl, tenantHost, expectedStatus);
        }
    }
}
