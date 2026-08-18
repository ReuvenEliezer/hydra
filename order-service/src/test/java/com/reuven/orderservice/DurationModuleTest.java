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
//        // Build the Jackson 3 Mapper and register your custom JacksonModule
//        this.jsonMapper = JsonMapper.builder()
//                .addModule(new DurationModule())
//                .build();
//    }
//
//    @Test
//    @DisplayName("Serialization and deserialization of a full, precise Duration covering all time units")
//    void shouldSerializeAndDeserializeFullPreciseDuration() throws Exception {
//        // Define a complex duration: 2 days, 3 hours, 4 minutes, 5 seconds, 600 millis, 400 micros, 500 nanos
//        Duration originalDuration = Duration.ofDays(2)
//                .plusHours(3)
//                .plusMinutes(4)
//                .plusSeconds(5)
//                .plusMillis(600)
//                .plusNanos(400_500); // 400,000 nanos is 400 micros, plus a 500 nano remainder
//
//        // 1. Test serialization (Java -> JSON)
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
//                .doesNotContain("\"negative\""); // should not appear when positive
//
//        // 2. Test deserialization (JSON -> Java)
//        Duration deserializedDuration = jsonMapper.readValue(jsonResult, Duration.class);
//        assertThat(deserializedDuration).isEqualTo(originalDuration);
//    }
//
//    @Test
//    @DisplayName("Correct handling of a negative Duration")
//    void shouldHandleNegativeDurationCorrectly() throws Exception {
//        // Negative duration: minus 5 hours and 30 minutes
//        Duration negativeDuration = Duration.ofHours(5).plusMinutes(30).negated();
//
//        // 1. Test serialization (values should be written as positive alongside a negative: true flag)
//        String jsonResult = jsonMapper.writeValueAsString(negativeDuration);
//
//        assertThat(jsonResult)
//                .contains("\"negative\":true")
//                .contains("\"hour\":5")
//                .contains("\"min\":30");
//
//        // 2. Test deserialization (returns to a valid negative object in Java)
//        Duration deserializedDuration = jsonMapper.readValue(jsonResult, Duration.class);
//        assertThat(deserializedDuration).isEqualTo(negativeDuration);
//    }
//
//    @Test
//    @DisplayName("Backward compatibility: deserialization of old or partial JSON containing only hours and minutes")
//    void shouldBeBackwardCompatibleWithLegacyOrPartialJson() throws Exception {
//        // Legacy JSON received from a third-party system without day or nanosecond fields
//        String legacyJson = "{\"hour\":12,\"min\":45}";
//
//        Duration deserialized = jsonMapper.readValue(legacyJson, Duration.class);
//
//        // Verify the system didn't crash and filled in the rest with 0
//        Duration expected = Duration.ofHours(12).plusMinutes(45);
//        assertThat(deserialized).isEqualTo(expected);
//    }
//
//    @Test
//    @DisplayName("Serialization and deserialization of a zero value (Duration.ZERO)")
//    void shouldHandleDurationZero() throws Exception {
//        Duration zeroDuration = Duration.ZERO;
//
//        String jsonResult = jsonMapper.writeValueAsString(zeroDuration);
//
//        // All fields should be zeroed out
//        assertThat(jsonResult).isEqualTo("{\"day\":0,\"hour\":0,\"min\":0,\"sec\":0,\"ms\":0,\"micro\":0,\"nano\":0}");
//
//        Duration deserialized = jsonMapper.readValue(jsonResult, Duration.class);
//        assertThat(deserialized).isEqualTo(zeroDuration);
//    }
//
//    @Test
//    @DisplayName("Handling a null value in the serializer")
//    void shouldHandleNullDurationSafely() throws Exception {
//        // Sending null directly to writeValueAsString returns the text "null"
//        String jsonResult = jsonMapper.writeValueAsString(null);
//        assertThat(jsonResult).isEqualTo("null");
//
//        // Verify the deserializer can read the "null" string back into a null value in Java
//        Duration deserialized = jsonMapper.readValue("null", Duration.class);
//        assertThat(deserialized).isNull();
//    }
//}
