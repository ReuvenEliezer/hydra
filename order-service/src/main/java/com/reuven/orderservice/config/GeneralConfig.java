package com.reuven.orderservice.config;

import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.context.annotation.Primary;
import tools.jackson.databind.DeserializationFeature;
import tools.jackson.databind.MapperFeature;
import tools.jackson.databind.SerializationFeature;
import tools.jackson.databind.json.JsonMapper;


@Configuration
public class GeneralConfig {

    @Bean
    public JsonMapper jsonMapper() {
        return JsonMapper.builder()
                // 1. Deserialization settings
                .configure(DeserializationFeature.FAIL_ON_UNKNOWN_PROPERTIES, false)
                .configure(DeserializationFeature.ACCEPT_SINGLE_VALUE_AS_ARRAY, true)

                // 2. Serialization settings (no need for WRITE_DATES_AS_TIMESTAMPS, it's already false by default!)
                .configure(SerializationFeature.FAIL_ON_EMPTY_BEANS, false)
                .configure(MapperFeature.DEFAULT_VIEW_INCLUSION, false)

                // 3. Structural additions
//                .changeDefaultPropertyInclusion(incl -> incl.withValueInclusion(JsonInclude.Include.NON_NULL))
                .findAndAddModules() // Takes care of loading all modern time modules
//                .addModule(new DurationModule())
                .build();
    }

}