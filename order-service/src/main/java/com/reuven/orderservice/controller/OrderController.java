package com.reuven.orderservice.controller;


import com.reuven.JwtClaimNames;
import com.reuven.Roles;
import com.reuven.orderservice.dto.CreateOrderRequest;
import com.reuven.orderservice.dto.OrderResponse;
import com.reuven.orderservice.dto.OrderStatus;
import com.reuven.orderservice.dto.UpdateOrderStatusRequest;
import com.reuven.orderservice.service.OrderService;
import jakarta.validation.Valid;
import org.springframework.data.domain.Page;
import org.springframework.data.domain.Pageable;
import org.springframework.data.web.PageableDefault;
import org.springframework.http.HttpStatus;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.web.bind.annotation.*;

import java.util.UUID;

@RestController
@RequestMapping("/api/orders")
public class OrderController {

    private final OrderService orderService;

    public OrderController(OrderService orderService) {
        this.orderService = orderService;
    }

//    @GetMapping
////    @PreAuthorize("hasRole('USER')")
//    @PreAuthorize("hasAuthority('ROLE_USER')")
////    @PreAuthorize("hasRole('USER')") // Spring will automatically search for ROLE_USER
////    @PreAuthorize("hasAuthority('ROLE_USER')") // Check exactly the value coming in the JWT
//    public List<String> getOrders(@AuthenticationPrincipal Jwt jwt) {
//        // Now, the internal logic will decide what to fetch
//        String userId = jwt.getSubject();
//        return List.of("Order 1 for user: " + userId, "Order 2 for user: " + userId);

    /// /        return orderService.getOrdersForUser(userId);
//    }
    @GetMapping
//    @PreAuthorize("hasAnyAuthority('ROLE_USER', 'ROLE_ADMIN', 'ROLE_SUPER_ADMIN')")
    @PreAuthorize(Roles.USER)
    public Page<OrderResponse> getOrders(
            @AuthenticationPrincipal Jwt jwt,
            @RequestParam(name = "status", required = false) OrderStatus status,
            @PageableDefault(size = 20, sort = "createdAt") Pageable pageable) {

        UUID tenantId = UUID.fromString(jwt.getClaimAsString(JwtClaimNames.TENANT_ID));
        if (status != null) {
            return orderService.getOrdersByStatus(tenantId, status, pageable);
        }
        return orderService.getOrders(tenantId, pageable);
    }

//    @PostMapping
//    @PreAuthorize("hasAuthority('ROLE_ADMIN')") // Only an admin can create an order
//    public void createOrder(@AuthenticationPrincipal Jwt jwt) {
//        var auths = org.springframework.security.core.context.SecurityContextHolder.getContext().getAuthentication().getAuthorities();
//        System.out.println("DEBUG - Current Authorities: " + auths);
//        var auth = SecurityContextHolder.getContext().getAuthentication();
//        System.out.println("USER AUTH: " + auth);
//        System.out.println("AUTHORITIES: " + auth.getAuthorities());
//        String userId = jwt.getSubject();
//        // Here you use the userId to bring orders from the Database
//    }

    @PostMapping
    @ResponseStatus(HttpStatus.CREATED)
    @PreAuthorize(Roles.USER)
    public OrderResponse createOrder(
            @Valid @RequestBody CreateOrderRequest request,
            @AuthenticationPrincipal Jwt jwt) {

        UUID tenantId = UUID.fromString(jwt.getClaimAsString(JwtClaimNames.TENANT_ID));
        UUID userId = UUID.fromString(jwt.getSubject());
        return orderService.createOrder(request, tenantId, userId);
    }

    @GetMapping("/{id}")
    @PreAuthorize(Roles.USER)
    public OrderResponse getOrder(
            @PathVariable("id") UUID id,
            @AuthenticationPrincipal Jwt jwt) {
        UUID tenantId = UUID.fromString(jwt.getClaimAsString(JwtClaimNames.TENANT_ID));
        return orderService.getOrder(id, tenantId);
    }

    @PatchMapping("/{id}/status")
    @PreAuthorize(Roles.ADMIN)
    public OrderResponse updateStatus(
            @PathVariable("id") UUID id,
            @Valid @RequestBody UpdateOrderStatusRequest request,
            @AuthenticationPrincipal Jwt jwt) {

        UUID tenantId = UUID.fromString(jwt.getClaimAsString(JwtClaimNames.TENANT_ID));
        return orderService.updateStatus(id, tenantId, request);
    }

    @DeleteMapping("/{id}")
    @ResponseStatus(HttpStatus.NO_CONTENT)
    @PreAuthorize(Roles.ADMIN)
    public void cancelOrder(
            @PathVariable("id") UUID id,
            @AuthenticationPrincipal Jwt jwt) {

        UUID tenantId = UUID.fromString(jwt.getClaimAsString(JwtClaimNames.TENANT_ID));
        orderService.cancelOrder(id, tenantId);
    }

}