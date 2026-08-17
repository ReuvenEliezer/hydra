package com.reuven.auth;

import com.reuven.auth.entity.EntityStatus;
import com.reuven.auth.entity.Tenant;
import com.reuven.auth.entity.User;
import com.reuven.Role;
import jakarta.servlet.http.Cookie;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.springframework.http.HttpHeaders;
import org.springframework.test.web.servlet.MvcResult;

import static org.assertj.core.api.Assertions.assertThat;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.*;

/**
 * Drives the refresh-token flow through real HTTP requests (MockMvc, plain HTTP -
 * the "test" profile never enables server.ssl, so this exercises exactly what a
 * browser sees against a non-HTTPS dev/test run). Covers the cookie contract end to
 * end: httpOnly cookie issued at login, rotated on refresh, and cleared on logout.
 */
@DisplayName("Refresh Token Flow Integration Tests")
class RefreshFlowIntegrationTest extends BaseIntegrationTest {

    private static final String LOGIN_URL = "/api/v1/auth/login";
    private static final String REFRESH_URL = "/api/v1/auth/refresh";
    private static final String LOGOUT_URL = "/api/v1/auth/logout";
    private static final String COOKIE_NAME = "refresh_token";
    private static final String USER_PASSWORD = "UserPass@123";

    @BeforeEach
    void seedTenantAndUser() {
        testTenant = new Tenant("Acme Corp", "acme", EntityStatus.ACTIVE);
        tenantRepository.save(testTenant);
        User testUser = new User(testTenant, "refresh-test-user",
                passwordEncoder.encode(USER_PASSWORD), Role.USER, EntityStatus.ACTIVE);
        userRepository.save(testUser);
    }

    private Cookie loginAndGetRefreshCookie() throws Exception {
        MvcResult result = mockMvc.perform(post(LOGIN_URL)
                        .header(HttpHeaders.HOST, testTenant.getUrlIdentifier() + ".localhost")
                        .contentType("application/json")
                        .content("""
                                {"username":"refresh-test-user","password":"%s"}""".formatted(USER_PASSWORD)))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.token").isNotEmpty())
                .andReturn();

        Cookie cookie = result.getResponse().getCookie(COOKIE_NAME);
        assertThat(cookie).as("login must set the refresh_token cookie").isNotNull();
        return cookie;
    }

    @Test
    @DisplayName("login sets an httpOnly, Strict, path-scoped refresh cookie")
    void login_setsExpectedCookieAttributes() throws Exception {
        Cookie cookie = loginAndGetRefreshCookie();

        assertThat(cookie.isHttpOnly()).isTrue();
        assertThat(cookie.getPath()).isEqualTo("/api/v1/auth");
        assertThat(cookie.getValue()).isNotBlank();
    }

    @Test
    @DisplayName("refresh with a valid cookie returns a new access token and rotates the cookie")
    void refresh_withValidCookie_rotatesTokenAndIssuesNewAccessToken() throws Exception {
        Cookie firstRefreshCookie = loginAndGetRefreshCookie();

        MvcResult result = mockMvc.perform(post(REFRESH_URL).cookie(firstRefreshCookie))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.token").isNotEmpty())
                .andReturn();

        Cookie rotatedCookie = result.getResponse().getCookie(COOKIE_NAME);
        assertThat(rotatedCookie).isNotNull();
        assertThat(rotatedCookie.getValue()).isNotEqualTo(firstRefreshCookie.getValue());
    }

    @Test
    @DisplayName("refresh without any cookie returns 401 invalid_refresh_token")
    void refresh_withoutCookie_returns401() throws Exception {
        mockMvc.perform(post(REFRESH_URL))
                .andExpect(status().isUnauthorized());
    }

    @Test
    @DisplayName("reusing an already-rotated refresh token (outside any race) is rejected and revokes the session")
    void refresh_reuseOfRotatedToken_returns401AndRevokesFamily() throws Exception {
        Cookie original = loginAndGetRefreshCookie();

        // First refresh succeeds and rotates...
        MvcResult firstRefresh = mockMvc.perform(post(REFRESH_URL).cookie(original))
                .andExpect(status().isOk())
                .andReturn();
        Cookie rotated = firstRefresh.getResponse().getCookie(COOKIE_NAME);

        // Let the grace window for the old token lapse (test profile sets grace-ttl to 2s).
        Thread.sleep(2500);

        // ...replaying the original (now-dead, outside-grace) token must fail.
        mockMvc.perform(post(REFRESH_URL).cookie(original))
                .andExpect(status().isUnauthorized())
                .andExpect(jsonPath("$.message").value("refresh_token_reuse_detected"));

        // And because reuse revokes the whole family, even the legitimately-rotated
        // token from the first refresh is now dead too.
        mockMvc.perform(post(REFRESH_URL).cookie(rotated))
                .andExpect(status().isUnauthorized());
    }

    @Test
    @DisplayName("two concurrent-looking refreshes with the same (still-fresh) cookie succeed once each via the grace window")
    void refresh_concurrentReplayWithinGraceWindow_bothSucceed() throws Exception {
        Cookie original = loginAndGetRefreshCookie();

        MvcResult first = mockMvc.perform(post(REFRESH_URL).cookie(original))
                .andExpect(status().isOk())
                .andReturn();

        // Immediately replay the SAME original cookie again, simulating a second tab
        // that fired the same refresh request concurrently.
        MvcResult replay = mockMvc.perform(post(REFRESH_URL).cookie(original))
                .andExpect(status().isOk())
                .andReturn();

        String firstToken = first.getResponse().getCookie(COOKIE_NAME).getValue();
        String replayToken = replay.getResponse().getCookie(COOKIE_NAME).getValue();
        assertThat(replayToken).as("grace-window replay must be idempotent, not a fresh rotation")
                .isEqualTo(firstToken);
    }

    @Test
    @DisplayName("logout clears the cookie and the refresh token can no longer be used")
    void logout_clearsCookieAndInvalidatesToken() throws Exception {
        Cookie refreshCookie = loginAndGetRefreshCookie();

        mockMvc.perform(post(LOGOUT_URL).cookie(refreshCookie))
                .andExpect(status().isNoContent())
                .andExpect(cookie().maxAge(COOKIE_NAME, 0));

        mockMvc.perform(post(REFRESH_URL).cookie(refreshCookie))
                .andExpect(status().isUnauthorized());
    }

    @Test
    @DisplayName("logout without any cookie is a no-op 204, not an error")
    void logout_withoutCookie_returns204() throws Exception {
        mockMvc.perform(post(LOGOUT_URL))
                .andExpect(status().isNoContent());
    }
}
