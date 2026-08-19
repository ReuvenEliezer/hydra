package com.reuven.database;

import liquibase.database.Database;

import java.sql.SQLException;

/**
 * The abstraction Constitution Principle II requires: the guard's policy (decision matrix,
 * data-model.md §3) is written against this interface, never against JDBC metadata directly, so
 * the detection mechanism can change without touching the policy.
 */
public interface SchemaStateInspector {

    /**
     * True when {@code DATABASECHANGELOG} exists and holds at least one row. Row-count based,
     * not table-existence based: an empty table left by an aborted first attempt must still
     * count as "no history" (research R5).
     */
    boolean hasMigrationHistory(Database database) throws SQLException;

    /**
     * True when the schema contains at least one table other than {@code DATABASECHANGELOG} /
     * {@code DATABASECHANGELOGLOCK}. Deliberately generic rather than a hardcoded per-service
     * table list, so it does not rot as the schema grows (research R5).
     */
    boolean hasApplicationTables(Database database) throws SQLException;
}
