package com.reuven.auth.repository;

import com.reuven.auth.entity.Tenant;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.stereotype.Repository;

import java.util.UUID;

public interface TenantRepository extends JpaRepository<Tenant, UUID> {

    // כאן נוכל להוסיף בעתיד שליפות מיוחדות, למשל:
    // Optional<Tenant> findByName(String name);
}