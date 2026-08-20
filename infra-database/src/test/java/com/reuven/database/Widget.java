package com.reuven.database;

import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.Id;
import jakarta.persistence.Table;

/**
 * The entity behind {@code changelog/superset.yaml}'s {@code widgets} table (id + name), used
 * only by the US2 baseline tests to give Hibernate {@code validate} something real to check
 * (T024/S7: reconciling a schema that does not match).
 */
@Entity
@Table(name = "widgets")
public class Widget {

    @Id
    private Integer id;

    @Column(nullable = false)
    private String name;

    protected Widget() {
    }
}
