package com.reuven.database;

import liquibase.database.Database;
import liquibase.database.jvm.JdbcConnection;

import java.sql.Connection;
import java.sql.DatabaseMetaData;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Statement;
import java.util.Locale;
import java.util.Set;

/**
 * {@link SchemaStateInspector} over JDBC metadata on the live Liquibase connection (research
 * R5). Table names are matched case-insensitively since engines disagree on default case
 * folding (H2 upper-cases by default, PostgreSQL lower-cases).
 */
public class LiquibaseSchemaStateInspector implements SchemaStateInspector {

    private static final String CHANGELOG_TABLE = "DATABASECHANGELOG";
    private static final Set<String> BOOKKEEPING_TABLES = Set.of("DATABASECHANGELOG", "DATABASECHANGELOGLOCK");

    @Override
    public boolean hasMigrationHistory(Database database) throws SQLException {
        Connection connection = underlyingConnection(database);
        String actualTableName = findTable(connection, database, CHANGELOG_TABLE);
        if (actualTableName == null) {
            return false;
        }
        String escapedTable = database.escapeTableName(
                database.getDefaultCatalogName(), database.getDefaultSchemaName(), actualTableName);
        try (Statement statement = connection.createStatement();
             ResultSet resultSet = statement.executeQuery("select count(*) from " + escapedTable)) {
            resultSet.next();
            return resultSet.getLong(1) > 0;
        }
    }

    @Override
    public boolean hasApplicationTables(Database database) throws SQLException {
        Connection connection = underlyingConnection(database);
        DatabaseMetaData metaData = connection.getMetaData();
        try (ResultSet resultSet = metaData.getTables(
                connection.getCatalog(), database.getDefaultSchemaName(), "%", new String[]{"TABLE"})) {
            while (resultSet.next()) {
                String tableName = resultSet.getString("TABLE_NAME");
                if (tableName != null && !BOOKKEEPING_TABLES.contains(tableName.toUpperCase(Locale.ROOT))) {
                    return true;
                }
            }
        }
        return false;
    }

    private static String findTable(Connection connection, Database database, String name) throws SQLException {
        DatabaseMetaData metaData = connection.getMetaData();
        try (ResultSet resultSet = metaData.getTables(
                connection.getCatalog(), database.getDefaultSchemaName(), "%", new String[]{"TABLE"})) {
            while (resultSet.next()) {
                String tableName = resultSet.getString("TABLE_NAME");
                if (name.equalsIgnoreCase(tableName)) {
                    return tableName;
                }
            }
        }
        return null;
    }

    private static Connection underlyingConnection(Database database) {
        return ((JdbcConnection) database.getConnection()).getUnderlyingConnection();
    }
}
