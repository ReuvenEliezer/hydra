package com.reuven.auth.repository;

import com.reuven.auth.entity.ReservedTenantIdentifier;
import org.springframework.data.jpa.repository.JpaRepository;

/**
 * Read/insert access to the permanent identifier ledger. There is deliberately no delete method:
 * {@link ReservedTenantIdentifier} rows are insert-only, and the inherited {@code delete*}
 * methods exist only because they come with {@code JpaRepository}.
 */
public interface ReservedTenantIdentifierRepository extends JpaRepository<ReservedTenantIdentifier, String> {

    boolean existsByIdentifier(String identifier);
}
