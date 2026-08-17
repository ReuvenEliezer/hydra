package com.reuven.auth.repository;

import com.reuven.auth.entity.Tenant;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.stereotype.Repository;

import java.util.Optional;
import java.util.UUID;

public interface TenantRepository extends JpaRepository<Tenant, UUID> {

    /**
     * The single lookup behind every tenant resolution - one indexed row read on the unique
     * {@code url_identifier}, on the login path and on the public lookup alike. The argument is
     * already normalized (lowercase, no port) by {@code TenantHostParser}.
     */
    Optional<Tenant> findByUrlIdentifier(String urlIdentifier);
}