package com.reuven.auth;

import com.reuven.auth.config.TestContainersConfig;
import com.reuven.auth.entity.Tenant;
import com.reuven.auth.entity.User;
import com.reuven.auth.repository.ReservedTenantIdentifierRepository;
import com.reuven.auth.repository.TenantRepository;
import com.reuven.auth.repository.UserRepository;
import com.reuven.auth.service.JwtProvider;
import com.reuven.auth.service.KeyProvider;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.webmvc.test.autoconfigure.AutoConfigureMockMvc;
import org.springframework.context.annotation.Import;
import org.springframework.data.redis.connection.RedisConnectionFactory;
import org.springframework.data.redis.core.StringRedisTemplate;
import org.springframework.security.crypto.password.PasswordEncoder;
import org.springframework.test.annotation.DirtiesContext;
import org.springframework.test.context.ActiveProfiles;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.web.servlet.MockMvc;
import tools.jackson.databind.json.JsonMapper;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.GeneralSecurityException;
import java.security.KeyPairGenerator;
import java.util.Base64;

@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.RANDOM_PORT)
@AutoConfigureMockMvc
@ActiveProfiles("test")
@Import(TestContainersConfig.class)
@DirtiesContext(classMode = DirtiesContext.ClassMode.AFTER_EACH_TEST_METHOD)
// Reset Spring context after each test method to ensure isolation
public abstract class BaseIntegrationTest {

    // Instance fields, not static: each test method gets a fresh Spring context reset by
    // @BeforeEach, and static fields here would be shared/overwritten across test classes
    // running in the same JVM - harmless under sequential execution, but a silent race
    // condition waiting to happen the moment parallel test execution is turned on.
    protected Tenant testTenant;
    protected User superAdmin;

    private static String ephemeralKeyPath;

    protected static final String SUPER_ADMIN_PASSWORD = "SuperAdmin@123";
    protected static final String ADMIN_PASSWORD = "Admin@12345";
    protected static final String USER_PASSWORD = "UserPass@123";

    @Autowired
    protected MockMvc mockMvc;
    @Autowired
    protected JsonMapper jsonMapper;
    @Autowired
    protected TenantRepository tenantRepository;
    @Autowired
    protected UserRepository userRepository;
    @Autowired
    protected ReservedTenantIdentifierRepository reservedTenantIdentifierRepository;
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
//        registry.add("spring.data.redis.host", redis::getHost);
//        registry.add("spring.data.redis.port", () -> redis.getMappedPort(6379));

        // LocalKeyProvider (active under "test" too - see its @Profile) takes a file
        // PATH, not raw PEM content, so every branch below yields a filesystem path
        // rather than reading key material into a String.
        String path = System.getenv("JWT_PRIVATE_KEY_PATH");

        if (path == null || path.isBlank()) {
            // CI sets the env var above (see .github/workflows/ci.yml); a bare `mvn test`
            // has nothing, and no key fixture is committed - `keys/` is gitignored and a
            // private key has no business in version control even as a test fixture.
            // So mint a throwaway pair per JVM: tests only need signatures that verify
            // against the public key derived from this same private key.
            path = ephemeralKeyPath();
        }
        String finalPath = path;
        registry.add("jwt.private-key-path", () -> finalPath);
        registry.add("jwt.issuer", () -> "hydra-auth-service");
    }

    // Generated once per JVM, not per context load: @DirtiesContext rebuilds the context
    // after every test method, and RSA keygen on each rebuild is pure wasted wall-clock.
    private static synchronized String ephemeralKeyPath() {
        if (ephemeralKeyPath == null) {
            ephemeralKeyPath = generateEphemeralKeyFile();
        }
        return ephemeralKeyPath;
    }

    private static String generateEphemeralKeyFile() {
        try {
            KeyPairGenerator generator = KeyPairGenerator.getInstance("RSA");
            generator.initialize(2048);
            // getEncoded() on an RSA PrivateKey is PKCS#8 DER - exactly what
            // RsaKeyConverters.pkcs8() expects once PEM-wrapped.
            String base64 = Base64.getMimeEncoder(64, "\n".getBytes(StandardCharsets.UTF_8))
                    .encodeToString(generator.generateKeyPair().getPrivate().getEncoded());
            String pem = "-----BEGIN PRIVATE KEY-----\n" + base64 + "\n-----END PRIVATE KEY-----\n";
            Path keyFile = Files.createTempFile("hydra-test-private-key-", ".pem");
            keyFile.toFile().deleteOnExit();
            Files.writeString(keyFile, pem);
            return keyFile.toString();
        } catch (GeneralSecurityException | IOException e) {
            throw new IllegalStateException("Could not generate an ephemeral RSA test key", e);
        }
    }

    @BeforeEach
    protected void setUp() throws Exception {
        cleanPostgresDatabase();
        cleanRedisDatabase();
    }

    /**
     * Cleans up AFTER each test as well, so the last test of a run leaves nothing behind.
     * <p>
     * The Postgres container is per-run and thrown away, but the Redis container is declared
     * {@code withReuse(true)} in {@code TestContainersConfig} - it deliberately OUTLIVES the
     * JVM and is re-attached by the next run. Refresh-token families and rate-limit buckets
     * written by the final test therefore survive into the next run, where they can only show
     * up as an unexplained 429 or an already-consumed token in a test that never created one.
     * Cleaning on the way in cannot help there: the damage is read before that test's
     * {@code @BeforeEach} has flushed anything.
     */
    @AfterEach
    protected void tearDown() {
        cleanPostgresDatabase();
        cleanRedisDatabase();
    }

    /**
     * Deletion order is a foreign-key constraint, not a style choice: users reference tenants.
     * <p>
     * The reserved-identifier ledger is cleared last and ONLY because this is a test database.
     * In production those rows are insert-only by design - a claimed address stays claimed for
     * good - which is exactly why a row left behind here is not inert: the next test that tries
     * to provision the same identifier gets a perfectly correct "already taken" rejection for a
     * tenant no test in this run ever created.
     */
    private void cleanPostgresDatabase() {
        userRepository.deleteAll();
        tenantRepository.deleteAll();
        reservedTenantIdentifierRepository.deleteAll();
    }

    private void cleanRedisDatabase() {
        RedisConnectionFactory connection = stringRedisTemplate.getConnectionFactory();
        if (connection != null) {
            connection.getConnection().serverCommands().flushDb();
        }
    }
}