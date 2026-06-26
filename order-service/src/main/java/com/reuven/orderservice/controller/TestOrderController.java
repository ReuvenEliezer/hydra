package com.reuven.orderservice.controller;


import org.springframework.web.bind.annotation.*;

import java.time.Duration;
import java.time.LocalDate;
import java.time.LocalDateTime;

@RestController
@RequestMapping("/api/test-orders")
public class TestOrderController {

    public record OrderResponse(
            String orderId,
            Duration processingTime,
            LocalDate orderDate,
            LocalDateTime createdAt
    ) {}

    @PostMapping
    public OrderResponse createOrder(@RequestBody OrderResponse request) {
        return request;
    }

    @GetMapping("/search")
    public String searchOrdersByDate(@RequestParam("date") LocalDate date) {
        return "Orders for date: " + date.toString();
    }

    // The new Duration API in the URL you requested earlier
    @GetMapping("/by-duration")
    public String getOrdersByDuration(@RequestParam("duration") Duration duration) {
        return "Searching items within the last: " + duration.toMinutes() + " minutes";
    }


}