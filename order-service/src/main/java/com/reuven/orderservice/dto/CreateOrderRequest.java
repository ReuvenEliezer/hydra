package com.reuven.orderservice.dto;

import jakarta.validation.constraints.DecimalMin;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import java.math.BigDecimal;

public record CreateOrderRequest(
        @NotBlank String orderNumber,
        @NotNull @DecimalMin("0.01") BigDecimal totalAmount
) {}
