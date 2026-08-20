package com.reuven.database;

import org.springframework.boot.context.properties.ConfigurationProperties;
import org.springframework.boot.context.properties.bind.DefaultValue;

/**
 * {@code hydra.database.baseline.*} (data-model.md §2). {@code tag} has no static default: its
 * default ({@code baseline-<UTC instant>}) is a point in time, computed by
 * {@link SchemaMigrationGuard} only when the property is absent, not a constant this record
 * could hold.
 */
@ConfigurationProperties("hydra.database.baseline")
public record SchemaMigrationProperties(@DefaultValue("false") boolean enabled, String tag) {
}
