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
//@WithMockUser // ✅ מייצר משתמש מדומה ומאשר את החסימה של ה-401
@AutoConfigureMockMvc(addFilters = false) // ✅ מבטל את כל הפילטרים (כולל אבטחה) כדי להתמקד בלוגיקה של ה-API בלבד
class OrderApiIntegrationTest {

    @Autowired
    private MockMvc mockMvc;

//    @Test
//    @DisplayName("בדיקת POST API: מוודא ש-Duration מורכב וחיובי עובר סריאליזציה ודסריאליזציה תקינה")
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
//        // ✅ נתיב מעודכן
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
    @DisplayName("בדיקת POST API: מוודא ש-Duration חיובי בפורמט ISO-8601 עובר סריאליזציה תקינה")
    void shouldProcessOrderWithComplexDuration() throws Exception {
        // שעה וחצי מיוצגת בסטנדרט כ-PT1H30M
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
                // וידוא שג'קסון מחזיר את ה-Duration כמחרוזת ISO תקנית
                .andExpect(jsonPath("$.processingTime").value("PT1H30M"))
                .andExpect(jsonPath("$.orderDate").value("2026-06-19"))
                .andExpect(jsonPath("$.createdAt").value("2026-06-19T10:15:30"));
    }


//    @Test
//    @DisplayName("בדיקת POST API: טיפול ב-Duration שלילי (Negative)")
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
//        // ✅ נתיב מעודכן
//        mockMvc.perform(post("/api/test-orders")
//                        .contentType(MediaType.APPLICATION_JSON)
//                        .content(requestJson))
//                .andExpect(status().isOk())
//                .andExpect(jsonPath("$.processingTime.negative").value(true))
//                .andExpect(jsonPath("$.processingTime.min").value(45));
//    }

    @Test
    @DisplayName("בדיקת POST API: טיפול ב-Duration שלילי (Negative) בפורמט ISO-8601 הרשמי")
    void shouldProcessOrderWithNegativeDuration() throws Exception {
        // מינוס 45 דקות מיוצג בסטנדרט הבינלאומי עם סימן מינוס בתחילה: -PT45M
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
                // וידוא שהערך השלילי נקלט ונשמר במבנה ה-ISO הנכון שלו
                .andExpect(jsonPath("$.processingTime").value("PT-45M"));
    }

    @Test
    @DisplayName("בדיקת GET API: התאמת LocalDate מה-URL")
    void shouldParseLocalDateFromQueryParam() throws Exception {
        // ✅ נתיב מעודכן
        mockMvc.perform(get("/api/test-orders/search")
                        .param("date", "2026-06-19"))
                .andExpect(status().isOk())
                .andExpect(content().string("Orders for date: 2026-06-19"));
    }

    @Test
    @DisplayName("בדיקת GET API: התאמת Duration מתוך ה-URL (פורמט ISO-8601)")
    void shouldParseDurationFromQueryParam() throws Exception {
        // ✅ נתיב מעודכן
        mockMvc.perform(get("/api/test-orders/by-duration")
                        .param("duration", "PT2H"))
                .andExpect(status().isOk())
                .andExpect(content().string("Searching items within the last: 120 minutes"));
    }
}
