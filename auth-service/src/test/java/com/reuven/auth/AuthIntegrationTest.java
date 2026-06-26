package com.reuven.auth;

import com.reuven.auth.dto.AuthResponse;
import com.reuven.auth.dto.LoginRequest;
import com.reuven.auth.dto.RegisterRequest;
import com.reuven.auth.entity.EntityStatus;
import com.reuven.auth.entity.Tenant;
import com.reuven.auth.entity.User;
import com.reuven.auth.entity.UserRole;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.http.MediaType;
import org.springframework.test.web.servlet.MvcResult;
import org.springframework.test.web.servlet.request.MockMvcRequestBuilders;
import org.springframework.test.web.servlet.result.MockMvcResultMatchers;

import java.time.Duration;
import java.util.Date;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

@DisplayName("Auth Integration Tests")
class AuthIntegrationTest extends BaseIntegrationTest {

    // JwtProvider isn't on the base class - only this test class needs it directly,
    // to mint an expired token for the token-validation tests below.

    @Value("${jwt.expiration-duration:PT1H}")
    Duration tokenValidityDuration;
    private String adminToken;


    @BeforeEach
    protected void setUp() {
        super.setUp();
        Tenant systemTenant = new Tenant("System Tenant", EntityStatus.ACTIVE);
        tenantRepository.save(systemTenant);
        superAdmin = new User(systemTenant, "super-admin",
                passwordEncoder.encode(SUPER_ADMIN_PASSWORD), UserRole.SUPER_ADMIN, EntityStatus.ACTIVE);
        userRepository.save(superAdmin);

        testTenant = new Tenant("Acme Corp", EntityStatus.ACTIVE);
        tenantRepository.save(testTenant);
        userRepository.save(new User(testTenant, "acme-admin", passwordEncoder.encode(ADMIN_PASSWORD), UserRole.ADMIN, EntityStatus.ACTIVE));
        adminToken = loginAs("acme-admin", ADMIN_PASSWORD, testTenant.getId());
    }


    @Test
    @DisplayName("Expired token is rejected with 401 when used against a protected endpoint")
    void expiredToken_returns401() throws Exception {
        String expiredToken = jwtProvider.generateToken(superAdmin,
                new Date(System.currentTimeMillis() - tokenValidityDuration.minus(Duration.ofMinutes(1)).toMillis())); // expired 1 min ago

        mockMvc.perform(post("/api/v1/tenants/{tenantId}/users/admin", testTenant.getId())
                        .header("Authorization", "Bearer " + expiredToken)
                        .contentType(MediaType.APPLICATION_JSON)
                        .content(jsonMapper.writeValueAsString(new RegisterRequest("ghost-admin", ADMIN_PASSWORD))))
                .andExpect(status().isUnauthorized());
    }

    @Test
    @DisplayName("Malformed bearer token is rejected with 401, not 500")
    void malformedToken_returns401() throws Exception {
        mockMvc.perform(post("/api/v1/tenants/{tenantId}/users/admin", testTenant.getId())
                        .header("Authorization", "Bearer not-a-real-jwt")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content(jsonMapper.writeValueAsString(new RegisterRequest("ghost-admin", ADMIN_PASSWORD))))
                .andExpect(status().isUnauthorized());
    }


    @Test
    @DisplayName("Super admin can login")
    void superAdminLogin_success() throws Exception {
        var loginRequest = new LoginRequest("super-admin", SUPER_ADMIN_PASSWORD);
        mockMvc.perform(post("/api/v1/auth/login")
                        .header("X-Tenant-ID", superAdmin.getTenant().getId().toString())
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
                        .header("X-Tenant-ID", superAdmin.getTenant().getId().toString())
                        .contentType(MediaType.APPLICATION_JSON)
                        .content(jsonMapper.writeValueAsString(loginRequest)))
                .andExpect(status().isUnauthorized());
    }

    @Test
    @DisplayName("Unknown username returns 401, not a 'user not found' message (no enumeration)")
    void login_unknownUser_returns401() throws Exception {
        var loginRequest = new LoginRequest("nobody-by-this-name", "irrelevant-password");
        mockMvc.perform(post("/api/v1/auth/login")
                        .header("X-Tenant-ID", superAdmin.getTenant().getId().toString())
                        .contentType(MediaType.APPLICATION_JSON)
                        .content(jsonMapper.writeValueAsString(loginRequest)))
                .andExpect(status().isUnauthorized())
                .andExpect(jsonPath("$.message").value("Invalid credentials"));
    }

    @Test
    @DisplayName("Correct username/password but wrong tenant header returns 401")
    void login_correctCredentialsWrongTenant_returns401() throws Exception {
        // super-admin exists under the System tenant, not testTenant
        var loginRequest = new LoginRequest("super-admin", SUPER_ADMIN_PASSWORD);
        mockMvc.perform(post("/api/v1/auth/login")
                        .header("X-Tenant-ID", testTenant.getId().toString())
                        .contentType(MediaType.APPLICATION_JSON)
                        .content(jsonMapper.writeValueAsString(loginRequest)))
                .andExpect(status().isUnauthorized());
    }

    @Test
    @DisplayName("Missing X-Tenant-ID header returns 400")
    void login_missingTenantHeader_returns400() throws Exception {
        var loginRequest = new LoginRequest("super-admin", SUPER_ADMIN_PASSWORD);
        mockMvc.perform(post("/api/v1/auth/login")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content(jsonMapper.writeValueAsString(loginRequest)))
                .andExpect(status().isBadRequest());
    }

    @Test
    @DisplayName("Super admin can create tenant admin")
    void registerAdmin_bySuperAdmin_success() throws Exception {

        String superAdminToken = loginAs(
                "super-admin",
                SUPER_ADMIN_PASSWORD,
                superAdmin.getTenant().getId()
        );

        String username = "admin-" + UUID.randomUUID();

        mockMvc.perform(post("/api/v1/admin/{tenantId}/register-admin", testTenant.getId())
                        .header("Authorization", "Bearer " + superAdminToken)
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
        mockMvc.perform(post("/api/v1/tenants/{tenantId}/users/admin", testTenant.getId())
                        .header("Authorization", "Bearer " + adminToken)
                        .contentType(MediaType.APPLICATION_JSON)
                        .content(jsonMapper.writeValueAsString(new RegisterRequest("another-admin", ADMIN_PASSWORD))))
                .andExpect(status().isForbidden());
    }

    @Test
    @DisplayName("No Authorization header at all returns 401, not 403")
    void registerAdmin_noToken_returns401() throws Exception {
        mockMvc.perform(post("/api/v1/tenants/{tenantId}/users/admin", testTenant.getId())
                        .contentType(MediaType.APPLICATION_JSON)
                        .content(jsonMapper.writeValueAsString(new RegisterRequest("ghost-admin", ADMIN_PASSWORD))))
                .andExpect(status().isUnauthorized());
    }

    @Test
    @DisplayName("Super admin can register user")
    void registerUser_success() throws Exception {

        var request = new RegisterRequest("john.doe", USER_PASSWORD);

        mockMvc.perform(post("/api/v1/admin/register-user")
                        .header("Authorization", "Bearer " + adminToken)
                        .contentType(MediaType.APPLICATION_JSON)
                        .content(jsonMapper.writeValueAsString(request)))
                .andExpect(status().isCreated());
    }

    @Test
    @DisplayName("User cannot register user outside their own tenant context")
    void registerUser_crossTenant_isRejected() throws Exception {

        Tenant otherTenant = new Tenant("Other Corp", EntityStatus.ACTIVE);
        tenantRepository.save(otherTenant);

        String requestUsername = "intruder";

        var request = new RegisterRequest(requestUsername, USER_PASSWORD);

        mockMvc.perform(post("/api/v1/admin/register-user")
                        .header("Authorization", "Bearer " + adminToken)
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
                passwordEncoder.encode(USER_PASSWORD), UserRole.USER, EntityStatus.ACTIVE));
        String userToken = loginAs("regular-joe", USER_PASSWORD, testTenant.getId());

        mockMvc.perform(post("/api/v1/tenants/{tenantId}/users/register", testTenant.getId())
                        .header("Authorization", "Bearer " + userToken)
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
                        .header("Authorization", "Bearer " + adminToken)
                        .contentType(MediaType.APPLICATION_JSON)
                        .content(jsonMapper.writeValueAsString(request)))
                .andExpect(status().isCreated());

        // Second attempt - should fail
        mockMvc.perform(post("/api/v1/admin/register-user")
                        .header("Authorization", "Bearer " + adminToken)
                        .contentType(MediaType.APPLICATION_JSON)
                        .content(jsonMapper.writeValueAsString(request)))
                .andExpect(status().isUnprocessableEntity());
    }

    private String loginAs(String username, String password, UUID tenantId) {
        try {
            MvcResult result = mockMvc.perform(MockMvcRequestBuilders.post("/api/v1/auth/login")
                            .header("X-Tenant-ID", tenantId.toString())
                            .contentType(MediaType.APPLICATION_JSON)
                            .content(jsonMapper.writeValueAsString(new LoginRequest(username, password))))
                    .andExpect(MockMvcResultMatchers.status().isOk())
                    .andReturn();
            return jsonMapper.readValue(result.getResponse().getContentAsString(), AuthResponse.class).token();
        } catch (Exception e) {
            throw new RuntimeException(e);
        }
    }
}