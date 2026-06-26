//package com.reuven.orderservice;
//
//import com.reuven.orderservice.config.DurationModule;
//import tools.jackson.databind.json.JsonMapper;
//import org.junit.jupiter.api.BeforeEach;
//import org.junit.jupiter.api.DisplayName;
//import org.junit.jupiter.api.Test;
//import java.time.Duration;
//
//import static org.assertj.core.api.Assertions.assertThat;
//
//class DurationModuleTest {
//
//    private JsonMapper jsonMapper;
//
//    @BeforeEach
//    void setUp() {
//        // בניית ה-Mapper של Jackson 3 ורישום ה-JacksonModule המותאם שלך
//        this.jsonMapper = JsonMapper.builder()
//                .addModule(new DurationModule())
//                .build();
//    }
//
//    @Test
//    @DisplayName("סריאליזציה ודסריאליזציה של Duration מלא ומדויק הכולל את כל יחידות הזמן")
//    void shouldSerializeAndDeserializeFullPreciseDuration() throws Exception {
//        // הגדרת משך זמן מורכב: יומיים, 3 שעות, 4 דקות, 5 שניות, 600 מילי, 400 מיקרו, 500 ננו
//        Duration originalDuration = Duration.ofDays(2)
//                .plusHours(3)
//                .plusMinutes(4)
//                .plusSeconds(5)
//                .plusMillis(600)
//                .plusNanos(400_500); // 400,000 ננו זה 400 מיקרו, ועוד 500 ננו שארית
//
//        // 1. בדיקת סריאליזציה (Java -> JSON)
//        String jsonResult = jsonMapper.writeValueAsString(originalDuration);
//
//        assertThat(jsonResult)
//                .contains("\"day\":2")
//                .contains("\"hour\":3")
//                .contains("\"min\":4")
//                .contains("\"sec\":5")
//                .contains("\"ms\":600")
//                .contains("\"micro\":400")
//                .contains("\"nano\":500")
//                .doesNotContain("\"negative\""); // לא צריך להופיע כשחיובי
//
//        // 2. בדיקת דסריאליזציה (JSON -> Java)
//        Duration deserializedDuration = jsonMapper.readValue(jsonResult, Duration.class);
//        assertThat(deserializedDuration).isEqualTo(originalDuration);
//    }
//
//    @Test
//    @DisplayName("טיפול מושלם ב-Duration שלילי (Negative)")
//    void shouldHandleNegativeDurationCorrectly() throws Exception {
//        // משך זמן שלילי: מינוס 5 שעות ו-30 דקות
//        Duration negativeDuration = Duration.ofHours(5).plusMinutes(30).negated();
//
//        // 1. בדיקת סריאליזציה (הערכים צריכים להיכתב כחיוביים לצד דגל negative: true)
//        String jsonResult = jsonMapper.writeValueAsString(negativeDuration);
//
//        assertThat(jsonResult)
//                .contains("\"negative\":true")
//                .contains("\"hour\":5")
//                .contains("\"min\":30");
//
//        // 2. בדיקת דסריאליזציה (החזרה לאובייקט שלילי תקין ב-Java)
//        Duration deserializedDuration = jsonMapper.readValue(jsonResult, Duration.class);
//        assertThat(deserializedDuration).isEqualTo(negativeDuration);
//    }
//
//    @Test
//    @DisplayName("תאימות לאחור: דסריאליזציה של JSON ישן או חלקי המכיל שעות ודקות בלבד")
//    void shouldBeBackwardCompatibleWithLegacyOrPartialJson() throws Exception {
//        // JSON ישן שהגיע ממערכת צד-שלישי ללא שדות ימים או ננו-שניות
//        String legacyJson = "{\"hour\":12,\"min\":45}";
//
//        Duration deserialized = jsonMapper.readValue(legacyJson, Duration.class);
//
//        // מוודא שהמערכת לא קרסה והשלימה את השאר ל-0
//        Duration expected = Duration.ofHours(12).plusMinutes(45);
//        assertThat(deserialized).isEqualTo(expected);
//    }
//
//    @Test
//    @DisplayName("סריאליזציה ודסריאליזציה של ערך אפס (Duration.ZERO)")
//    void shouldHandleDurationZero() throws Exception {
//        Duration zeroDuration = Duration.ZERO;
//
//        String jsonResult = jsonMapper.writeValueAsString(zeroDuration);
//
//        // כל השדות צריכים להתאפס
//        assertThat(jsonResult).isEqualTo("{\"day\":0,\"hour\":0,\"min\":0,\"sec\":0,\"ms\":0,\"micro\":0,\"nano\":0}");
//
//        Duration deserialized = jsonMapper.readValue(jsonResult, Duration.class);
//        assertThat(deserialized).isEqualTo(zeroDuration);
//    }
//
//    @Test
//    @DisplayName("טיפול בערך null על ידי הסריאלייזר")
//    void shouldHandleNullDurationSafely() throws Exception {
//        // שליחת null ישירות ל-writeValueAsString מחזירה את המילה "null" בטקסט
//        String jsonResult = jsonMapper.writeValueAsString(null);
//        assertThat(jsonResult).isEqualTo("null");
//
//        // בדיקה שהדסריאלייזר יודע לקרוא מחרוזת "null" חזרה לטיפוס null ב-Java
//        Duration deserialized = jsonMapper.readValue("null", Duration.class);
//        assertThat(deserialized).isNull();
//    }
//}
