package com.reuven.orderservice.entity;

import com.reuven.orderservice.dto.OrderStatus;
import jakarta.persistence.*;
import lombok.*;
import org.hibernate.annotations.CreationTimestamp;
import org.hibernate.annotations.UpdateTimestamp;

import java.math.BigDecimal;
import java.time.LocalDateTime;
import java.util.UUID;

@Entity
@Table(
        name = "orders",
        indexes = {
                @Index(name = "idx_orders_tenant_id", columnList = "tenant_id"),
                @Index(name = "idx_orders_tenant_created", columnList = "tenant_id, created_at")
        }
)
@Getter
@NoArgsConstructor
@AllArgsConstructor
@Builder
public class Order {

    @Id
    @GeneratedValue(strategy = GenerationType.UUID)
    @Column(name = "id", updatable = false, nullable = false)
    private UUID id;

    // Tenant column - critical for data isolation
    @Column(name = "tenant_id", nullable = false, updatable = false)
    private UUID tenantId;

    @Column(name = "order_number", nullable = false)
    private String orderNumber;

    @Column(name = "total_amount", nullable = false, precision = 19, scale = 2)
    private BigDecimal totalAmount;

    @Enumerated(EnumType.STRING)
    @Column(name = "status", nullable = false)
    private OrderStatus status;

    // Column for the user who performed the action
    @Column(name = "created_by", nullable = false)
    private UUID createdBy;

    // Optimistic locking to prevent concurrent updates
    @Version
    private Long version;

    @CreationTimestamp
    @Column(name = "created_at", nullable = false, updatable = false)
    private LocalDateTime createdAt;

    @UpdateTimestamp
    @Column(name = "updated_at", nullable = false)
    private LocalDateTime updatedAt;

    @Override
    public boolean equals(Object o) {
        if (this == o) return true;
        if (!(o instanceof Order other)) return false;
        // Compare by ID - works great as long as the ID doesn't change
        return id != null && id.equals(other.getId());
    }

    @Override
    public int hashCode() {
        // Return a constant to ensure consistency in Collections
        return getClass().hashCode();
    }

//    // Helper method to generate a new ID if none was provided
//    @PrePersist
//    protected void onCreate() {
//        if (this.id == null) {
//            this.id = UUID.randomUUID();
//        }
//    }
}
