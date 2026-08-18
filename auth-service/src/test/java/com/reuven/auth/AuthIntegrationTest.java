package com.reuven.auth;

import com.reuven.auth.dto.AuthResponse;
import com.reuven.auth.dto.LoginRequest;
import com.reuven.auth.dto.RegisterRequest;
import com.reuven.auth.entity.EntityStatus;
import com.reuven.auth.entity.Tenant;
import com.reuven.auth.entity.User;
import com.reuven.JwtClaimNames;
import com.reuven.Role;
import com.reuven.auth.service.JwtProvider;
import com.nimbusds.jwt.SignedJWT;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.http.HttpHeaders;
import org.springframework.http.MediaType;
import org.springframework.test.web.servlet.MvcResult;
import org.springframework.test.web.servlet.request.MockMvcRequestBuilders;
import org.springframework.test.web.servlet.result.MockMvcResultMatchers;

import java.time.Clock;
import java.time.Duration;
import java.time.Instant;
import java.time.ZoneOffset;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

@DisplayName("Auth Integration Tests")
class AuthIntegrationTest extends BaseIntegrationTest {

    // JwtProvider and KeyProvider are autowired on the base class. We only need the
    // issuer/key-id values directly here, to build a second JwtProvider below that
    // shares the same key material but runs on a Clock.fixed(...) in the past - that's
    // what lets us mint a deterministically-expired token without depending on
    // tokenValidityDuration's exact magnitude (see expiredToken_returns401).

    @Value("${jwt.issuer:hydra-auth-service}")
    String issuer;

    @Value("${jwt.key-id:hydra-auth-key-1}")
    String keyId;

    @Value("${jwt.expiration-duration:PT1H}")
    Duration tokenValidityDuration;
    private String adminToken;


    @BeforeEach
    protected void setUp() throws Exception {
        super.setUp();
        Tenant systemTenant = new Tenant("System Tenant", "system", EntityStatus.ACTIVE);
        tenantRepository.save(systemTenant);
        superAdmin = new User(systemTenant, "super-admin",
                passwordEncoder.encode(SUPER_ADMIN_PASSWORD), Role.SUPER_ADMIN, EntityStatus.ACTIVE);
        userRepository.save(superAdmin);

        testTenant = new Tenant("Acme Corp", "acme", EntityStatus.ACTIVE);
        tenantRepository.save(testTenant);
        userRepository.save(new User(testTenant, "acme-admin", passwordEncoder.encode(ADMIN_PASSWORD), Role.ADMIN, EntityStatus.ACTIVE));
        adminToken = loginAs("acme-admin", ADMIN_PASSWORD, testTenant.getUrlIdentifier());
    }


    @Test
    @DisplayName("Expired token is rejected with 401 when used against a protected endpoint")
    void expiredToken_returns401() throws Exception {
        // "now" minus the full validity window minus one more minute -> exp always lands
        // exactly one minute in the past, regardless of how long tokenValidityDuration is.
        Clock oneMinuteAgoClock = Clock.fixed(
                Instant.now().minus(tokenValidityDuration).minus(Duration.ofMinutes(1)),
                ZoneOffset.UTC);
        JwtProvider expiredTokenProvider =
                new JwtProvider(keyProvider, oneMinuteAgoClock, issuer, keyId, tokenValidityDuration);

        String expiredToken = expiredTokenProvider.generateToken(superAdmin);

        mockMvc.perform(post("/api/v1/admin/{tenantId}/register-admin", testTenant.getId())
                        .header(HttpHeaders.AUTHORIZATION, "Bearer " + expiredToken)
                        .contentType(MediaType.APPLICATION_JSON)
                        .content(jsonMapper.writeValueAsString(new RegisterRequest("ghost-admin", ADMIN_PASSWORD))))
                .andExpect(status().isUnauthorized());
    }

    @Test
    @DisplayName("Malformed bearer token is rejected with 401, not 500")
    void malformedToken_returns401() throws Exception {
        mockMvc.perform(post("/api/v1/admin/{tenantId}/register-admin", testTenant.getId())
                        .header(HttpHeaders.AUTHORIZATION, "Bearer not-a-real-jwt")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content(jsonMapper.writeValueAsString(new RegisterRequest("ghost-admin", ADMIN_PASSWORD))))
                .andExpect(status().isUnauthorized());
    }


    @Test
    @DisplayName("Super admin can login")
    void superAdminLogin_success() throws Exception {
        var loginRequest = new LoginRequest("super-admin", SUPER_ADMIN_PASSWORD);
        mockMvc.perform(post("/api/v1/auth/login")
                        .header(HttpHeaders.HOST, superAdmin.getTenant().getUrlIdentifier() + ".localhost")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content(jsonMapper.writeValueAsString(loginRequest)))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.token").isNotEmpty());
    }

    @Test
    @DisplayName("Wrong password returns 401, not 500")
    void login_wrongPassword_returns401() throws Exception {
        var loginRequest = new LoginRequest("super-admin", "totally-wrong-password");
        mockMvc.perform(post("/api/v1/auth/login")
                        .header(HttpHeaders.HOST, superAdmin.getTenant().getUrlIdentifier() + ".localhost")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content(jsonMapper.writeValueAsString(loginRequest)))
                .andExpect(status().isUnauthorized());
    }

    @Test
    @DisplayName("Unknown username returns 401, not a 'user not found' message (no enumeration)")
    void login_unknownUser_returns401() throws Exception {
        var loginRequest = new LoginRequest("nobody-by-this-name", "irrelevant-password");
        mockMvc.perform(post("/api/v1/auth/login")
                        .header(HttpHeaders.HOST, superAdmin.getTenant().getUrlIdentifier() + ".localhost")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content(jsonMapper.writeValueAsString(loginRequest)))
                .andExpect(status().isUnauthorized())
                .andExpect(jsonPath("$.message").value("Invalid credentials"));
    }

    @Test
    @DisplayName("Correct username/password at another tenant's address returns 401")
    void login_correctCredentialsWrongTenant_returns401() throws Exception {
        // super-admin exists under the System tenant, so acme.localhost must not authenticate them
        var loginRequest = new LoginRequest("super-admin", SUPER_ADMIN_PASSWORD);
        mockMvc.perform(post("/api/v1/auth/login")
                        .header(HttpHeaders.HOST, testTenant.getUrlIdentifier() + ".localhost")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content(jsonMapper.writeValueAsString(loginRequest)))
                .andExpect(status().isUnauthorized());
    }

    // ---- Tenant resolution on the login path (US2, US3) -----------------------------

    @Test
    @DisplayName("A super admin's token carries their OWN tenant, resolved from their own address")
    void superAdminLogin_atSystemAddress_carriesSystemTenantClaim() throws Exception {
        String token = loginAs("super-admin", SUPER_ADMIN_PASSWORD, "system");

        SignedJWT jwt = SignedJWT.parse(token);
        String tenantClaim = jwt.getJWTClaimsSet().getStringClaim(JwtClaimNames.TENANT_ID);

        assertThat(tenantClaim).isEqualTo(superAdmin.getTenant().getId().toString());
    }

    @Test
    @DisplayName("A super admin's credentials do NOT authenticate at another tenant's address")
    void superAdminLogin_atAnotherTenantsAddress_returns401() throws Exception {
        // Resolution is strictly per-address and is never bypassed by role. A super admin's
        // cross-tenant AUTHORITY is a post-login concern; where they may SIGN IN is not.
        mockMvc.perform(post("/api/v1/auth/login")
                        .header(HttpHeaders.HOST, "acme.localhost")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content(jsonMapper.writeValueAsString(
                                new LoginRequest("super-admin", SUPER_ADMIN_PASSWORD))))
                .andExpect(status().isUnauthorized());
    }

    @Test
    @DisplayName("An address that resolves to no tenant returns 400 unknown_tenant_address, never 401")
    void login_unresolvableAddress_returns400() throws Exception {
        mockMvc.perform(post("/api/v1/auth/login")
                        .header(HttpHeaders.HOST, "nosuch.localhost")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content(jsonMapper.writeValueAsString(
                                new LoginRequest("acme-admin", ADMIN_PASSWORD))))
                .andExpect(status().isBadRequest())
                .andExpect(jsonPath("$.message").value("unknown_tenant_address"));
    }

    @Test
    @DisplayName("Valid credentials at an unresolvable address still fail closed - never attributed elsewhere")
    void login_validCredentialsAtUnknownAddress_isNeverAttributedToAnotherTenant() throws Exception {
        // The credentials below are genuinely valid FOR acme. Sent to an address that names
        // no tenant, they must not fall back to a default, a first, or a guessed tenant.
        mockMvc.perform(post("/api/v1/auth/login")
                        .header(HttpHeaders.HOST, "localhost")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content(jsonMapper.writeValueAsString(
                                new LoginRequest("acme-admin", ADMIN_PASSWORD))))
                .andExpect(status().isBadRequest())
                .andExpect(jsonPath("$.message").value("unknown_tenant_address"))
                .andExpect(jsonPath("$.token").doesNotExist());
    }

    @Test
    @DisplayName("An inactive tenant's address returns 403 tenant_inactive, distinct from both 400 and 401")
    void login_inactiveTenantAddress_returns403() throws Exception {
        testTenant.setStatus(EntityStatus.SUSPENDED);
        tenantRepository.save(testTenant);

        mockMvc.perform(post("/api/v1/auth/login")
                        .header(HttpHeaders.HOST, "acme.localhost")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content(jsonMapper.writeValueAsString(
                                new LoginRequest("acme-admin", ADMIN_PASSWORD))))
                .andExpect(status().isForbidden())
                .andExpect(jsonPath("$.message").value("tenant_inactive"));
    }

    @Test
    @DisplayName("Super admin can create tenant admin")
    void registerAdmin_bySuperAdmin_success() throws Exception {

        String superAdminToken = loginAs(
                "super-admin",
                SUPER_ADMIN_PASSWORD,
                superAdmin.getTenant().getUrlIdentifier()
        );

        String username = "admin-" + UUID.randomUUID();

        mockMvc.perform(post("/api/v1/admin/{tenantId}/register-admin", testTenant.getId())
                        .header(HttpHeaders.AUTHORIZATION, "Bearer " + superAdminToken)
                        .contentType(MediaType.APPLICATION_JSON)
                        .content(jsonMapper.writeValueAsString(
                                new RegisterRequest(username, ADMIN_PASSWORD)
                        )))
                .andExpect(status().isCreated());

        assertThat(userRepository.findByTenantIdAndUsername(testTenant.getId(), username))
                .isPresent();
    }


    @Test
    @DisplayName("Tenant admin (not super admin) gets 403 trying to register another admin")
    void registerAdmin_byTenantAdmin_returns403() throws Exception {
        mockMvc.perform(post("/api/v1/admin/{tenantId}/register-admin", testTenant.getId())
                        .header(HttpHeaders.AUTHORIZATION, "Bearer " + adminToken)
                        .contentType(MediaType.APPLICATION_JSON)
                        .content(jsonMapper.writeValueAsString(new RegisterRequest("another-admin", ADMIN_PASSWORD))))
                .andExpect(status().isForbidden());
    }

    @Test
    @DisplayName("No Authorization header at all returns 401, not 403")
    void registerAdmin_noToken_returns401() throws Exception {
        mockMvc.perform(post("/api/v1/admin/{tenantId}/register-admin", testTenant.getId())
                        .contentType(MediaType.APPLICATION_JSON)
                        .content(jsonMapper.writeValueAsString(new RegisterRequest("ghost-admin", ADMIN_PASSWORD))))
                .andExpect(status().isUnauthorized());
    }

    @Test
    @DisplayName("Super admin can register user")
    void registerUser_success() throws Exception {

        var request = new RegisterRequest("john.doe", USER_PASSWORD);

        mockMvc.perform(post("/api/v1/admin/register-user")
                        .header(HttpHeaders.AUTHORIZATION, "Bearer " + adminToken)
                        .contentType(MediaType.APPLICATION_JSON)
                        .content(jsonMapper.writeValueAsString(request)))
                .andExpect(status().isCreated());
    }

    @Test
    @DisplayName("User cannot register user outside their own tenant context")
    void registerUser_crossTenant_isRejected() throws Exception {

        Tenant otherTenant = new Tenant("Other Corp", "other", EntityStatus.ACTIVE);
        tenantRepository.save(otherTenant);

        String requestUsername = "intruder";

        var request = new RegisterRequest(requestUsername, USER_PASSWORD);

        mockMvc.perform(post("/api/v1/admin/register-user")
                        .header(HttpHeaders.AUTHORIZATION, "Bearer " + adminToken)
                        .contentType(MediaType.APPLICATION_JSON)
                        .content(jsonMapper.writeValueAsString(request)))
                .andExpect(status().isCreated());

        // Critical check: User is only created under the tenant of the logged-in admin
        assertThat(
                userRepository.existsByTenantIdAndUsername(otherTenant.getId(), requestUsername)
        ).isFalse();

        assertThat(
                userRepository.existsByTenantIdAndUsername(testTenant.getId(), requestUsername)
        ).isTrue();
    }

    @Test
    @DisplayName("Plain user cannot register other users")
    void registerUser_byPlainUser_returns403() throws Exception {
        userRepository.save(new User(testTenant, "regular-joe",
                passwordEncoder.encode(USER_PASSWORD), Role.USER, EntityStatus.ACTIVE));
        String userToken = loginAs("regular-joe", USER_PASSWORD, testTenant.getUrlIdentifier());

        mockMvc.perform(post("/api/v1/admin/register-user", testTenant.getId())
                        .header(HttpHeaders.AUTHORIZATION, "Bearer " + userToken)
                        .contentType(MediaType.APPLICATION_JSON)
                        .content(jsonMapper.writeValueAsString(new RegisterRequest("another-user", USER_PASSWORD))))
                .andExpect(status().isForbidden());
    }

    @Test
    @DisplayName("Duplicate username within the same tenant is rejected")
    void registerUser_duplicateUsername_returns422() throws Exception {

        var request = new RegisterRequest("john.doe", USER_PASSWORD);

        // First creation - should succeed
        mockMvc.perform(post("/api/v1/admin/register-user")
                        .header(HttpHeaders.AUTHORIZATION, "Bearer " + adminToken)
                        .contentType(MediaType.APPLICATION_JSON)
                        .content(jsonMapper.writeValueAsString(request)))
                .andExpect(status().isCreated());

        // Second attempt - should fail
        mockMvc.perform(post("/api/v1/admin/register-user")
                        .header(HttpHeaders.AUTHORIZATION, "Bearer " + adminToken)
                        .contentType(MediaType.APPLICATION_JSON)
                        .content(jsonMapper.writeValueAsString(request)))
                .andExpect(status().isUnprocessableContent());
    }

    /**
     * Signs in at {@code <urlIdentifier>.localhost}. MockHttpServletRequest derives
     * getServerName() from a Host header when one is set, so this exercises the real resolution
     * path rather than a test-only shortcut.
     */
    private String loginAs(String username, String password, String urlIdentifier) throws Exception {
        MvcResult result = mockMvc.perform(MockMvcRequestBuilders.post("/api/v1/auth/login")
                        .header(HttpHeaders.HOST, urlIdentifier + ".localhost")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content(jsonMapper.writeValueAsString(new LoginRequest(username, password))))
                .andExpect(MockMvcResultMatchers.status().isOk())
                .andReturn();
        return jsonMapper.readValue(result.getResponse().getContentAsString(), AuthResponse.class).token();
    }
}