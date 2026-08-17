package com.reuven.auth.entity;

import jakarta.persistence.*;
import lombok.Getter;
import org.hibernate.annotations.CreationTimestamp;
import java.time.LocalDateTime;
import java.util.UUID;

@Getter
@Entity
@Table(name = "tenants")
public class Tenant {

    @Id
    @GeneratedValue(strategy = GenerationType.UUID)
    private UUID id;

    @Column(nullable = false, length = 100)
    private String name;

    /**
     * The Tenant URL Identifier - the single DNS label in front of a configured base domain
     * ({@code acme} in {@code acme.hydra.example.com}). The unique constraint is what "at most
     * one tenant per address" rests on.
     * <p>
     * There is deliberately no setter: renaming an identifier is out of this feature's scope,
     * and leaving one here would offer a way to free a claimed address without going through
     * {@code reserved_tenant_identifiers}, which must outlive every such change.
     */
    @Column(name = "url_identifier", nullable = false, unique = true, length = 63)
    private String urlIdentifier;

    @Enumerated(EnumType.STRING)
    @Column(nullable = false)
    private EntityStatus status;

    @CreationTimestamp
    @Column(name = "created_at", nullable = false, updatable = false)
    private LocalDateTime createdAt;

    public Tenant() {}

    /**
     * The identifier is mandatory from construction, so "a tenant with no address" is
     * unrepresentable rather than merely rejected downstream (FR-009).
     */
    public Tenant(String name, String urlIdentifier, EntityStatus status) {
        this.name = name;
        this.urlIdentifier = urlIdentifier;
        this.status = status;
    }

    public void setName(String name) { this.name = name; }

    public void setStatus(EntityStatus status) {
        this.status = status;
    }

    @Override
    public boolean equals(Object o) {
        if (this == o) return true;
        if (!(o instanceof Tenant tenant)) return false;
        return id != null && id.equals(tenant.getId());
    }

    @Override
    public int hashCode() {
        return getClass().hashCode(); // Constant throughout the object's life
    }
}