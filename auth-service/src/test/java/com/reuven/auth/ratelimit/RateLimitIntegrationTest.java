package com.reuven.auth.ratelimit;

import com.reuven.auth.BaseIntegrationTest;
import com.reuven.auth.entity.EntityStatus;
import com.reuven.auth.entity.Tenant;
import com.reuven.auth.entity.User;
import com.reuven.ratelimit.ClientIpResolver;
import com.reuven.ratelimit.RateLimitErrorCodes;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.springframework.http.HttpHeaders;
import org.springframework.http.MediaType;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.web.servlet.MvcResult;

import static org.assertj.core.api.Assertions.assertThat;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.header;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

/**
 * Drives rate limiting through real HTTP requests (MockMvc) against the actual
 * controller/exception-handler chain - complements RateLimiterTest, which exercises
 * the Redis-backed limiter's own logic directly. Overrides the default capacities to
 * small numbers scoped to just this test class, so tests run fast and deterministically
 * without touching the defaults every other test class relies on.
 */
class RateLimitIntegrationTest extends BaseIntegrationTest {

    private static final String LOGIN_URL = "/api/v1/auth/login";
    private static final String REFRESH_URL = "/api/v1/auth/refresh";

    @DynamicPropertySource
    static void rateLimitProperties(DynamicPropertyRegistry registry) {
        registry.add("rate-limit.enabled", () -> "true");
        registry.add("rate-limit.limits.login-ip.capacity", () -> "3");
        registry.add("rate-limit.limits.login-ip.window", () -> "PT1M");
        registry.add("rate-limit.limits.login-username.capacity", () -> "3");
        registry.add("rate-limit.limits.login-username.window", () -> "PT1M");
        registry.add("rate-limit.limits.refresh-ip.capacity", () -> "3");
        registry.add("rate-limit.limits.refresh-ip.window", () -> "PT1M");
        registry.add("rate-limit.limits.refresh-token.capacity", () -> "3");
        registry.add("rate-limit.limits.refresh-token.window", () -> "PT1M");
    }

    private User testUser;

    @BeforeEach
    protected void setUp() throws Exception {
        super.setUp();
        testTenant = tenantRepository.save(new Tenant("Acme Corp", EntityStatus.ACTIVE));
        testUser = userRepository.save(new User(testTenant, "rate-limit-user",
                passwordEncoder.encode(USER_PASSWORD), com.reuven.Role.USER, EntityStatus.ACTIVE));
    }

    private String loginBody(String username, String password) {
        return """
                {"username":"%s","password":"%s"}""".formatted(username, password);
    }

    @Test
    @DisplayName("login: exceeding per-IP limit returns 429 with Retry-After header and error body")
    void login_exceedingPerIpLimit_returns429() throws Exception {
        // 3 requests allowed (wrong password each time is fine - only the COUNT matters
        // for the rate limiter, which runs before authentication).
        for (int i = 0; i < 3; i++) {
            mockMvc.perform(post(LOGIN_URL)
                            .contentType(MediaType.APPLICATION_JSON)
                            .header(com.reuven.Headers.TENANT_ID, testTenant.getId().toString())
                            .content(loginBody("rate-limit-user", "wrong-password")))
                    .andExpect(status().isUnauthorized());
        }

        MvcResult result = mockMvc.perform(post(LOGIN_URL)
                        .contentType(MediaType.APPLICATION_JSON)
                        .header(com.reuven.Headers.TENANT_ID, testTenant.getId().toString())
                        .content(loginBody("rate-limit-user", "wrong-password")))
                .andExpect(status().isTooManyRequests())
                .andExpect(header().exists(HttpHeaders.RETRY_AFTER))
                .andExpect(jsonPath("$.error").value(RateLimitErrorCodes.RATE_LIMIT_EXCEEDED))
                .andExpect(jsonPath("$.message").value("Too many requests. Please try again later."))
                .andReturn();

        int retryAfter = Integer.parseInt(result.getResponse().getHeader(HttpHeaders.RETRY_AFTER));
        assertThat(retryAfter).isPositive();
    }

    @Test
    @DisplayName("login: different (username, IP) pairs have independent budgets")
    void login_differentUsernamesAndIps_haveIndependentBudgets() throws Exception {
        userRepository.save(new User(testTenant, "rate-limit-user-2",
                passwordEncoder.encode(USER_PASSWORD), com.reuven.Role.USER, EntityStatus.ACTIVE));

        for (int i = 0; i < 3; i++) {
            mockMvc.perform(post(LOGIN_URL)
                    .header(ClientIpResolver.X_FORWARDED_FOR, "10.0.0.1")
                    .contentType(MediaType.APPLICATION_JSON)
                    .header(com.reuven.Headers.TENANT_ID, testTenant.getId().toString())
                    .content(loginBody("rate-limit-user", "wrong-password")));
        }

        mockMvc.perform(post(LOGIN_URL)
                        .header(ClientIpResolver.X_FORWARDED_FOR, "10.0.0.1")
                        .contentType(MediaType.APPLICATION_JSON)
                        .header(com.reuven.Headers.TENANT_ID, testTenant.getId().toString())
                        .content(loginBody("rate-limit-user", "wrong-password")))
                .andExpect(status().isTooManyRequests());

        // A different username, from a different simulated IP, with correct credentials:
        // neither its per-username nor its per-IP budget has been touched by the above,
        // so this must succeed - proving the two (username, ip) pairs don't share state.
        mockMvc.perform(post(LOGIN_URL)
                        .header(ClientIpResolver.X_FORWARDED_FOR, "10.0.0.2")
                        .contentType(MediaType.APPLICATION_JSON)
                        .header(com.reuven.Headers.TENANT_ID, testTenant.getId().toString())
                        .content(loginBody("rate-limit-user-2", USER_PASSWORD)))
                .andExpect(status().isOk());
    }

    @Test
    @DisplayName("refresh: exceeding per-IP limit returns 429 without requiring cookies")
    void refresh_exceedingPerIpLimit_returns429EvenWithoutCookie() throws Exception {
        for (int i = 0; i < 3; i++) {
            mockMvc.perform(post(REFRESH_URL))
                    .andExpect(status().isUnauthorized());
        }

        mockMvc.perform(post(REFRESH_URL))
                .andExpect(status().isTooManyRequests())
                .andExpect(header().exists(HttpHeaders.RETRY_AFTER))
                .andExpect(jsonPath("$.error").value(RateLimitErrorCodes.RATE_LIMIT_EXCEEDED));
    }
}
