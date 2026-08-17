package com.reuven.auth.ratelimit;

import com.reuven.auth.BaseIntegrationTest;
import com.reuven.auth.entity.EntityStatus;
import com.reuven.auth.entity.Tenant;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.springframework.http.HttpHeaders;
import org.springframework.http.MediaType;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;

import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

/**
 * Verifies {@code rate-limit.enabled=false} disables enforcement end-to-end over real
 * HTTP requests. Kept as its own test class (own Spring context, own capacity-1
 * override) rather than a method inside {@link RateLimitIntegrationTest}, since the
 * property has to be false for the whole context here, not just one test method.
 */
class RateLimitDisabledIntegrationTest extends BaseIntegrationTest {

    private static final String LOGIN_URL = "/api/v1/auth/login";

    @DynamicPropertySource
    static void rateLimitProperties(DynamicPropertyRegistry registry) {
        registry.add("rate-limit.enabled", () -> "false");
        // Deliberately tiny capacity: if the enabled flag were NOT actually honored,
        // the very first extra request beyond 1 would immediately fail this test.
        registry.add("rate-limit.limits.login-ip.capacity", () -> "1");
        registry.add("rate-limit.limits.login-ip.window", () -> "PT1M");
        registry.add("rate-limit.limits.login-username.capacity", () -> "1");
        registry.add("rate-limit.limits.login-username.window", () -> "PT1M");
    }

    @BeforeEach
    protected void setUp() throws Exception {
        super.setUp();
        testTenant = tenantRepository.save(new Tenant("Acme Corp", "acme", EntityStatus.ACTIVE));
    }

    private String loginBody(String username) {
        return """
                {"username":"%s","password":"wrong-password"}""".formatted(username);
    }

    @Test
    @DisplayName("rate-limit.enabled=false: requests far beyond capacity are never rejected with 429")
    void disabledGlobally_neverReturns429() throws Exception {
        for (int i = 0; i < 10; i++) {
            mockMvc.perform(post(LOGIN_URL)
                            .contentType(MediaType.APPLICATION_JSON)
                            .header(HttpHeaders.HOST, testTenant.getUrlIdentifier() + ".localhost")
                            .content(loginBody("whoever")))
                    // Wrong password -> 401 from normal auth logic, but crucially never 429.
                    .andExpect(status().isUnauthorized());
        }
    }
}
