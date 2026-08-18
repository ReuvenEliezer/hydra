package com.reuven.integration.edge;

import com.redis.testcontainers.RedisContainer;
import com.reuven.auth.AuthServiceApplication;
import com.reuven.auth.entity.EntityStatus;
import com.reuven.auth.entity.Tenant;
import com.reuven.auth.repository.TenantRepository;
import com.reuven.auth.repository.UserRepository;
import org.springframework.boot.SpringApplication;
import org.springframework.context.ConfigurableApplicationContext;
import org.testcontainers.utility.DockerImageName;

import java.io.IOException;
import java.io.UncheckedIOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.GeneralSecurityException;
import java.security.KeyPairGenerator;
import java.util.Base64;
import java.util.Map;
import java.util.UUID;

/**
 * Starts one real, in-process auth-service the two conformance test classes each point their own
 * edge stand-in at, and seeds the tenants the clause assertions resolve against. Mirrors
 * {@code AuthOrderCrossServiceIntegrationTest}'s pattern of running the real Spring context on a
 * random port rather than mocking anything - the conformance suite has to observe what the real
 * service does with {@code Host} and CORS headers, which a mock cannot stand in for.
 */
final class EdgeConformanceFixture {

    static final String RECOGNIZED_TENANT_HOST = "acme.localhost";
    static final String SECOND_RECOGNIZED_TENANT_HOST = "beta.localhost";
    static final String ORIGIN = "http://acme.localhost:5173";

    private final RedisContainer redis;
    private final ConfigurableApplicationContext authContext;
    final int authPort;

    private EdgeConformanceFixture(RedisContainer redis, ConfigurableApplicationContext authContext, int authPort) {
        this.redis = redis;
        this.authContext = authContext;
        this.authPort = authPort;
    }

    static EdgeConformanceFixture start() {
        RedisContainer redis = new RedisContainer(DockerImageName.parse("redis:8.8-alpine"));
        redis.start();

        String keyPath = ephemeralKeyFile();

        SpringApplication authApp = new SpringApplication(AuthServiceApplication.class);
        authApp.setDefaultProperties(Map.ofEntries(
                Map.entry("server.port", "0"),
                Map.entry("spring.profiles.active", "local"),
                Map.entry("spring.data.redis.host", redis.getHost()),
                Map.entry("spring.data.redis.port", String.valueOf(redis.getMappedPort(6379))),
                Map.entry("JWT_PRIVATE_KEY_PATH", keyPath),
                Map.entry("app.bootstrap.super-admin-password", "password"),
                Map.entry("hydra.tenant.base-domains", "localhost"),
                Map.entry("hydra.cors.allowed-origin-patterns", "http://*.localhost:5173")
        ));
        // A unique in-memory database per fixture instance: TransparentEdgeConformanceTest and
        // HostileEdgeDetectionTest both start their own fixture in the same forked JVM, and
        // DB_CLOSE_DELAY=-1 keeps a fixed-name schema alive across them - a shared name would
        // let the second fixture's deleteAll() trip the first fixture's still-referenced rows.
        String dbName = "edge_conformance_it_" + UUID.randomUUID();
        ConfigurableApplicationContext authContext = authApp.run(
                "--server.port=0",
                "--spring.profiles.active=local",
                "--spring.datasource.url=jdbc:h2:mem:" + dbName + ";MODE=PostgreSQL;DATABASE_TO_LOWER=TRUE;DB_CLOSE_DELAY=-1"
        );
        int authPort = Integer.parseInt(authContext.getEnvironment().getProperty("local.server.port"));

        UserRepository userRepository = authContext.getBean(UserRepository.class);
        TenantRepository tenantRepository = authContext.getBean(TenantRepository.class);
        userRepository.deleteAll();
        tenantRepository.deleteAll();
        tenantRepository.save(new Tenant("Acme Corp", "acme", EntityStatus.ACTIVE));
        tenantRepository.save(new Tenant("Beta Inc", "beta", EntityStatus.ACTIVE));

        return new EdgeConformanceFixture(redis, authContext, authPort);
    }

    void stop() {
        authContext.close();
        redis.stop();
    }

    private static String ephemeralKeyFile() {
        try {
            KeyPairGenerator generator = KeyPairGenerator.getInstance("RSA");
            generator.initialize(2048);
            String base64 = Base64.getMimeEncoder(64, "\n".getBytes(StandardCharsets.UTF_8))
                    .encodeToString(generator.generateKeyPair().getPrivate().getEncoded());
            Path keyFile = Files.createTempFile("hydra-edge-conformance-key-", ".pem");
            keyFile.toFile().deleteOnExit();
            Files.writeString(keyFile,
                    "-----BEGIN PRIVATE KEY-----\n" + base64 + "\n-----END PRIVATE KEY-----\n");
            return keyFile.toString();
        } catch (GeneralSecurityException e) {
            throw new IllegalStateException("Could not generate an ephemeral RSA test key", e);
        } catch (IOException e) {
            throw new UncheckedIOException(e);
        }
    }
}
