package com.reuven.orderservice.service;

import com.reuven.orderservice.dto.CreateOrderRequest;
import com.reuven.orderservice.dto.OrderResponse;
import com.reuven.orderservice.dto.OrderStatus;
import com.reuven.orderservice.dto.UpdateOrderStatusRequest;
import com.reuven.orderservice.entity.Order;
import com.reuven.orderservice.exception.BusinessRuleException;
import com.reuven.orderservice.exception.ResourceNotFoundException;
import com.reuven.orderservice.repository.OrderRepository;
import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.springframework.data.domain.Page;
import org.springframework.data.domain.Pageable;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.UUID;

@Slf4j
@Service
@RequiredArgsConstructor
@Transactional(readOnly = true)
public class OrderService {

    private final OrderRepository orderRepository;

    @Transactional
    public OrderResponse createOrder(CreateOrderRequest request, UUID tenantId, UUID userId) {
        if (orderRepository.existsByOrderNumberAndTenantId(request.orderNumber(), tenantId)) {
            throw new BusinessRuleException("Order number already exists in this tenant: " + request.orderNumber());
        }

        Order order = Order.builder()
                .tenantId(tenantId)
                .orderNumber(request.orderNumber())
                .totalAmount(request.totalAmount())
                .status(OrderStatus.PENDING)
                .createdBy(userId)
                .build();

        Order saved = orderRepository.save(order);
        log.info("Created order {} for tenant {}", saved.getId(), tenantId);
        return OrderResponse.from(saved);
    }

    public Page<OrderResponse> getOrders(UUID tenantId, Pageable pageable) {
        return orderRepository.findAllByTenantId(tenantId, pageable)
                .map(OrderResponse::from);
    }

    public Page<OrderResponse> getOrdersByStatus(UUID tenantId, OrderStatus status, Pageable pageable) {
        return orderRepository.findAllByTenantIdAndStatus(tenantId, status, pageable)
                .map(OrderResponse::from);
    }

    public OrderResponse getOrder(UUID orderId, UUID tenantId) {
        return orderRepository.findByIdAndTenantId(orderId, tenantId)
                .map(OrderResponse::from)
                .orElseThrow(() -> new ResourceNotFoundException("Order not found: " + orderId));
    }

    @Transactional
    public OrderResponse updateStatus(UUID orderId, UUID tenantId, UpdateOrderStatusRequest request) {
        Order order = orderRepository.findByIdAndTenantId(orderId, tenantId)
                .orElseThrow(() -> new ResourceNotFoundException("Order not found: " + orderId));

        validateStatusTransition(order.getStatus(), request.status());

        Order updated = Order.builder()
                .id(order.getId())
                .tenantId(order.getTenantId())
                .orderNumber(order.getOrderNumber())
                .totalAmount(order.getTotalAmount())
                .status(request.status())
                .createdBy(order.getCreatedBy())
                .version(order.getVersion())
                .createdAt(order.getCreatedAt())
                .build();

        Order saved = orderRepository.save(updated);
        log.info("Order {} status changed: {} -> {}", orderId, order.getStatus(), request.status());
        return OrderResponse.from(saved);
    }

    @Transactional
    public void cancelOrder(UUID orderId, UUID tenantId) {
        Order order = orderRepository.findByIdAndTenantId(orderId, tenantId)
                .orElseThrow(() -> new ResourceNotFoundException("Order not found: " + orderId));

        if (order.getStatus() == OrderStatus.DELIVERED) {
            throw new BusinessRuleException("Cannot cancel a delivered order");
        }
        if (order.getStatus() == OrderStatus.CANCELLED) {
            throw new BusinessRuleException("Order is already cancelled");
        }

        Order cancelled = Order.builder()
                .id(order.getId())
                .tenantId(order.getTenantId())
                .orderNumber(order.getOrderNumber())
                .totalAmount(order.getTotalAmount())
                .status(OrderStatus.CANCELLED)
                .createdBy(order.getCreatedBy())
                .version(order.getVersion())
                .createdAt(order.getCreatedAt())
                .build();

        orderRepository.save(cancelled);
        log.info("Order {} cancelled for tenant {}", orderId, tenantId);
    }

    private void validateStatusTransition(OrderStatus current, OrderStatus next) {
        boolean valid = switch (current) {
            case PENDING -> next == OrderStatus.SHIPPED || next == OrderStatus.CANCELLED;
            case SHIPPED -> next == OrderStatus.DELIVERED || next == OrderStatus.CANCELLED;
            case DELIVERED, CANCELLED -> false;
        };
        if (!valid) {
            throw new BusinessRuleException(
                    "Invalid status transition: " + current + " -> " + next);
        }
    }
}
