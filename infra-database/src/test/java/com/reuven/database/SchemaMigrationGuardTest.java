package com.reuven.database;

import liquibase.Liquibase;
import liquibase.database.Database;
import liquibase.database.DatabaseFactory;
import liquibase.database.jvm.JdbcConnection;
import liquibase.resource.ClassLoaderResourceAccessor;
import org.junit.jupiter.api.Test;

import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.ResultSet;
import java.sql.Statement;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

/**
 * Drives all six rows of data-model.md §3's decision matrix directly against
 * {@link SchemaMigrationGuard#customize(Liquibase)} on in-memory H2 — no Spring context, since
 * the guard is a plain {@code Customizer<Liquibase>} with no framework dependency of its own.
 * Each test gets its own database so the three states (fresh / legacy / managed) don't interact.
 */
class SchemaMigrationGuardTest {

    private static final SchemaStateInspector INSPECTOR = new LiquibaseSchemaStateInspector();

    @Test
    void freshDatabase_enabledFalse_proceedsNormally() throws Exception {
        try (Connection connection = freshConnection("guard_fresh_false")) {
            Liquibase liquibase = liquibaseFor(connection);
            SchemaMigrationGuard guard = guard(false, null);

            guard.customize(liquibase);
            liquibase.update();

            assertThat(changesetCount(connection)).isEqualTo(1);
        }
    }

    @Test
    void freshDatabase_enabledTrue_nothingToReconcile_proceedsNormally() throws Exception {
        try (Connection connection = freshConnection("guard_fresh_true")) {
            Liquibase liquibase = liquibaseFor(connection);
            SchemaMigrationGuard guard = guard(true, "should-not-be-used");

            guard.customize(liquibase);
            liquibase.update();

            assertThat(changesetCount(connection)).isEqualTo(1);
            assertThat(tagCount(connection)).isEqualTo(0);
        }
    }

    @Test
    void legacyDatabase_enabledFalse_refusesToStart() throws Exception {
        try (Connection connection = freshConnection("guard_legacy_false")) {
            createWidgetsTableWithoutLiquibase(connection);
            Liquibase liquibase = liquibaseFor(connection);
            SchemaMigrationGuard guard = guard(false, null);

            assertThatThrownBy(() -> guard.customize(liquibase))
                    .isInstanceOf(IllegalStateException.class)
                    .hasMessageContaining("hydra.database.baseline.enabled=true");

            // Refused before any changeset ran: no DATABASECHANGELOG table at all yet.
            assertThat(tableExists(connection, "DATABASECHANGELOG")).isFalse();
        }
    }

    @Test
    void legacyDatabase_enabledTrue_reconciles() throws Exception {
        try (Connection connection = freshConnection("guard_legacy_true")) {
            createWidgetsTableWithoutLiquibase(connection);
            Liquibase liquibase = liquibaseFor(connection);
            SchemaMigrationGuard guard = guard(true, "baseline-test-tag");

            guard.customize(liquibase);
            liquibase.update(); // proceeds as a no-op: the changeset is already recorded

            assertThat(changesetCount(connection)).isEqualTo(1);
            assertThat(tagCount(connection)).isEqualTo(1);
            assertThat(lastTag(connection)).isEqualTo("baseline-test-tag");
        }
    }

    @Test
    void managedDatabase_enabledFalse_proceedsNormally() throws Exception {
        try (Connection connection = freshConnection("guard_managed_false")) {
            liquibaseFor(connection).update(); // establishes H=true, T=true

            Liquibase liquibase = liquibaseFor(connection);
            SchemaMigrationGuard guard = guard(false, null);
            guard.customize(liquibase);
            liquibase.update();

            assertThat(changesetCount(connection)).isEqualTo(1);
        }
    }

    @Test
    void managedDatabase_enabledTrue_ignoredAsNoOp() throws Exception {
        try (Connection connection = freshConnection("guard_managed_true")) {
            liquibaseFor(connection).update(); // establishes H=true, T=true

            Liquibase liquibase = liquibaseFor(connection);
            SchemaMigrationGuard guard = guard(true, "should-not-be-applied");
            guard.customize(liquibase);
            liquibase.update();

            assertThat(changesetCount(connection)).isEqualTo(1);
            assertThat(tagCount(connection)).isEqualTo(0);
        }
    }

    private static SchemaMigrationGuard guard(boolean enabled, String tag) {
        return new SchemaMigrationGuard(INSPECTOR, new SchemaMigrationProperties(enabled, tag));
    }

    private static Connection freshConnection(String dbName) throws Exception {
        return DriverManager.getConnection("jdbc:h2:mem:" + dbName + ";DB_CLOSE_DELAY=-1", "sa", "");
    }

    private static Liquibase liquibaseFor(Connection connection) throws Exception {
        Database database = DatabaseFactory.getInstance()
                .findCorrectDatabaseImplementation(new JdbcConnection(connection));
        return new Liquibase("changelog/base.yaml", new ClassLoaderResourceAccessor(), database);
    }

    private static void createWidgetsTableWithoutLiquibase(Connection connection) throws Exception {
        try (Statement statement = connection.createStatement()) {
            statement.execute("create table widgets (id int primary key)");
        }
    }

    private static boolean tableExists(Connection connection, String name) throws Exception {
        try (ResultSet resultSet = connection.getMetaData().getTables(null, null, name, new String[]{"TABLE"})) {
            return resultSet.next();
        }
    }

    private static int changesetCount(Connection connection) throws Exception {
        return scalarInt(connection, "select count(*) from databasechangelog");
    }

    private static int tagCount(Connection connection) throws Exception {
        return scalarInt(connection, "select count(*) from databasechangelog where tag is not null");
    }

    private static String lastTag(Connection connection) throws Exception {
        try (Statement statement = connection.createStatement();
             ResultSet resultSet = statement.executeQuery(
                     "select tag from databasechangelog where tag is not null order by orderexecuted desc limit 1")) {
            resultSet.next();
            return resultSet.getString(1);
        }
    }

    private static int scalarInt(Connection connection, String sql) throws Exception {
        try (Statement statement = connection.createStatement();
             ResultSet resultSet = statement.executeQuery(sql)) {
            resultSet.next();
            return resultSet.getInt(1);
        }
    }
}
