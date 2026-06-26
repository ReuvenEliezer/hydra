package com.reuven.auth;

import com.reuven.auth.entity.Tenant;
import com.reuven.auth.entity.User;
import com.reuven.auth.repository.TenantRepository;
import com.reuven.auth.repository.UserRepository;
import com.reuven.auth.service.JwtProvider;
import org.junit.jupiter.api.BeforeEach;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.webmvc.test.autoconfigure.AutoConfigureMockMvc;

import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.testcontainers.service.connection.ServiceConnection;
import org.springframework.security.crypto.password.PasswordEncoder;
import org.springframework.test.annotation.DirtiesContext;
import org.springframework.test.context.ActiveProfiles;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.web.servlet.MockMvc;
import org.testcontainers.containers.PostgreSQLContainer;
import org.testcontainers.junit.jupiter.Container;
import org.testcontainers.junit.jupiter.Testcontainers;
import tools.jackson.databind.json.JsonMapper;

import java.nio.file.Files;
import java.nio.file.Paths;
import java.util.Objects;

@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.RANDOM_PORT)
@AutoConfigureMockMvc
@Testcontainers
@ActiveProfiles("test")
@DirtiesContext(classMode = DirtiesContext.ClassMode.AFTER_EACH_TEST_METHOD) // Reset Spring context after each test method to ensure isolation
public abstract class BaseIntegrationTest {

    // Instance fields, not static: each test method gets a fresh Spring context reset by
    // @BeforeEach, and static fields here would be shared/overwritten across test classes
    // running in the same JVM - harmless under sequential execution, but a silent race
    // condition waiting to happen the moment parallel test execution is turned on.
    protected Tenant testTenant;
    protected User superAdmin;

    protected static final String SUPER_ADMIN_PASSWORD = "SuperAdmin@123";
    protected static final String ADMIN_PASSWORD = "Admin@12345";
    protected static final String USER_PASSWORD = "UserPass@123";

    @Container
    @ServiceConnection
    protected static PostgreSQLContainer<?> postgres = new PostgreSQLContainer<>("postgres:16-alpine")
            .withReuse(true)
            ;

    static {
        System.out.println("Starting PostgreSQL Container...");
        postgres.start();
    }

    @Autowired protected MockMvc mockMvc;
    @Autowired protected JsonMapper jsonMapper;
    @Autowired protected TenantRepository tenantRepository;
    @Autowired protected UserRepository userRepository;
    @Autowired protected PasswordEncoder passwordEncoder;
    @Autowired protected JwtProvider jwtProvider;

    @DynamicPropertySource
    static void baseProperties(DynamicPropertyRegistry registry) throws Exception {
        // Valid RSA key in Base64 format (shortened but structurally valid)
        // Note: In this test we will use a valid dummy key

        // Clean loading from file
        try {

//            openssl genrsa -out private.pem 2048
//            openssl pkcs8 -topk8 -inform PEM -outform PEM -nocrypt -in private.pem -out test-private-key.pem

            String pemKey = new String(Files.readAllBytes(Paths.get(
                Objects.requireNonNull(BaseIntegrationTest.class.getClassLoader()
                        .getResource("test-private-key.pem")).toURI())));
            registry.add("jwt.private-key", () -> pemKey);
            registry.add("jwt.issuer", () -> "hydra-auth-service");
        } catch (Exception e) {
            throw new RuntimeException("Failed to load test private key", e);
        }
    }

    @BeforeEach
    protected void setUp() {
        cleanDatabase();
    }

    private void cleanDatabase() {
        userRepository.deleteAll();
        tenantRepository.deleteAll();
    }
}