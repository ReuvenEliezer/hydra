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

/**
 * US1 (quickstart S3, FR-001): appending one changeset to a changelog and re-running {@code
 * update} against a database that already has the original changelog applied records and
 * applies exactly the new changeset — nothing already recorded runs again. Exercised directly
 * against the Liquibase Java API on a disposable H2 database, never against a service changelog
 * (research/tasks.md T011 note: a synced checksum outlives an edit).
 */
class IncrementalChangesetTest {

    private static final String DB_URL =
            "jdbc:h2:mem:incremental_changeset_test;DB_CLOSE_DELAY=-1";

    @Test
    void appendedChangesetAppliesAlone() throws Exception {
        try (Connection connection = DriverManager.getConnection(DB_URL, "sa", "")) {
            applyChangelog(connection, "changelog/base.yaml");
            assertThat(changesetCount(connection)).isEqualTo(1);
        }

        try (Connection connection = DriverManager.getConnection(DB_URL, "sa", "")) {
            applyChangelog(connection, "changelog/superset.yaml");
            assertThat(changesetCount(connection)).isEqualTo(2);
        }
    }

    /**
     * Deliberately does not close the {@link Liquibase} instance: doing so closes its
     * {@link Database}, which closes the very {@code connection} the caller still needs to
     * assert against. The outer try-with-resources in the test owns the connection's lifecycle.
     */
    private static void applyChangelog(Connection connection, String changelogPath) throws Exception {
        Database database = DatabaseFactory.getInstance()
                .findCorrectDatabaseImplementation(new JdbcConnection(connection));
        new Liquibase(changelogPath, new ClassLoaderResourceAccessor(), database).update();
    }

    private static int changesetCount(Connection connection) throws Exception {
        try (Statement statement = connection.createStatement();
             ResultSet resultSet = statement.executeQuery("select count(*) from databasechangelog")) {
            resultSet.next();
            return resultSet.getInt(1);
        }
    }
}
