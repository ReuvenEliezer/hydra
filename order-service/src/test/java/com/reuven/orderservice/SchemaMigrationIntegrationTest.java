package com.reuven.orderservice;

import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.SpringApplication;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.context.TestConfiguration;
import org.springframework.boot.testcontainers.service.connection.ServiceConnection;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Import;
import org.springframework.jdbc.core.JdbcTemplate;
import org.testcontainers.containers.PostgreSQLContainer;

import java.util.List;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

/**
 * US3 (quickstart S8, FR-003): order-service's changelog lives at Liquibase's default classpath
 * location ({@code db/changelog/db.changelog-master.yaml}), so no {@code
 * spring.liquibase.change-log} override is needed in {@code application.yaml} at all — the
 * default finds it. This proves both halves — the changelog is found and applies (positive) and
 * a wrong path fails loudly rather than silently doing nothing (negative).
 */
@SpringBootTest(properties = "spring.jpa.hibernate.ddl-auto=validate")
@Import(SchemaMigrationIntegrationTest.Containers.class)
class SchemaMigrationIntegrationTest {

    @Autowired
    JdbcTemplate jdbcTemplate;

    @Test
    void freshDatabase_schemaBuiltEntirelyByTheChangelog() {
        List<String> indexNames = jdbcTemplate.queryForList(
                "select indexname from pg_indexes where tablename = 'orders'", String.class);
        assertThat(indexNames).contains("idx_orders_tenant_id", "idx_orders_tenant_created");

        List<String> constraintNames = jdbcTemplate.queryForList(
                "select constraint_name from information_schema.table_constraints where table_name = 'orders'",
                String.class);
        assertThat(constraintNames).noneMatch(name -> name.equalsIgnoreCase("fk_orders_tenant"));

        List<String> changesetIds = jdbcTemplate.queryForList(
                "select id from databasechangelog order by orderexecuted", String.class);
        assertThat(changesetIds).containsExactly("20260614-01-create-orders-table");
    }

    @Test
    void missingChangelogPath_failsStartupLoudly() {
        SpringApplication app = new SpringApplication(OrderServiceApplication.class);

        assertThatThrownBy(() -> app.run(
                "--server.port=0",
                "--spring.datasource.url=jdbc:h2:mem:order_missing_changelog_test",
                "--spring.datasource.driver-class-name=org.h2.Driver",
                "--spring.datasource.username=sa",
                "--spring.datasource.password=",
                "--spring.liquibase.change-log=classpath:/db/changelog/does-not-exist.yaml"))
                .hasStackTraceContaining("classpath:/db/changelog/does-not-exist.yaml");
    }

    @TestConfiguration(proxyBeanMethods = false)
    static class Containers {
        @Bean
        @ServiceConnection
        PostgreSQLContainer<?> postgres() {
            return new PostgreSQLContainer<>("postgres:16-alpine");
        }
    }
}
