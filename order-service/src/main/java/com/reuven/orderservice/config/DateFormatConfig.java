//package com.reuven.orderservice.config;
//
//import org.springframework.context.annotation.Configuration;
//import org.springframework.format.FormatterRegistry;
//import org.springframework.web.servlet.config.annotation.WebMvcConfigurer;
//
//import java.time.Duration;
//import java.time.LocalDate;
//import java.time.LocalDateTime;
//import java.time.format.DateTimeFormatter;
//
//@Configuration
//public class DateFormatConfig implements WebMvcConfigurer {
//# Default format definition for LocalDate (ISO_DATE standard: yyyy-MM-dd)
//spring.mvc.format.date=iso
//
//# Default format definition for LocalDateTime (ISO_DATE_TIME standard: yyyy-MM-dd'T'HH:mm:ss)
//spring.mvc.format.date-time=iso

//    @Override
//    public void addFormatters(FormatterRegistry registry) {
//        registry.addConverter(String.class, LocalDate.class,
//                source -> LocalDate.parse(source, DateTimeFormatter.ISO_DATE));
//
//        registry.addConverter(String.class, LocalDateTime.class,
//                source -> LocalDateTime.parse(source, DateTimeFormatter.ISO_DATE_TIME));
//    }
//}