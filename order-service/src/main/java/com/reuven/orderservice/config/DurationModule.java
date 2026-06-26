//package com.reuven.orderservice.config;
//
//import tools.jackson.core.JacksonException;
//import tools.jackson.core.JsonGenerator;
//import tools.jackson.core.JsonParser;
//import tools.jackson.core.Version;
//import tools.jackson.databind.DeserializationContext;
//import tools.jackson.databind.JacksonModule;
//import tools.jackson.databind.SerializationContext;
//import tools.jackson.databind.deser.std.StdDeserializer;
//import tools.jackson.databind.module.SimpleDeserializers;
//import tools.jackson.databind.module.SimpleSerializers;
//import tools.jackson.databind.node.ObjectNode;
//import tools.jackson.databind.ser.std.StdSerializer;
//
//import java.time.Duration;
//
//public class DurationModule extends JacksonModule {
//
//    @Override
//    public String getModuleName() {
//        return "Custom" + DurationModule.class.getSimpleName();
//    }
//
//    @Override
//    public Version version() {
//        return Version.unknownVersion();
//    }
//
//    @Override
//    public void setupModule(SetupContext context) {
//        // Register components within the Jackson 3 Context
//        context.addSerializers(new SimpleSerializers() {{
//            addSerializer(Duration.class, new DurationSerializer());
//        }});
//
//        context.addDeserializers(new SimpleDeserializers() {{
//            addDeserializer(Duration.class, new DurationDeserializer());
//        }});
//    }
//    // 1. Full serialization component (including days, ms, nano and negative)
//    static class DurationSerializer extends StdSerializer<Duration> {
//        DurationSerializer() {
//            super(Duration.class);
//        }
//
//        @Override
//        public void serialize(Duration value, JsonGenerator jgen, SerializationContext ctxt) throws JacksonException {
//            if (value == null) {
//                value = Duration.ZERO;
//            }
//
//            boolean isNegative = value.isNegative();
//            Duration absValue = value.abs();
//
//            long totalSeconds = absValue.getSeconds();
//            int totalNanos = absValue.getNano();
//
//            // Breakdown of the seconds and days part
//            long days = totalSeconds / 86400;
//            long hours = (totalSeconds % 86400) / 3600;
//            long minutes = (totalSeconds % 3600) / 60;
//            long seconds = totalSeconds % 60;
//
//            // Breakdown of time units smaller than nanoseconds
//            long millis = totalNanos / 1_000_000;
//            long micros = (totalNanos % 1_000_000) / 1_000;
//            long nanos = totalNanos % 1_000;
//
//            jgen.writeStartObject();
//
//            if (isNegative) {
//                jgen.writeBooleanProperty("negative", true);
//            }
//
//            // ✅ Fixed to writeNumberField (instead of writeNumberProperty which doesn't exist)
//            jgen.writeNumberProperty("day", days);
//            jgen.writeNumberProperty("hour", hours);
//            jgen.writeNumberProperty("min", minutes);
//            jgen.writeNumberProperty("sec", seconds);
//            jgen.writeNumberProperty("ms", millis);
//            jgen.writeNumberProperty("micro", micros);
//            jgen.writeNumberProperty("nano", nanos);
//
//            jgen.writeEndObject();
//        }
//    }
//
//    // 2. Full deserialization component (including days, ms, nano and negative)
//    static class DurationDeserializer extends StdDeserializer<Duration> {
//        DurationDeserializer() {
//            super(Duration.class);
//        }
//
//        @Override
//        public Duration deserialize(JsonParser p, DeserializationContext ctxt) throws JacksonException {
//            ObjectNode node = p.readValueAsTree();
//
//            // Reading all fields with default 0 (also supports old JSON that sent only hours/minutes/seconds)
//            boolean isNegative = node.path("negative").asBoolean(false);
//            long days = node.path("day").asLong(0);
//            long hours = node.path("hour").asLong(0);
//            long minutes = node.path("min").asLong(0);
//            long seconds = node.path("sec").asLong(0);
//            long millis = node.path("ms").asLong(0);
//            long micros = node.path("micro").asLong(0);
//            long nanos = node.path("nano").asLong(0);
//
//            // Calculating the times back to one accurate Java object
//            long totalSeconds = (days * 86400) + (hours * 3600) + (minutes * 60) + seconds;
//            long totalNanos = (millis * 1_000_000) + (micros * 1_000) + nanos;
//
//            Duration duration = Duration.ofSeconds(totalSeconds, totalNanos);
//
//            return isNegative ? duration.negated() : duration;
//        }
//    }
//}