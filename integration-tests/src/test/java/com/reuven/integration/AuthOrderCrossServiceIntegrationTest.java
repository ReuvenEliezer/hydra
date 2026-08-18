package com.reuven.integration;

import com.redis.testcontainers.RedisContainer;
import com.reuven.Role;
import com.reuven.auth.AuthServiceApplication;
import com.reuven.auth.dto.AuthResponse;
import com.reuven.auth.entity.EntityStatus;
import com.reuven.auth.entity.Tenant;
import com.reuven.auth.entity.User;
import com.reuven.auth.repository.ReservedTenantIdentifierRepository;
import com.reuven.auth.repository.TenantRepository;
import com.reuven.auth.repository.UserRepository;
import com.reuven.orderservice.OrderServiceApplication;
import com.reuven.orderservice.dto.OrderResponse;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.springframework.boot.SpringApplication;
import org.springframework.boot.resttestclient.TestRestTemplate;
import org.springframework.context.ConfigurableApplicationContext;
import org.springframework.http.*;
import org.springframework.security.crypto.bcrypt.BCryptPasswordEncoder;
import org.springframework.test.annotation.DirtiesContext;
import org.testcontainers.containers.PostgreSQLContainer;
import org.testcontainers.utility.DockerImageName;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.GeneralSecurityException;
import java.security.KeyPairGenerator;
import java.util.Base64;
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

    protected static RedisContainer redis = new RedisContainer(DockerImageName.parse("redis:8.8-alpine"))
            .withReuse(true);

    private static PostgreSQLContainer<?> authPostgres;
    private static PostgreSQLContainer<?> orderPostgres;

    private static ConfigurableApplicationContext authContext;
    private static ConfigurableApplicationContext orderContext;

    private static int authPort;
    private static int orderPort;

    private static UserRepository userRepository;
    private static TenantRepository tenantRepository;
    private static ReservedTenantIdentifierRepository reservedTenantIdentifierRepository;

    private static final String ADMIN_PASSWORD = "Admin@12345";
    private static final String USER_PASSWORD = "UserPass@123";

    private static final TestRestTemplate REST = new TestRestTemplate();

    /** The seeded tenant's sign-in address is crossco.localhost. */
    private static final String TENANT_URL_IDENTIFIER = "crossco";

    /**
     * Throwaway in-memory databases, one per service - NOT the developer's dev database.
     * <p>
     * Both services below are started under the {@code local} profile, whose
     * {@code application-local.yml} points {@code spring.datasource.url} at a FILE-backed H2
     * (`~/data/auth_db`, `~/data/orders_db`) - the very database a developer runs the app
     * against. Without this override the test seeds into it and, worse, {@code deleteAll()}s
     * it in {@link #clearSeededData()}: a test run silently destroys the local System Tenant
     * and super-admin, leaving orphaned rows in {@code reserved_tenant_identifiers} (which is
     * insert-only by design) and a bootstrap that can never re-seed because
     * {@code BootstrapService} only fires on an empty {@code users} table. The symptom is
     * remote from the cause - sign-in at system.localhost simply returns {@code unknown}.
     * <p>
     * These are passed as COMMAND-LINE ARGS, not {@code setDefaultProperties()}. Default
     * properties sit BELOW {@code application-{profile}.yml} in Spring's precedence order, so
     * they are silently ignored for any key the profile YAML already defines - and
     * {@code spring.datasource.url} is exactly such a key. Command-line args sit above it.
     * <p>
     * {@code DB_CLOSE_DELAY=-1} keeps the schema alive for the JVM's lifetime rather than
     * dropping it the moment the pool closes its last connection; the whole database still
     * dies with the JVM, so nothing survives the run.
     */
    private static final String H2_OPTIONS = ";MODE=PostgreSQL;DATABASE_TO_LOWER=TRUE;DB_CLOSE_DELAY=-1";
    private static final String AUTH_TEST_DB_URL = "jdbc:h2:mem:auth_crossservice_it" + H2_OPTIONS;
    private static final String ORDER_TEST_DB_URL = "jdbc:h2:mem:order_crossservice_it" + H2_OPTIONS;

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

        redis.start();
        // Setting System Properties, or passing directly to Spring
        System.setProperty("spring.data.redis.host", redis.getHost());
        System.setProperty("spring.data.redis.port", String.valueOf(redis.getMappedPort(6379)));

        String path = System.getenv("JWT_PRIVATE_KEY_PATH");

        if (path == null || path.isBlank()) {
            // CI sets the env var above (see .github/workflows/ci.yml); a bare `mvn test` has
            // nothing, and no key fixture is committed - `keys/` is gitignored and a private
            // key has no business in version control even as a test fixture. So mint a
            // throwaway pair: this test only needs order-service to verify tokens against the
            // JWKS auth-service publishes from this very key, which holds for any valid pair.
            // (auth-service's own BaseIntegrationTest carries the same fallback - the two test
            // roots are separate Maven modules with no shared test classpath between them.)
            path = generateEphemeralKeyFile();
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
                Map.entry("spring.data.redis.host", redis.getHost()),
                Map.entry("spring.data.redis.port", String.valueOf(redis.getMappedPort(6379))),
//                Map.entry("jwt.private-key-path", path),
                Map.entry("JWT_PRIVATE_KEY_PATH", path),
                Map.entry("app.bootstrap.super-admin-password", "password")
        ));
        authContext = authApp.run(
                "--server.port=0",
                "--spring.profiles.active=local",
                "--spring.datasource.url=" + AUTH_TEST_DB_URL
        );
        authPort = Integer.parseInt(authContext.getEnvironment().getProperty("local.server.port"));

        userRepository = authContext.getBean(UserRepository.class);
        tenantRepository = authContext.getBean(TenantRepository.class);
        reservedTenantIdentifierRepository = authContext.getBean(ReservedTenantIdentifierRepository.class);

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
                "--spring.profiles.active=local",
                "--spring.datasource.url=" + ORDER_TEST_DB_URL);
        orderPort = Integer.parseInt(orderContext.getEnvironment().getProperty("local.server.port"));
    }

    private static String generateEphemeralKeyFile() {
        try {
            KeyPairGenerator generator = KeyPairGenerator.getInstance("RSA");
            generator.initialize(2048);
            // getEncoded() on an RSA PrivateKey is PKCS#8 DER - exactly what
            // RsaKeyConverters.pkcs8() (inside LocalKeyProvider) expects once PEM-wrapped.
            String base64 = Base64.getMimeEncoder(64, "\n".getBytes(StandardCharsets.UTF_8))
                    .encodeToString(generator.generateKeyPair().getPrivate().getEncoded());
            Path keyFile = Files.createTempFile("hydra-test-private-key-", ".pem");
            keyFile.toFile().deleteOnExit();
            Files.writeString(keyFile,
                    "-----BEGIN PRIVATE KEY-----\n" + base64 + "\n-----END PRIVATE KEY-----\n");
            return keyFile.toString();
        } catch (GeneralSecurityException | IOException e) {
            throw new IllegalStateException("Could not generate an ephemeral RSA test key", e);
        }
    }

    @AfterAll
    static void stopBothServices() {
        if (orderContext != null) orderContext.close();
        if (authContext != null) authContext.close();
        if (orderPostgres != null) orderPostgres.stop();
        if (authPostgres != null) authPostgres.stop();
        if (redis != null) redis.stop();
    }

    @Test
    @DisplayName("A user registered via auth-service can create an order in order-service with their real token")
    void registeredUserToken_isAcceptedByOrderService() {
        UUID tenantId = seedTenantAndAdmin();
        String adminToken = login("acme-admin", ADMIN_PASSWORD, TENANT_URL_IDENTIFIER);

        registerUser(tenantId, adminToken, "jane.doe");
        String userToken = login("jane.doe", USER_PASSWORD, TENANT_URL_IDENTIFIER);

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
    @DisplayName("A Host-resolved super admin keeps their cross-tenant reach, and order-service still reads the JWT claim")
    void superAdminCrossTenantReach_survivesAddressBasedLogin() {
        UUID ownTenantId = seedTenantAndAdmin();
        UUID otherTenantId = tenantRepository
                .save(new Tenant("Other Corp", "otherco", EntityStatus.ACTIVE))
                .getId();
        userRepository.save(new User(
                tenantRepository.findById(ownTenantId).orElseThrow(),
                "cross-super-admin",
                new BCryptPasswordEncoder(12).encode(ADMIN_PASSWORD),
                Role.SUPER_ADMIN,
                EntityStatus.ACTIVE));

        // Signs in at their OWN address, like everyone else - resolution never consults role.
        String superAdminToken = login("cross-super-admin", ADMIN_PASSWORD, TENANT_URL_IDENTIFIER);

        HttpHeaders headers = new HttpHeaders();
        headers.setContentType(MediaType.APPLICATION_JSON);
        headers.setBearerAuth(superAdminToken);

        // ...and still reaches ANOTHER tenant afterwards. This is the non-regression the
        // whole story exists to prove: where you may sign in and what you may then do are
        // two separate questions, and this feature only changed the first.
        ResponseEntity<AuthResponse> registered = REST.exchange(
                authUrl("/api/v1/admin/" + otherTenantId + "/register-admin"),
                HttpMethod.POST,
                new HttpEntity<>("""
                        {"username": "other-admin", "password": "%s"}
                        """.formatted(ADMIN_PASSWORD), headers),
                AuthResponse.class
        );

        assertThat(registered.getStatusCode()).isEqualTo(HttpStatus.CREATED);

        // And an order-service call with that token still derives its tenant from the JWT
        // claim - the super admin's own tenant - with no tenant header anywhere in sight.
        ResponseEntity<OrderResponse> order = REST.exchange(
                orderUrl("/api/orders"),
                HttpMethod.POST,
                new HttpEntity<>("""
                        {"orderNumber": "ORD-CROSS-3", "totalAmount": 15.00}
                        """, headers),
                OrderResponse.class
        );

        assertThat(order.getStatusCode()).isEqualTo(HttpStatus.CREATED);
        assertThat(order.getBody()).isNotNull();
        assertThat(order.getBody().tenantId()).isEqualTo(ownTenantId);
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

    /**
     * Clears seeded data before each test.
     * <p>
     * Required now that {@code tenants.url_identifier} is unique: each test seeds the same
     * {@code crossco} address, and the datastore outlives the individual test method. Without
     * this, the second test in a run fails on the unique constraint rather than on anything it
     * is actually asserting. Users go first; they hold the foreign key to tenants.
     */
    @BeforeEach
    void clearSeededData() {
        deleteAllSeededData();
    }

    /**
     * Clears seeded data AFTER each test as well, so the last test in the run leaves nothing
     * behind - {@link #clearSeededData()} alone only ever cleans up on the NEXT run's way in,
     * which means the final test's tenant and users sit in the datastore indefinitely.
     * <p>
     * With {@link #AUTH_TEST_DB_URL} the database is in-memory and dies with the JVM anyway, so
     * this is belt-and-braces rather than the thing standing between a test run and the
     * developer's data. It is kept because it is what makes the invariant local to this class:
     * anyone who later repoints the datasource does not silently reintroduce the leak.
     */
    @AfterEach
    void clearSeededDataAfterTest() {
        deleteAllSeededData();
    }

    /**
     * Deletion order is a foreign-key constraint, not a style choice: users reference tenants.
     * Reserved identifiers go last and are deleted only because this is a test datastore - in
     * production the ledger is insert-only by design, which is precisely why a leaked row here
     * would permanently block re-claiming {@code crossco}.
     */
    private static void deleteAllSeededData() {
        userRepository.deleteAll();
        tenantRepository.deleteAll();
        reservedTenantIdentifierRepository.deleteAll();
    }

    private UUID seedTenantAndAdmin() {
        // Equivalent of what BootstrapService does for the very first super-admin in a
        // real deployment - done explicitly here since BootstrapService only runs under
        // the local profile (SECURITY.md Section 7), and this test runs against real
        // Postgres under a non-local profile, matching production more closely.
        Tenant tenant = tenantRepository.save(new Tenant("Cross-Service Test Co", TENANT_URL_IDENTIFIER, EntityStatus.ACTIVE));
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

    /**
     * Signs in at the tenant's own address. The URL still targets localhost - the point of this
     * test is the token contract between two services, not DNS - but the Host header carries the
     * tenant address, which is the only thing auth-service resolves from. httpclient5 is on the
     * classpath, so TestRestTemplate honours an explicit Host rather than dropping it the way
     * HttpURLConnection would.
     */
    private String login(String username, String password, String urlIdentifier) {
        HttpHeaders headers = new HttpHeaders();
        headers.setContentType(MediaType.APPLICATION_JSON);
        headers.set(HttpHeaders.HOST, urlIdentifier + ".localhost");

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
