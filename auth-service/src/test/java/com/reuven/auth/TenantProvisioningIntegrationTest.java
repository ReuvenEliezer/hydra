package com.reuven.auth;

import com.reuven.Role;
import com.reuven.auth.dto.AuthResponse;
import com.reuven.auth.dto.CreateTenantRequest;
import com.reuven.auth.dto.LoginRequest;
import com.reuven.auth.entity.EntityStatus;
import com.reuven.auth.entity.Tenant;
import com.reuven.auth.entity.User;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.http.HttpHeaders;
import org.springframework.http.MediaType;
import org.springframework.test.web.servlet.MvcResult;
import org.springframework.test.web.servlet.ResultActions;
import org.springframework.test.web.servlet.request.MockMvcRequestBuilders;

import com.reuven.auth.repository.ReservedTenantIdentifierRepository;

import static org.assertj.core.api.Assertions.assertThat;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

/**
 * Tenant provisioning: format, reserved words, permanent uniqueness, authorization, and the
 * one property that makes the whole feature self-service - that a provisioned address works
 * immediately, with no configuration step in between.
 */
@DisplayName("Tenant provisioning")
class TenantProvisioningIntegrationTest extends BaseIntegrationTest {

    private static final String TENANTS_URL = "/api/v1/admin/tenants";

    @Autowired
    ReservedTenantIdentifierRepository reservedIdentifierRepository;

    private String superAdminToken;

    @BeforeEach
    protected void setUp() throws Exception {
        // super.setUp() already clears the reserved-identifier ledger along with users and
        // tenants, before and after every test method.
        super.setUp();

        Tenant systemTenant = tenantRepository.save(
                new Tenant("System Tenant", "system", EntityStatus.ACTIVE));
        superAdmin = userRepository.save(new User(systemTenant, "super-admin",
                passwordEncoder.encode(SUPER_ADMIN_PASSWORD), Role.SUPER_ADMIN, EntityStatus.ACTIVE));

        testTenant = tenantRepository.save(new Tenant("Acme Corp", "acme", EntityStatus.ACTIVE));
        userRepository.save(new User(testTenant, "acme-admin",
                passwordEncoder.encode(ADMIN_PASSWORD), Role.ADMIN, EntityStatus.ACTIVE));

        superAdminToken = loginAs("super-admin", SUPER_ADMIN_PASSWORD, "system");
    }

    @Test
    @DisplayName("a super admin creates a tenant and gets its id, name, and address back")
    void createTenant_returns201() throws Exception {
        createTenant("Beta Industries", "beta")
                .andExpect(status().isCreated())
                .andExpect(jsonPath("$.id").isNotEmpty())
                .andExpect(jsonPath("$.name").value("Beta Industries"))
                .andExpect(jsonPath("$.urlIdentifier").value("beta"));

        assertThat(tenantRepository.findByUrlIdentifier("beta")).isPresent();
        assertThat(reservedIdentifierRepository.existsByIdentifier("beta")).isTrue();
    }

    @Test
    @DisplayName("the new address resolves immediately, with no configuration step in between")
    void createdTenant_resolvesImmediately() throws Exception {
        createTenant("Beta Industries", "beta").andExpect(status().isCreated());

        // Nothing happens between these two calls: no restart, no config edit, no cache warm.
        mockMvc.perform(get(TenantResolutionIntegrationTest.TENANT_URL)
                        .header(HttpHeaders.HOST, "beta.localhost"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.status").value("recognized"))
                .andExpect(jsonPath("$.displayName").value("Beta Industries"));
    }

    @ParameterizedTest(name = "[{index}] \"{0}\" is rejected as malformed")
    @ValueSource(strings = {
            "-bad-",        // leading and trailing hyphen
            "bad-",         // trailing hyphen
            "-bad",         // leading hyphen
            "ADMIN",        // uppercase fails the PATTERN, before the reserved check ever runs
            "Beta",         // ditto - case is not normalized into validity
            "bad_name",     // underscore is not a DNS label character
            "bad.name",     // a dot would make it two labels
            "",             // blank
    })
    @DisplayName("a malformed identifier is a 400 - a fixable typo, not a semantic conflict")
    void malformedIdentifier_returns400(String identifier) throws Exception {
        createTenant("Beta Industries", identifier).andExpect(status().isBadRequest());
    }

    @Test
    @DisplayName("a reserved platform word is a 422 - well-formed, but not the operator's to take")
    void reservedIdentifier_returns422() throws Exception {
        createTenant("Admin Corp", "admin").andExpect(status().isUnprocessableContent());

        assertThat(tenantRepository.findByUrlIdentifier("admin")).isEmpty();
    }

    @Test
    @DisplayName("an identifier already claimed by a live tenant is a 422")
    void alreadyClaimedIdentifier_returns422() throws Exception {
        createTenant("Beta Industries", "beta").andExpect(status().isCreated());

        createTenant("Beta Impostors", "beta").andExpect(status().isUnprocessableContent());

        assertThat(tenantRepository.findByUrlIdentifier("beta"))
                .get()
                .extracting(Tenant::getName)
                .isEqualTo("Beta Industries");
    }

    @Test
    @DisplayName("an identifier stays claimed FOREVER - even after its tenant is deleted")
    void claimedIdentifier_isNeverReusedEvenAfterTenantDeletion() throws Exception {
        createTenant("Beta Industries", "beta").andExpect(status().isCreated());

        // The tenant row disappears entirely - the unique constraint on tenants.url_identifier
        // no longer objects to anything. Only the reservation ledger still does.
        Tenant beta = tenantRepository.findByUrlIdentifier("beta").orElseThrow();
        tenantRepository.delete(beta);
        assertThat(tenantRepository.findByUrlIdentifier("beta")).isEmpty();

        // Whoever holds a bookmark, a saved link, or an old session for beta.localhost must
        // never land on a different organization wearing the same address.
        createTenant("Someone Else Entirely", "beta").andExpect(status().isUnprocessableContent());
    }

    @Test
    @DisplayName("a tenant admin cannot provision tenants")
    void createTenant_byNonSuperAdmin_returns403() throws Exception {
        String adminToken = loginAs("acme-admin", ADMIN_PASSWORD, "acme");

        mockMvc.perform(post(TENANTS_URL)
                        .header(HttpHeaders.AUTHORIZATION, "Bearer " + adminToken)
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("""
                                {"name":"Beta Industries","urlIdentifier":"beta"}"""))
                .andExpect(status().isForbidden());

        assertThat(tenantRepository.findByUrlIdentifier("beta")).isEmpty();
    }

    @Test
    @DisplayName("an anonymous caller cannot provision tenants")
    void createTenant_unauthenticated_isRejected() throws Exception {
        mockMvc.perform(post(TENANTS_URL)
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("""
                                {"name":"Beta Industries","urlIdentifier":"beta"}"""))
                .andExpect(status().isUnauthorized());

        assertThat(tenantRepository.findByUrlIdentifier("beta")).isEmpty();
    }

    private ResultActions createTenant(String name, String urlIdentifier) throws Exception {
        return mockMvc.perform(post(TENANTS_URL)
                .header(HttpHeaders.AUTHORIZATION, "Bearer " + superAdminToken)
                .contentType(MediaType.APPLICATION_JSON)
                .content(jsonMapper.writeValueAsString(new CreateTenantRequest(name, urlIdentifier))));
    }

    /** Signs in at {@code <urlIdentifier>.localhost}, the same address a browser would use. */
    private String loginAs(String username, String password, String urlIdentifier) throws Exception {
        MvcResult result = mockMvc.perform(MockMvcRequestBuilders.post("/api/v1/auth/login")
                        .header(HttpHeaders.HOST, urlIdentifier + ".localhost")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content(jsonMapper.writeValueAsString(new LoginRequest(username, password))))
                .andExpect(status().isOk())
                .andReturn();
        return jsonMapper.readValue(result.getResponse().getContentAsString(), AuthResponse.class).token();
    }
}
