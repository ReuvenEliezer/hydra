package com.reuven.orderservice.dto;

import com.reuven.orderservice.entity.Order;
import java.math.BigDecimal;
import java.time.LocalDateTime;
import java.util.UUID;

public record OrderResponse(
        UUID id,
        UUID tenantId,
        String orderNumber,
        BigDecimal totalAmount,
        OrderStatus status,
        UUID createdBy,
        LocalDateTime createdAt,
        LocalDateTime updatedAt
) {
    public static OrderResponse from(Order order) {
        return new OrderResponse(
                order.getId(),
                order.getTenantId(),
                order.getOrderNumber(),
                order.getTotalAmount(),
                order.getStatus(),
                order.getCreatedBy(),
                order.getCreatedAt(),
                order.getUpdatedAt()
        );
    }
}
