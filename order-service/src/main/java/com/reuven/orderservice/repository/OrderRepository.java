package com.reuven.orderservice.repository;

import com.reuven.orderservice.dto.OrderStatus;
import com.reuven.orderservice.entity.Order;
import org.springframework.data.domain.Page;
import org.springframework.data.domain.Pageable;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Query;
import org.springframework.stereotype.Repository;

import java.util.Optional;
import java.util.UUID;

public interface OrderRepository extends JpaRepository<Order, UUID> {

    // Tenant-scoped queries - always filter by tenantId for data isolation
    Page<Order> findAllByTenantId(UUID tenantId, Pageable pageable);

    Optional<Order> findByIdAndTenantId(UUID id, UUID tenantId);

    Page<Order> findAllByTenantIdAndStatus(UUID tenantId, OrderStatus status, Pageable pageable);

    boolean existsByOrderNumberAndTenantId(String orderNumber, UUID tenantId);

    @Query("SELECT COUNT(o) FROM Order o WHERE o.tenantId = :tenantId")
    long countByTenantId(UUID tenantId);
}
