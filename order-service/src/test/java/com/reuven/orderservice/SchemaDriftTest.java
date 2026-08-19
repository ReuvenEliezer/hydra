package com.reuven.orderservice;

import com.reuven.schemadrift.DriftTestApplication;
import org.junit.jupiter.api.Test;
import org.springframework.boot.SpringApplication;
import org.testcontainers.containers.PostgreSQLContainer;

import java.nio.file.Files;
import java.nio.file.Path;
import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.ResultSet;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

/**
 * US4 (quickstart S9, SC-004, FR-006, G8): an entity field with no matching changeset fails
 * startup instead of being silently patched — proven on PostgreSQL (the deployed-environment
 * engine) and, separately, on a throwaway H2 file database matching the shape of the {@code
 * local} profile's storage (research R9), because FR-006 exempts no environment.
 */
class SchemaDriftTest {

    @Test
    void driftOnPostgres_failsStartup_columnNeverCreated() throws Exception {
        try (PostgreSQLContainer<?> postgres = new PostgreSQLContainer<>("postgres:16-alpine")) {
            postgres.start();

            SpringApplication app = new SpringApplication(DriftTestApplication.class);
            assertThatThrownBy(() -> app.run(
                    "--spring.datasource.url=" + postgres.getJdbcUrl(),
                    "--spring.datasource.username=" + postgres.getUsername(),
                    "--spring.datasource.password=" + postgres.getPassword(),
                    "--spring.liquibase.change-log=classpath:/drift-changelog/db.changelog-master.yaml",
                    "--spring.jpa.hibernate.ddl-auto=validate"))
                    .hasStackTraceContaining("name");

            try (Connection connection = DriverManager.getConnection(
                    postgres.getJdbcUrl(), postgres.getUsername(), postgres.getPassword())) {
                assertThat(columnExists(connection, "drift_widgets", "name")).isFalse();
            }
        }
    }

    @Test
    void driftOnLocalProfileStyleH2FileDatabase_failsIdentically() throws Exception {
        Path dbDir = Files.createTempDirectory("hydra-drift-h2-");
        String dbUrl = "jdbc:h2:file:" + dbDir.resolve("drift_db")
                + ";MODE=PostgreSQL;DATABASE_TO_LOWER=TRUE;DB_CLOSE_DELAY=-1";

        SpringApplication app = new SpringApplication(DriftTestApplication.class);
        assertThatThrownBy(() -> app.run(
                "--spring.datasource.url=" + dbUrl,
                "--spring.datasource.driver-class-name=org.h2.Driver",
                "--spring.datasource.username=sa",
                "--spring.datasource.password=",
                "--spring.liquibase.change-log=classpath:/drift-changelog/db.changelog-master.yaml",
                "--spring.jpa.hibernate.ddl-auto=validate"))
                .hasStackTraceContaining("name");

        try (Connection connection = DriverManager.getConnection(dbUrl, "sa", "")) {
            assertThat(columnExists(connection, "DRIFT_WIDGETS", "NAME")).isFalse();
        }
    }

    private static boolean columnExists(Connection connection, String table, String column) throws Exception {
        try (ResultSet resultSet = connection.getMetaData().getColumns(null, null, table, column)) {
            return resultSet.next();
        }
    }
}
