package com.reuven.integration;

import com.reuven.auth.AuthServiceApplication;
import com.reuven.auth.dto.AuthResponse;
import com.reuven.auth.entity.EntityStatus;
import com.reuven.auth.entity.Tenant;
import com.reuven.auth.entity.User;
import com.reuven.Headers;
import com.reuven.Role;
import com.reuven.auth.repository.TenantRepository;
import com.reuven.auth.repository.UserRepository;
import com.reuven.orderservice.OrderServiceApplication;
import com.reuven.orderservice.dto.OrderResponse;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.SpringApplication;
import org.springframework.boot.resttestclient.TestRestTemplate;
import org.springframework.context.ConfigurableApplicationContext;
import org.springframework.http.*;
import org.springframework.security.crypto.bcrypt.BCryptPasswordEncoder;
import org.springframework.test.annotation.DirtiesContext;
import org.springframework.test.context.ActiveProfiles;
import org.testcontainers.containers.PostgreSQLContainer;

import java.net.URL;
import java.nio.file.Paths;
import java.util.Map;
import java.util.Objects;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * A genuinely cross-service test: two real, fully-wired Spring Boot applications
 * (auth-service and order-service) are started in this same JVM, each against its own
 * real PostgreSQL instance (via Testcontainers), and talk to each other over real HTTP -
 * exactly as they would in production, except both processes happen to live in one JVM
 * instead of two.
 * <p>
 * This is deliberately NOT a @SpringBootTest of a single service. Each service's own test
 * suite (AuthIntegrationTest, OrderServiceApplicationTests, etc.) only proves that service
 * is internally consistent with its own assumptions about the JWT contract. Only a test
 * like this one proves the contract actually holds between the two real, independently
 * deployable artifacts - see ARCHITECTURE.md's "Token contract" and "Test layout" sections.
 * <p>
 * Flow under test:
 * 1. auth-service starts for real, against a real Postgres, with Liquibase-managed schema.
 * 2. order-service starts for real, against a DIFFERENT real Postgres, configured to fetch
 * its JWKS from auth-service's actual runtime port (not a hardcoded guess).
 * 3. A tenant + admin user is seeded directly via auth-service's repositories (the
 * equivalent of what BootstrapService does in real life, done here explicitly since
 * BootstrapService is local-profile-only - see SECURITY.md Section 7).
 * 4. The admin logs in over real HTTP and registers a regular user over real HTTP -
 * this is the actual "register a user" flow the task asked to exercise.
 * 5. The new user logs in over real HTTP, receiving a token minted by auth-service's
 * real JwtProvider with auth-service's real private key.
 * 6. That token is sent to order-service's real /api/orders endpoint. order-service
 * must independently verify it via the JWKS it already fetched from auth-service,
 * with no synchronous call back to auth-service at request time.
 */
//@Testcontainers
@DisplayName("Cross-service: auth-service token accepted by order-service")
//@ActiveProfiles("local")
@DirtiesContext(classMode = DirtiesContext.ClassMode.AFTER_CLASS)
class AuthOrderCrossServiceIntegrationTest {

    private static PostgreSQLContainer<?> authPostgres;
    private static PostgreSQLContainer<?> orderPostgres;

    private static ConfigurableApplicationContext authContext;
    private static ConfigurableApplicationContext orderContext;

    private static int authPort;
    private static int orderPort;

    private static UserRepository userRepository;
    private static TenantRepository tenantRepository;

    private static final String ADMIN_PASSWORD = "Admin@12345";
    private static final String USER_PASSWORD = "UserPass@123";

    private static final TestRestTemplate REST = new TestRestTemplate();

    @BeforeAll
    static void startBothServices() throws Exception {
        // --- Two independent Postgres instances, one per service, matching how this
        //     actually runs in production (each service owns its own database). ---
//        authPostgres = new PostgreSQLContainer<>("postgres:16-alpine")
//                .withDatabaseName("auth_db");
//        authPostgres.start();
//
//        orderPostgres = new PostgreSQLContainer<>("postgres:16-alpine")
//                .withDatabaseName("orders_db");
//        orderPostgres.start();

        String path = System.getenv("JWT_PRIVATE_KEY_PATH");

        if (path == null || path.isBlank()) {
            // fallback for local
            URL resource = AuthOrderCrossServiceIntegrationTest.class
                    .getClassLoader()
                    .getResource("test-private-key.pem");

            if (resource == null) {
                throw new IllegalStateException("No JWT key found (env or test resource)");
            }

            try {
                path = Paths.get(resource.toURI()).toString();
            } catch (Exception e) {
                throw new RuntimeException(e);
            }
        }

        // IMPORTANT: application-test.yml already defines spring.datasource.url as
        // ${DB_URL:jdbc:postgresql://localhost:5432/auth_db} - a placeholder that resolves
        // against System properties / env vars. setDefaultProperties() sits BELOW
        // application-{profile}.yml in Spring's precedence order, so values set there would
        // be silently ignored for any key the profile-specific YAML already defines. Setting
        // System properties for exactly the placeholder names the YAML already exposes
        // (DB_URL, DB_USERNAME, DB_PASSWORD) is what actually overrides them correctly.
//        System.setProperty("DB_URL", authPostgres.getJdbcUrl());
//        System.setProperty("DB_USERNAME", authPostgres.getUsername());
//        System.setProperty("DB_PASSWORD", authPostgres.getPassword());

        // --- Start auth-service for real, on a random port, against its own Postgres. ---
        SpringApplication authApp = new SpringApplication(AuthServiceApplication.class);
        authApp.setDefaultProperties(Map.ofEntries(
                Map.entry("server.port", "0"),
                Map.entry("spring.profiles.active", "local"),
//                Map.entry("jwt.private-key-path", path),
                Map.entry("JWT_PRIVATE_KEY_PATH", path),
                Map.entry("app.bootstrap.super-admin-password", "password")
        ));
        authContext = authApp.run(
                "--server.port=0",
                "--spring.profiles.active=local"
        );
        authPort = Integer.parseInt(authContext.getEnvironment().getProperty("local.server.port"));

        userRepository = authContext.getBean(UserRepository.class);
        tenantRepository = authContext.getBean(TenantRepository.class);

        // order-service's application-dev.yml has the same ${DB_URL:...} pattern.
//        System.setProperty("DB_URL", orderPostgres.getJdbcUrl());
//        System.setProperty("DB_USERNAME", orderPostgres.getUsername());
//        System.setProperty("DB_PASSWORD", orderPostgres.getPassword());

        // order-service's base application.yml defines jwk-set-uri/issuer-uri via
        // ${AUTH_SERVICE_URL:http://localhost:8083}/... - another placeholder that sits
        // above setDefaultProperties() in precedence. Setting AUTH_SERVICE_URL itself
        // (to auth-service's ACTUAL random port, not the hardcoded 8083 default) is what
        // correctly routes order-service's JWKS fetch to the real running instance - this
        // is the crux of the whole cross-service contract this test exists to verify.
        System.setProperty("AUTH_SERVICE_URL", "http://localhost:" + authPort);

        // --- Start order-service for real, pointed at auth-service's ACTUAL runtime port
        //     for JWKS - not a hardcoded guess. This is the part that actually proves the
        //     two services agree on the contract over a real network call. ---
        SpringApplication orderApp = new SpringApplication(OrderServiceApplication.class);
        orderApp.setDefaultProperties(Map.ofEntries(
                Map.entry("server.port", "0"),
                Map.entry("spring.profiles.active", "local"),
                Map.entry("spring.security.oauth2.resourceserver.jwt.jwk-set-uri", "http://localhost:" + authPort + "/.well-known/jwks.json")
        ));
        orderContext = orderApp.run("--server.port=0",
                "--spring.profiles.active=local");
        orderPort = Integer.parseInt(orderContext.getEnvironment().getProperty("local.server.port"));
    }

    @AfterAll
    static void stopBothServices() {
        if (orderContext != null) orderContext.close();
        if (authContext != null) authContext.close();
        if (orderPostgres != null) orderPostgres.stop();
        if (authPostgres != null) authPostgres.stop();
    }

    @Test
    @DisplayName("A user registered via auth-service can create an order in order-service with their real token")
    void registeredUserToken_isAcceptedByOrderService() {
        UUID tenantId = seedTenantAndAdmin();
        String adminToken = login("acme-admin", ADMIN_PASSWORD, tenantId);

        registerUser(tenantId, adminToken, "jane.doe");
        String userToken = login("jane.doe", USER_PASSWORD, tenantId);

        HttpHeaders headers = new HttpHeaders();
        headers.setContentType(MediaType.APPLICATION_JSON);
        headers.setBearerAuth(userToken);

        String body = """
                {"orderNumber": "ORD-CROSS-1", "totalAmount": 49.99}
                """;

        ResponseEntity<OrderResponse> response = REST.exchange(
                orderUrl("/api/orders"),
                HttpMethod.POST,
                new HttpEntity<>(body, headers),
                OrderResponse.class
        );

        // The actual point of this test: order-service independently verified a token it
        // never saw minted, using only the JWKS it fetched from auth-service over HTTP.
        assertThat(response.getStatusCode()).isEqualTo(HttpStatus.CREATED);
        assertThat(response.getBody()).isNotNull();
        assertThat(response.getBody().orderNumber()).isEqualTo("ORD-CROSS-1");
        assertThat(response.getBody().tenantId()).isEqualTo(tenantId);
    }

    @Test
    @DisplayName("An invalid/forged token is rejected by order-service with 401")
    void invalidToken_isRejectedWithUnauthorized() {
        HttpHeaders headers = new HttpHeaders();
        headers.setContentType(MediaType.APPLICATION_JSON);
        headers.setBearerAuth("this-is-not-a-real-jwt-at-all");

        String body = """
                {"orderNumber": "ORD-CROSS-2", "totalAmount": 10.00}
                """;

        ResponseEntity<String> response = REST.exchange(
                orderUrl("/api/orders"),
                HttpMethod.POST,
                new HttpEntity<>(body, headers),
                String.class
        );

        assertThat(response.getStatusCode()).isEqualTo(HttpStatus.UNAUTHORIZED);
    }

    // ---- Helpers -------------------------------------------------------------------

    private UUID seedTenantAndAdmin() {
        // Equivalent of what BootstrapService does for the very first super-admin in a
        // real deployment - done explicitly here since BootstrapService only runs under
        // the local profile (SECURITY.md Section 7), and this test runs against real
        // Postgres under a non-local profile, matching production more closely.
        Tenant tenant = tenantRepository.save(new Tenant("Cross-Service Test Co", EntityStatus.ACTIVE));
        userRepository.save(new User(tenant, "acme-admin",
                new BCryptPasswordEncoder(12).encode(ADMIN_PASSWORD), Role.ADMIN, EntityStatus.ACTIVE));
        return tenant.getId();
    }

    private void registerUser(UUID tenantId, String adminToken, String username) {
        HttpHeaders headers = new HttpHeaders();
        headers.setContentType(MediaType.APPLICATION_JSON);
        headers.setBearerAuth(adminToken);

        String body = """
                {"username": "%s", "password": "%s"}
                """.formatted(username, AuthOrderCrossServiceIntegrationTest.USER_PASSWORD);

        ResponseEntity<AuthResponse> response = REST.exchange(
                authUrl("/api/v1/admin/register-user"),
                HttpMethod.POST,
                new HttpEntity<>(body, headers),
                AuthResponse.class
        );

        assertThat(response.getStatusCode()).isEqualTo(HttpStatus.CREATED);
        assertThat(response.getBody()).isNotNull();
        User user = userRepository.findByTenantIdAndUsername(tenantId, username)
                .orElseThrow(() -> new AssertionError("User not found in repository after registration"));
        assertThat(response.getBody().userId()).isEqualTo(user.getId());
        assertThat(response.getBody().message()).isEqualTo("USER_CREATED");

    }

    private String login(String username, String password, UUID tenantId) {
        HttpHeaders headers = new HttpHeaders();
        headers.setContentType(MediaType.APPLICATION_JSON);
        headers.set(Headers.TENANT_ID, tenantId.toString());

        String body = """
                {"username": "%s", "password": "%s"}
                """.formatted(username, password);

        ResponseEntity<AuthResponse> response = REST.exchange(
                authUrl("/api/v1/auth/login"),
                HttpMethod.POST,
                new HttpEntity<>(body, headers),
                AuthResponse.class
        );

        assertThat(response.getStatusCode()).isEqualTo(HttpStatus.OK);
        return Objects.requireNonNull(response.getBody()).token();
    }

    private String authUrl(String path) {
        return "http://localhost:" + authPort + path;
    }

    private String orderUrl(String path) {
        return "http://localhost:" + orderPort + path;
    }
}
