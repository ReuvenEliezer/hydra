package com.reuven.auth;

import com.redis.testcontainers.RedisContainer;
import org.junit.jupiter.api.MethodOrderer;
import org.junit.jupiter.api.Order;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.TestMethodOrder;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.context.TestConfiguration;
import org.springframework.boot.testcontainers.service.connection.ServiceConnection;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Import;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.test.annotation.DirtiesContext;
import org.springframework.test.context.ActiveProfiles;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.testcontainers.containers.PostgreSQLContainer;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.GeneralSecurityException;
import java.security.KeyPairGenerator;
import java.util.Base64;
import java.util.List;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * US1 (quickstart S1, S2): the changelogs, and only the changelogs, build the schema on an
 * empty database (FR-001), and a restart against the same database applies nothing more
 * (FR-002). The two tests share one Testcontainers PostgreSQL instance across the class and run
 * in declared order — {@link #freshDatabaseSchemaBuiltEntirelyByChangelogs()} creates the
 * schema, {@link #restartAppliesNothing()} then starts a second, independent Spring context
 * against that same database to prove the restart is a no-op.
 */
@SpringBootTest
@ActiveProfiles("test")
@Import(SchemaMigrationIntegrationTest.Containers.class)
@TestMethodOrder(MethodOrderer.OrderAnnotation.class)
@DirtiesContext(classMode = DirtiesContext.ClassMode.AFTER_EACH_TEST_METHOD)
class SchemaMigrationIntegrationTest {

    @Autowired
    JdbcTemplate jdbcTemplate;

    @DynamicPropertySource
    static void jwtKey(DynamicPropertyRegistry registry) {
        registry.add("jwt.private-key-path", SchemaMigrationIntegrationTest::ephemeralKeyPath);
    }

    @Test
    @Order(1)
    void freshDatabaseSchemaBuiltEntirelyByChangelogs() {
        List<String> tables = jdbcTemplate.queryForList(
                "select table_name from information_schema.tables where table_schema = 'public'",
                String.class);
        assertThat(tables).containsExactlyInAnyOrder(
                "tenants", "users", "user_roles", "reserved_tenant_identifiers",
                "databasechangelog", "databasechangeloglock");

        List<String> changesetIds = jdbcTemplate.queryForList(
                "select id from databasechangelog order by orderexecuted", String.class);
        assertThat(changesetIds).containsExactly(
                "20260621-01-initial-schema-with-roles",
                "20260813-01-tenant-url-identifier",
                "20260813-02-reserved-tenant-identifiers");
    }

    @Test
    @Order(2)
    void restartAppliesNothing() {
        Long rowCount = jdbcTemplate.queryForObject(
                "select count(*) from databasechangelog", Long.class);
        assertThat(rowCount).isEqualTo(3L);

        Long deploymentCount = jdbcTemplate.queryForObject(
                "select count(distinct deployment_id) from databasechangelog", Long.class);
        assertThat(deploymentCount).isEqualTo(1L);
    }

    private static String ephemeralKeyPath() {
        try {
            KeyPairGenerator generator = KeyPairGenerator.getInstance("RSA");
            generator.initialize(2048);
            String base64 = Base64.getMimeEncoder(64, "\n".getBytes(StandardCharsets.UTF_8))
                    .encodeToString(generator.generateKeyPair().getPrivate().getEncoded());
            String pem = "-----BEGIN PRIVATE KEY-----\n" + base64 + "\n-----END PRIVATE KEY-----\n";
            Path keyFile = Files.createTempFile("hydra-schema-migration-key-", ".pem");
            keyFile.toFile().deleteOnExit();
            Files.writeString(keyFile, pem);
            return keyFile.toString();
        } catch (GeneralSecurityException | IOException e) {
            throw new IllegalStateException("Could not generate an ephemeral RSA test key", e);
        }
    }

    /**
     * Static singleton containers (the standard Testcontainers pattern for this case): each
     * {@code @Test} above runs in its own Spring context, courtesy of
     * {@code @DirtiesContext(AFTER_EACH_TEST_METHOD)}, but "restart against the same database"
     * only means something if both contexts connect to the SAME running container rather than
     * one freshly created per context. {@code start()} on an already-running container is a
     * no-op, so the second context's {@code @ServiceConnection} wiring just reattaches.
     */
    @TestConfiguration(proxyBeanMethods = false)
    static class Containers {
        static final RedisContainer REDIS =
                new RedisContainer("redis:8.8-alpine").withExposedPorts(6379).withReuse(true);
        static final PostgreSQLContainer<?> POSTGRES = new PostgreSQLContainer<>("postgres:16-alpine");

        @Bean
        @ServiceConnection
        RedisContainer redisContainer() {
            return REDIS;
        }

        @Bean
        @ServiceConnection
        PostgreSQLContainer<?> postgres() {
            return POSTGRES;
        }
    }
}
