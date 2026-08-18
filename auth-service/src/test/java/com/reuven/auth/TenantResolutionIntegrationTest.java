package com.reuven.auth;

import com.reuven.auth.entity.EntityStatus;
import com.reuven.auth.entity.Tenant;
import com.reuven.ratelimit.RateLimitErrorCodes;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;
import org.springframework.http.HttpHeaders;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.web.servlet.MvcResult;

import java.util.regex.Pattern;

import static org.assertj.core.api.Assertions.assertThat;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.header;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

/**
 * The public lookup the sign-in page calls on load, driven end to end through the real
 * security chain, resolution service, and serializer.
 * <p>
 * {@code MockHttpServletRequest} derives {@code getServerName()} from a {@code Host} header when
 * one is set, so setting {@code Host} here exercises exactly the path a browser takes.
 */
@DisplayName("Public tenant resolution lookup")
class TenantResolutionIntegrationTest extends BaseIntegrationTest {

    static final String TENANT_URL = "/api/v1/tenant";

    /**
     * SC-006's assertion made mechanical: no state of this response may contain anything
     * UUID-shaped, so the check is against the raw serialized body rather than named fields -
     * a UUID added under a new field name would still be caught.
     */
    static final Pattern UUID_SHAPED = Pattern.compile(
            "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}");

    private static final int RESOLVE_CAPACITY = 3;

    @DynamicPropertySource
    static void rateLimitProperties(DynamicPropertyRegistry registry) {
        registry.add("rate-limit.enabled", () -> "true");
        registry.add("rate-limit.limits.tenant-resolve-ip.capacity", () -> String.valueOf(RESOLVE_CAPACITY));
        registry.add("rate-limit.limits.tenant-resolve-ip.window", () -> "PT1M");
    }

    @BeforeEach
    protected void setUp() throws Exception {
        super.setUp();
        testTenant = tenantRepository.save(new Tenant("Acme Corp", "acme", EntityStatus.ACTIVE));
    }

    @Test
    @DisplayName("an active tenant's address resolves to recognized, with the organization's name")
    void activeTenantAddress_returnsRecognized() throws Exception {
        mockMvc.perform(get(TENANT_URL).header(HttpHeaders.HOST, "acme.localhost"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.status").value("recognized"))
                .andExpect(jsonPath("$.displayName").value("Acme Corp"));
    }

    @Test
    @DisplayName("the recognized body carries no tenant UUID and no field beyond status/displayName")
    void recognizedBody_carriesNoUuidAndNothingElse() throws Exception {
        String body = resolveBody("acme.localhost");

        assertThat(UUID_SHAPED.matcher(body).find())
                .as("public lookup body must never contain a tenant UUID: %s", body)
                .isFalse();
        assertThat(body).doesNotContain(testTenant.getId().toString());
        // Exactly the two authorized fields - anything else is a new thing the browser could
        // read, and the contract says there is nothing else to read.
        assertThat(body).isEqualTo("{\"status\":\"recognized\",\"displayName\":\"Acme Corp\"}");
    }

    @Test
    @DisplayName("the address is matched case-insensitively and ignoring a trailing dot or port")
    void addressMatching_ignoresCasePortAndTrailingDot() throws Exception {
        for (String host : new String[]{"ACME.localhost", "acme.localhost.", "Acme.LocalHost:5173"}) {
            mockMvc.perform(get(TENANT_URL).header(HttpHeaders.HOST, host))
                    .andExpect(status().isOk())
                    .andExpect(jsonPath("$.status").value("recognized"))
                    .andExpect(jsonPath("$.displayName").value("Acme Corp"));
        }
    }

    @Test
    @DisplayName("the lookup needs no authentication - the page calls it before anyone has credentials")
    void lookupIsPublic() throws Exception {
        mockMvc.perform(get(TENANT_URL).header(HttpHeaders.HOST, "acme.localhost"))
                .andExpect(status().isOk());
    }

    @Test
    @DisplayName("exceeding the per-IP limit returns 429 with Retry-After")
    void exceedingPerIpLimit_returns429() throws Exception {
        for (int i = 0; i < RESOLVE_CAPACITY; i++) {
            mockMvc.perform(get(TENANT_URL).header(HttpHeaders.HOST, "acme.localhost"))
                    .andExpect(status().isOk());
        }

        MvcResult result = mockMvc.perform(get(TENANT_URL).header(HttpHeaders.HOST, "acme.localhost"))
                .andExpect(status().isTooManyRequests())
                .andExpect(header().exists(HttpHeaders.RETRY_AFTER))
                .andExpect(jsonPath("$.error").value(RateLimitErrorCodes.RATE_LIMIT_EXCEEDED))
                .andReturn();

        assertThat(Integer.parseInt(result.getResponse().getHeader(HttpHeaders.RETRY_AFTER))).isPositive();
    }

    // ---- Non-recognized outcomes (US3) ----------------------------------------------

    @ParameterizedTest(name = "[{index}] Host \"{0}\" resolves to unknown")
    @ValueSource(strings = {
            "nosuch.localhost",       // well-formed label, no tenant claims it
            "localhost",              // bare base domain - no label to be a tenant
            "a.b.localhost",          // two labels - not an address this system issues
            "acme.evil.com",          // right label, unconfigured base domain
            "-acme.localhost",        // not a valid DNS label
    })
    @DisplayName("addresses that name no tenant")
    void unresolvableAddresses_returnUnknown(String host) throws Exception {
        mockMvc.perform(get(TENANT_URL).header(HttpHeaders.HOST, host))
                // 200, not 404: the status IS the payload. A 404 would collide with
                // ResourceNotFoundException and read as "no such endpoint".
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.status").value("unknown"))
                .andExpect(jsonPath("$.displayName").doesNotExist());
    }

    @Test
    @DisplayName("a non-ACTIVE tenant resolves to inactive, and its name is NOT disclosed")
    void inactiveTenant_returnsInactiveWithoutDisplayName() throws Exception {
        testTenant.setStatus(EntityStatus.SUSPENDED);
        tenantRepository.save(testTenant);

        String body = resolveBody("acme.localhost");

        // The name is authorized only at an address that actually works (FR-014). An
        // inactive organization's name is not this endpoint's to hand out anonymously.
        assertThat(body).isEqualTo("{\"status\":\"inactive\"}");
    }

    @Test
    @DisplayName("no state of the response contains a UUID")
    void noStateLeaksAUuid() throws Exception {
        String recognized = resolveBody("acme.localhost");

        testTenant.setStatus(EntityStatus.ARCHIVED);
        tenantRepository.save(testTenant);
        String inactive = resolveBody("acme.localhost");

        String unknown = resolveBody("nosuch.localhost");

        for (String body : new String[]{recognized, inactive, unknown}) {
            assertThat(UUID_SHAPED.matcher(body).find())
                    .as("body must contain no UUID-shaped string: %s", body)
                    .isFalse();
        }
    }

    String resolveBody(String host) throws Exception {
        return mockMvc.perform(get(TENANT_URL).header(HttpHeaders.HOST, host))
                .andExpect(status().isOk())
                .andReturn()
                .getResponse()
                .getContentAsString();
    }
}
