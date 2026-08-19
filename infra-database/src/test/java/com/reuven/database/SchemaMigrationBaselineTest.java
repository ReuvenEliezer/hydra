package com.reuven.database;

import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.MethodOrderer;
import org.junit.jupiter.api.Order;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.TestMethodOrder;
import org.springframework.boot.SpringApplication;
import org.springframework.context.ConfigurableApplicationContext;
import org.testcontainers.containers.PostgreSQLContainer;

import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.ResultSet;
import java.sql.Statement;
import java.util.HashMap;
import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

/**
 * US2 (quickstart S4-S7): a real Spring Boot context, booted through the actual
 * {@code SchemaMigrationAutoConfiguration} / Boot {@code LiquibaseAutoConfiguration} wiring
 * (not a direct call into {@link SchemaMigrationGuard}, which {@link SchemaMigrationGuardTest}
 * already covers), against a real PostgreSQL database with a legacy, Hibernate-shaped schema
 * and real rows in it.
 * <p>
 * S4-S6 run in declared order against one shared container/database, because each scenario is
 * a step in the same story: a legacy database refuses to start, is reconciled once, and a
 * second reconciliation changes nothing. S7 (a legacy schema that turns out not to match) is a
 * different story against its own, independent database.
 */
@TestMethodOrder(MethodOrderer.OrderAnnotation.class)
class SchemaMigrationBaselineTest {

    private static PostgreSQLContainer<?> postgres;

    @BeforeAll
    static void startContainer() {
        postgres = new PostgreSQLContainer<>("postgres:16-alpine");
        postgres.start();
        createLegacyWidgetsTableWithRows(postgres, /* withNameColumn */ true);
    }

    @AfterAll
    static void stopContainer() {
        postgres.stop();
    }

    @Test
    @Order(1)
    void legacyDatabaseWithRows_refusesToStart_withNoBaselineFlag() throws Exception {
        assertThatThrownBy(() -> startApp(postgres, Map.of()))
                .hasStackTraceContaining("hydra.database.baseline.enabled=true");

        // Refused before any DDL: no bookkeeping table, and the pre-existing rows are untouched.
        assertThat(tableExists("databasechangelog")).isFalse();
        assertThat(widgetRowCount()).isEqualTo(3);
    }

    @Test
    @Order(2)
    void reconciliation_recordsChangesetsWithoutExecuting_andLeavesRowsIntact() throws Exception {
        ConfigurableApplicationContext context = startApp(postgres, Map.of(
                "hydra.database.baseline.enabled", "true",
                "hydra.database.baseline.tag", "s5-baseline"));
        try {
            assertThat(changesetCount()).isEqualTo(2);
            assertThat(taggedRowValue()).isEqualTo("s5-baseline");
            assertThat(widgetRowCount()).isEqualTo(3);
            assertThat(widgetNames()).containsExactlyInAnyOrder("alpha", "bravo", "charlie");
        } finally {
            context.close();
        }
    }

    @Test
    @Order(3)
    void reconciliation_isRepeatSafe() throws Exception {
        ConfigurableApplicationContext context = startApp(postgres, Map.of(
                "hydra.database.baseline.enabled", "true",
                "hydra.database.baseline.tag", "s6-should-not-be-written"));
        try {
            assertThat(changesetCount()).isEqualTo(2);
            // Still the S5 tag: the guard saw H=true and treated the flag as a no-op (FR-004).
            assertThat(taggedRowValue()).isEqualTo("s5-baseline");
        } finally {
            context.close();
        }
    }

    @Test
    void reconcilingAMismatchedSchema_syncsButValidateFailsInTheSameStartup() throws Exception {
        PostgreSQLContainer<?> mismatchDb = new PostgreSQLContainer<>("postgres:16-alpine");
        try {
            mismatchDb.start();
            // The "name" column the entity requires is missing from this legacy schema.
            createLegacyWidgetsTableWithRows(mismatchDb, /* withNameColumn */ false);

            assertThatThrownBy(() -> startApp(mismatchDb, Map.of(
                    "hydra.database.baseline.enabled", "true",
                    "hydra.database.baseline.tag", "s7-baseline")))
                    .hasStackTraceContaining("name");

            // The sync itself succeeded even though the overall startup failed later, at validate.
            try (Connection connection = rawConnection(mismatchDb);
                 Statement statement = connection.createStatement();
                 ResultSet resultSet = statement.executeQuery("select count(*) from databasechangelog")) {
                resultSet.next();
                assertThat(resultSet.getInt(1)).isEqualTo(2);
            }
        } finally {
            mismatchDb.stop();
        }
    }

    private static ConfigurableApplicationContext startApp(
            PostgreSQLContainer<?> container, Map<String, String> extraProperties) {
        SpringApplication app = new SpringApplication(MinimalTestApplication.class);
        Map<String, Object> properties = new HashMap<>();
        properties.put("spring.datasource.url", container.getJdbcUrl());
        properties.put("spring.datasource.username", container.getUsername());
        properties.put("spring.datasource.password", container.getPassword());
        properties.put("spring.liquibase.change-log", "classpath:changelog/superset.yaml");
        properties.put("spring.jpa.hibernate.ddl-auto", "validate");
        properties.put("spring.jpa.database-platform", "org.hibernate.dialect.PostgreSQLDialect");
        properties.putAll(extraProperties);
        app.setDefaultProperties(properties);
        return app.run();
    }

    private static void createLegacyWidgetsTableWithRows(PostgreSQLContainer<?> container, boolean withNameColumn) {
        try (Connection connection = rawConnection(container);
             Statement statement = connection.createStatement()) {
            if (withNameColumn) {
                statement.execute("create table widgets (id int primary key, name varchar(50) not null)");
                statement.execute("insert into widgets (id, name) values (1, 'alpha'), (2, 'bravo'), (3, 'charlie')");
            } else {
                statement.execute("create table widgets (id int primary key)");
                statement.execute("insert into widgets (id) values (1), (2), (3)");
            }
        } catch (Exception e) {
            throw new IllegalStateException("Failed to seed the legacy widgets table", e);
        }
    }

    private static Connection rawConnection(PostgreSQLContainer<?> container) throws Exception {
        return DriverManager.getConnection(
                container.getJdbcUrl(), container.getUsername(), container.getPassword());
    }

    private boolean tableExists(String name) throws Exception {
        try (Connection connection = rawConnection(postgres)) {
            try (ResultSet resultSet = connection.getMetaData()
                    .getTables(null, null, name, new String[]{"TABLE"})) {
                return resultSet.next();
            }
        }
    }

    private int widgetRowCount() throws Exception {
        return scalarInt("select count(*) from widgets");
    }

    private java.util.List<String> widgetNames() throws Exception {
        java.util.List<String> names = new java.util.ArrayList<>();
        try (Connection connection = rawConnection(postgres);
             Statement statement = connection.createStatement();
             ResultSet resultSet = statement.executeQuery("select name from widgets order by id")) {
            while (resultSet.next()) {
                names.add(resultSet.getString(1));
            }
        }
        return names;
    }

    private int changesetCount() throws Exception {
        return scalarInt("select count(*) from databasechangelog");
    }

    private String taggedRowValue() throws Exception {
        try (Connection connection = rawConnection(postgres);
             Statement statement = connection.createStatement();
             ResultSet resultSet = statement.executeQuery(
                     "select tag from databasechangelog where tag is not null order by orderexecuted desc limit 1")) {
            resultSet.next();
            return resultSet.getString(1);
        }
    }

    private int scalarInt(String sql) throws Exception {
        try (Connection connection = rawConnection(postgres);
             Statement statement = connection.createStatement();
             ResultSet resultSet = statement.executeQuery(sql)) {
            resultSet.next();
            return resultSet.getInt(1);
        }
    }
}
