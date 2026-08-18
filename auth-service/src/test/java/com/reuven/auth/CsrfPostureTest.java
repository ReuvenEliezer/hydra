package com.reuven.auth;

import com.reuven.auth.entity.EntityStatus;
import com.reuven.auth.entity.Tenant;
import com.reuven.auth.entity.User;
import com.reuven.Role;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.springframework.http.HttpHeaders;

import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

/**
 * FR-007/SC-005 regression: CSRF stays disabled (SecurityCommons.applyCommonSecurity), and that
 * is safe only because every credential-bearing endpoint is guarded instead by the refresh
 * cookie's {@code SameSite=Strict} attribute (see the FR-014 regression in
 * RefreshFlowIntegrationTest), which browsers already refuse to attach cross-site. This feature
 * declines cross-site support entirely (research R6), so FR-007's CSRF-protection guard is not
 * triggered - documented here rather than left to be discovered by a future "why is CSRF off"
 * question.
 */
class CsrfPostureTest extends BaseIntegrationTest {

    private static final String LOGIN_URL = "/api/v1/auth/login";
    private static final String USER_PASSWORD = "UserPass@123";

    @BeforeEach
    void seedTenantAndUser() {
        testTenant = new Tenant("Acme Corp", "acme", EntityStatus.ACTIVE);
        tenantRepository.save(testTenant);
        User testUser = new User(testTenant, "csrf-test-user",
                passwordEncoder.encode(USER_PASSWORD), Role.USER, EntityStatus.ACTIVE);
        userRepository.save(testUser);
    }

    @Test
    @DisplayName("a credential-bearing POST succeeds with no CSRF token, proving CSRF is disabled "
            + "rather than silently blocking cookie-bearing requests")
    void loginSucceedsWithNoCsrfToken() throws Exception {
        mockMvc.perform(post(LOGIN_URL)
                        .header(HttpHeaders.HOST, testTenant.getUrlIdentifier() + ".localhost")
                        .contentType("application/json")
                        .content("""
                                {"username":"csrf-test-user","password":"%s"}""".formatted(USER_PASSWORD)))
                .andExpect(status().isOk());
    }
}
