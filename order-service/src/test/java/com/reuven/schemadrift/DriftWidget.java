package com.reuven.schemadrift;

import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.Id;
import jakarta.persistence.Table;

/**
 * US4 (quickstart S9, FR-006): an entity field ({@code name}) with no matching changeset in
 * {@code drift-changelog/db.changelog-master.yaml}, which creates {@code drift_widgets} with
 * only an {@code id} column. Hibernate {@code validate} must fail startup on this mismatch
 * rather than silently patching the schema.
 */
@Entity
@Table(name = "drift_widgets")
public class DriftWidget {

    @Id
    private Integer id;

    @Column(nullable = false)
    private String name;

    protected DriftWidget() {
    }
}
