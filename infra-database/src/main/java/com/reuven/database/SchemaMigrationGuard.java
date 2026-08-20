package com.reuven.database;

import liquibase.Contexts;
import liquibase.LabelExpression;
import liquibase.Liquibase;
import liquibase.database.Database;
import liquibase.integration.spring.Customizer;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.sql.SQLException;
import java.time.Instant;

/**
 * The FR-005 guard: a {@link Customizer} bean, invoked by {@code SpringLiquibase.createLiquibase}
 * after the {@link Liquibase} object is built and before {@code performUpdate} runs a single
 * statement (research R3) — the exact "before any script runs" point the guard needs.
 * <p>
 * Implements the full six-row decision matrix in data-model.md §3. H = migration history
 * present, T = application tables present, baseline.enabled = the one-time reconciliation flag.
 */
public class SchemaMigrationGuard implements Customizer<Liquibase> {

    private static final Logger log = LoggerFactory.getLogger(SchemaMigrationGuard.class);

    private final SchemaStateInspector inspector;
    private final SchemaMigrationProperties properties;

    public SchemaMigrationGuard(SchemaStateInspector inspector, SchemaMigrationProperties properties) {
        this.inspector = inspector;
        this.properties = properties;
    }

    @Override
    public void customize(Liquibase liquibase) {
        Database database = liquibase.getDatabase();
        boolean hasHistory;
        boolean hasTables;
        try {
            hasHistory = inspector.hasMigrationHistory(database);
            hasTables = inspector.hasApplicationTables(database);
        } catch (SQLException e) {
            throw new IllegalStateException(
                    "Failed to inspect schema state for " + databaseDescription(database)
                            + " before running Liquibase", e);
        }

        if (hasHistory) {
            // H=true, any T: normal update; a still-set baseline flag is a no-op (repeat-safe).
            if (properties.enabled()) {
                log.info("hydra.database.baseline.enabled=true was set, but {} already has migration "
                        + "history; ignoring it and proceeding with the normal update.", databaseDescription(database));
            }
            return;
        }

        if (!hasTables) {
            // H=false, T=false: fresh database. Nothing to reconcile even if the flag is set.
            if (properties.enabled()) {
                log.info("hydra.database.baseline.enabled=true was set, but {} is empty; nothing to "
                        + "reconcile, the normal update will apply every changeset.", databaseDescription(database));
            }
            return;
        }

        // H=false, T=true: a legacy schema with no migration history.
        if (!properties.enabled()) {
            throw new IllegalStateException(
                    "Database " + databaseDescription(database) + " has existing tables but no Liquibase "
                            + "migration history. Refusing to start until it is reconciled once: restart with "
                            + "hydra.database.baseline.enabled=true.");
        }

        String tag = resolveTag();
        try {
            liquibase.changeLogSync(new Contexts(), new LabelExpression());
            liquibase.tag(tag);
        } catch (Exception e) {
            throw new IllegalStateException(
                    "Failed to reconcile (baseline) " + databaseDescription(database), e);
        }
        log.warn("Reconciled {}: every changeset in the changelog recorded as applied without "
                + "executing, tagged '{}'.", databaseDescription(database), tag);
    }

    private String resolveTag() {
        String tag = properties.tag();
        if (tag == null || tag.isBlank()) {
            return "baseline-" + Instant.now();
        }
        return tag;
    }

    private static String databaseDescription(Database database) {
        return database.getConnection().getURL();
    }
}
