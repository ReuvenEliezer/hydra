package com.reuven.auth;

import com.reuven.auth.entity.Tenant;
import com.reuven.auth.entity.User;
import com.reuven.auth.repository.TenantRepository;
import com.reuven.auth.repository.UserRepository;
import com.reuven.auth.service.JwtProvider;
import com.reuven.auth.service.KeyProvider;
import org.junit.jupiter.api.BeforeEach;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.testcontainers.service.connection.ServiceConnection;
import org.springframework.boot.webmvc.test.autoconfigure.AutoConfigureMockMvc;
import org.springframework.data.redis.connection.RedisConnectionFactory;
import org.springframework.data.redis.core.StringRedisTemplate;
import org.springframework.security.crypto.password.PasswordEncoder;
import org.springframework.test.annotation.DirtiesContext;
import org.springframework.test.context.ActiveProfiles;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.web.servlet.MockMvc;
import org.testcontainers.containers.GenericContainer;
import org.testcontainers.containers.PostgreSQLContainer;
import org.testcontainers.junit.jupiter.Container;
import org.testcontainers.junit.jupiter.Testcontainers;
import org.testcontainers.utility.DockerImageName;
import tools.jackson.databind.json.JsonMapper;

import java.net.URL;
import java.nio.file.Paths;

@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.RANDOM_PORT)
@AutoConfigureMockMvc
@Testcontainers
@ActiveProfiles("test")
@DirtiesContext(classMode = DirtiesContext.ClassMode.AFTER_EACH_TEST_METHOD)
// Reset Spring context after each test method to ensure isolation
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
            .withReuse(true);

    // No dedicated testcontainers Redis module is used on purpose - GenericContainer
    // is all that's needed for a single-node redis:7.4-alpine, and @ServiceConnection
    // doesn't have a built-in Redis recognizer for raw GenericContainer, so the
    // host/port are wired explicitly below via @DynamicPropertySource instead.
    @Container
    protected static GenericContainer<?> redis = new GenericContainer<>(DockerImageName.parse("redis:7.4-alpine"))
            .withExposedPorts(6379)
            .withReuse(true);

    @Autowired
    protected MockMvc mockMvc;
    @Autowired
    protected JsonMapper jsonMapper;
    @Autowired
    protected TenantRepository tenantRepository;
    @Autowired
    protected UserRepository userRepository;
    @Autowired
    protected PasswordEncoder passwordEncoder;
    @Autowired
    protected JwtProvider jwtProvider;
    @Autowired
    protected KeyProvider keyProvider;
    @Autowired
    protected StringRedisTemplate stringRedisTemplate;

    @DynamicPropertySource
    static void baseProperties(DynamicPropertyRegistry registry) {
        registry.add("spring.data.redis.host", redis::getHost);
        registry.add("spring.data.redis.port", () -> redis.getMappedPort(6379));

        // LocalKeyProvider (active under "test" too - see its @Profile) takes a file
        // PATH, not raw PEM content, so we resolve the fixture's classpath URI to an
        // actual filesystem path rather than reading it into a String.
        String path = System.getenv("JWT_PRIVATE_KEY_PATH");

        if (path == null || path.isBlank()) {
            // fallback for local
            URL resource = BaseIntegrationTest.class
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
        String finalPath = path;
        registry.add("jwt.private-key-path", () -> finalPath);
        registry.add("jwt.issuer", () -> "hydra-auth-service");
    }

    @BeforeEach
    protected void setUp() throws Exception {
        cleanPostgresDatabase();
        cleanRedisDatabase();
    }

    private void cleanPostgresDatabase() {
        userRepository.deleteAll();
        tenantRepository.deleteAll();
    }

    private void cleanRedisDatabase() {
        RedisConnectionFactory connection = stringRedisTemplate.getConnectionFactory();
        if (connection != null) {
            connection.getConnection().serverCommands().flushDb();
        }
    }
}