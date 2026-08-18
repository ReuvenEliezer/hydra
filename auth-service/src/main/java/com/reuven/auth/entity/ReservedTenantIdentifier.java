package com.reuven.auth.entity;

import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.Id;
import jakarta.persistence.Table;
import lombok.Getter;
import org.hibernate.annotations.CreationTimestamp;

import java.time.LocalDateTime;
import java.util.UUID;

/**
 * The permanent allocation ledger for Tenant URL Identifiers (FR-012).
 * <p>
 * <strong>Rows here are insert-only and outlive the tenant they were claimed for.</strong> They
 * are never updated and never deleted - not when the tenant is deactivated, not when it is
 * deleted, not when it is renamed off the identifier. That is the whole point of a separate
 * table: the unique constraint on {@code tenants.url_identifier} frees the value the moment the
 * tenant row goes away, which would let a later tenant inherit an address whose old links,
 * bookmarks, and sessions still point at the previous organization.
 * <p>
 * {@code identifier} is the primary key, so two concurrent provisioning calls for the same value
 * are resolved by the database rather than by a check-then-write race in application code - the
 * loser's whole transaction rolls back, and a tenant is never created without its reservation.
 * <p>
 * {@code tenantId} is nullable by design and carries no foreign key: a FK would either block
 * tenant deletion or cascade the reservation away, and both defeat the purpose.
 */
@Getter
@Entity
@Table(name = "reserved_tenant_identifiers")
public class ReservedTenantIdentifier {

    @Id
    @Column(name = "identifier", nullable = false, length = 63)
    private String identifier;

    @Column(name = "tenant_id")
    private UUID tenantId;

    @CreationTimestamp
    @Column(name = "reserved_at", nullable = false, updatable = false)
    private LocalDateTime reservedAt;

    protected ReservedTenantIdentifier() {}

    public ReservedTenantIdentifier(String identifier, UUID tenantId) {
        this.identifier = identifier;
        this.tenantId = tenantId;
    }

    @Override
    public boolean equals(Object o) {
        if (this == o) return true;
        if (!(o instanceof ReservedTenantIdentifier other)) return false;
        return identifier != null && identifier.equals(other.identifier);
    }

    @Override
    public int hashCode() {
        return getClass().hashCode(); // Constant throughout the object's life
    }
}
