package com.reuven.orderservice;

import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.webmvc.test.autoconfigure.AutoConfigureMockMvc;

import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.http.MediaType;
import org.springframework.security.test.context.support.WithMockUser;
import org.springframework.test.web.servlet.MockMvc;

import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.content;

@SpringBootTest
//@WithMockUser // ✅ generates a mock user and lifts the 401 block
@AutoConfigureMockMvc(addFilters = false) // ✅ disables all filters (including security) to focus purely on API logic
class OrderApiIntegrationTest {

    @Autowired
    private MockMvc mockMvc;

//    @Test
//    @DisplayName("POST API test: verifies that a complex, positive Duration passes serialization and deserialization correctly")
//    void shouldProcessOrderWithComplexDuration() throws Exception {
//        String requestJson = """
//            {
//                "orderId": "ORD-123",
//                "processingTime": {
//                    "day": 1,
//                    "hour": 5,
//                    "min": 30,
//                    "sec": 15,
//                    "ms": 500,
//                    "micro": 0,
//                    "nano": 0
//                },
//                "orderDate": "2026-06-19",
//                "createdAt": "2026-06-19T10:15:30"
//            }
//            """;
//
//        // ✅ updated path
//        mockMvc.perform(post("/api/test-orders")
//                        .contentType(MediaType.APPLICATION_JSON)
//                        .content(requestJson))
//                .andExpect(status().isOk())
//                .andExpect(jsonPath("$.orderId").value("ORD-123"))
//                .andExpect(jsonPath("$.processingTime.day").value(1))
//                .andExpect(jsonPath("$.processingTime.hour").value(5))
//                .andExpect(jsonPath("$.processingTime.min").value(30))
//                .andExpect(jsonPath("$.processingTime.ms").value(500))
//                .andExpect(jsonPath("$.orderDate").value("2026-06-19"))
//                .andExpect(jsonPath("$.createdAt").value("2026-06-19T10:15:30"));
//    }

    @Test
    @DisplayName("POST API test: verifies that a positive Duration in ISO-8601 format serializes correctly")
    void shouldProcessOrderWithComplexDuration() throws Exception {
        // An hour and a half is represented in the standard as PT1H30M
        String requestJson = """
            {
                "orderId": "ORD-123",
                "processingTime": "PT1H30M",
                "orderDate": "2026-06-19",
                "createdAt": "2026-06-19T10:15:30"
            }
            """;

        mockMvc.perform(post("/api/test-orders")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content(requestJson))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.orderId").value("ORD-123"))
                // verify that Jackson returns the Duration as a valid ISO string
                .andExpect(jsonPath("$.processingTime").value("PT1H30M"))
                .andExpect(jsonPath("$.orderDate").value("2026-06-19"))
                .andExpect(jsonPath("$.createdAt").value("2026-06-19T10:15:30"));
    }


//    @Test
//    @DisplayName("POST API test: handling a negative Duration")
//    void shouldProcessOrderWithNegativeDuration() throws Exception {
//        String requestJson = """
//            {
//                "orderId": "ORD-NEG",
//                "processingTime": {
//                    "negative": true,
//                    "day": 0,
//                    "hour": 0,
//                    "min": 45,
//                    "sec": 0,
//                    "ms": 0,
//                    "micro": 0,
//                    "nano": 0
//                },
//                "orderDate": "2026-06-19",
//                "createdAt": "2026-06-19T10:15:30"
//            }
//            """;
//
//        // ✅ updated path
//        mockMvc.perform(post("/api/test-orders")
//                        .contentType(MediaType.APPLICATION_JSON)
//                        .content(requestJson))
//                .andExpect(status().isOk())
//                .andExpect(jsonPath("$.processingTime.negative").value(true))
//                .andExpect(jsonPath("$.processingTime.min").value(45));
//    }

    @Test
    @DisplayName("POST API test: handling a negative Duration in the official ISO-8601 format")
    void shouldProcessOrderWithNegativeDuration() throws Exception {
        // Minus 45 minutes is represented in the international standard with a leading minus sign: -PT45M
        String requestJson = """
            {
                "orderId": "ORD-NEG",
                "processingTime": "-PT45M",
                "orderDate": "2026-06-19",
                "createdAt": "2026-06-19T10:15:30"
            }
            """;

        mockMvc.perform(post("/api/test-orders")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content(requestJson))
                .andExpect(status().isOk())
                // verify that the negative value is accepted and stored in its correct ISO structure
                .andExpect(jsonPath("$.processingTime").value("PT-45M"));
    }

    @Test
    @DisplayName("GET API test: matching LocalDate from the URL")
    void shouldParseLocalDateFromQueryParam() throws Exception {
        mockMvc.perform(get("/api/test-orders/search")
                        .param("date", "2026-06-19"))
                .andExpect(status().isOk())
                .andExpect(content().string("Orders for date: 2026-06-19"));
    }

    @Test
    @DisplayName("GET API test: matching Duration from the URL (ISO-8601 format)")
    void shouldParseDurationFromQueryParam() throws Exception {
        mockMvc.perform(get("/api/test-orders/by-duration")
                        .param("duration", "PT2H"))
                .andExpect(status().isOk())
                .andExpect(content().string("Searching items within the last: 120 minutes"));
    }
}
