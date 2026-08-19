package com.reuven.database;

import org.junit.jupiter.api.Test;
import org.springframework.boot.SpringApplication;
import org.springframework.context.ConfigurableApplicationContext;
import org.testcontainers.containers.PostgreSQLContainer;

import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.ResultSet;
import java.sql.Statement;
import java.util.List;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

/**
 * FR-010/G7, quickstart S11: a changeset guaranteed to fail leaves a clean, recoverable state.
 * Asserted against PostgreSQL specifically — it has transactional DDL, so the failed
 * changeset's own statements roll back and nothing partial is left behind (research R6; H2 has
 * no such guarantee, which is why this scenario is not asserted there).
 */
class FailedChangesetTest {

    @Test
    void failingChangeset_isNotRecorded_priorChangesetsUntouched_andRecoveryIsForwardOnly() throws Exception {
        try (PostgreSQLContainer<?> postgres = new PostgreSQLContainer<>("postgres:16-alpine")) {
            postgres.start();

            assertThatThrownBy(() -> startApp(postgres, "classpath:changelog/failing.yaml"))
                    .hasStackTraceContaining("does_not_exist");

            try (Connection connection = DriverManager.getConnection(
                    postgres.getJdbcUrl(), postgres.getUsername(), postgres.getPassword())) {
                assertThat(changesetIds(connection)).containsExactly("001-create-ok-table");
                assertThat(tableExists(connection, "ok_table")).isTrue();
                assertThat(tableExists(connection, "does_not_exist")).isFalse();
            }

            // Correcting the changeset and restarting succeeds — recovery is forward-only.
            ConfigurableApplicationContext context = startApp(postgres, "classpath:changelog/failing-fixed.yaml");
            try {
                try (Connection connection = DriverManager.getConnection(
                        postgres.getJdbcUrl(), postgres.getUsername(), postgres.getPassword())) {
                    assertThat(changesetIds(connection)).containsExactly(
                            "001-create-ok-table", "002-fails-column-on-missing-table");
                }
            } finally {
                context.close();
            }
        }
    }

    private static ConfigurableApplicationContext startApp(PostgreSQLContainer<?> postgres, String changeLog) {
        SpringApplication app = new SpringApplication(MinimalTestApplication.class);
        return app.run(
                "--spring.datasource.url=" + postgres.getJdbcUrl(),
                "--spring.datasource.username=" + postgres.getUsername(),
                "--spring.datasource.password=" + postgres.getPassword(),
                "--spring.liquibase.change-log=" + changeLog,
                "--spring.jpa.hibernate.ddl-auto=none");
    }

    private static List<String> changesetIds(Connection connection) throws Exception {
        List<String> ids = new java.util.ArrayList<>();
        try (Statement statement = connection.createStatement();
             ResultSet resultSet = statement.executeQuery(
                     "select id from databasechangelog order by orderexecuted")) {
            while (resultSet.next()) {
                ids.add(resultSet.getString(1));
            }
        }
        return ids;
    }

    private static boolean tableExists(Connection connection, String name) throws Exception {
        try (ResultSet resultSet = connection.getMetaData()
                .getTables(null, null, name, new String[]{"TABLE"})) {
            return resultSet.next();
        }
    }
}
