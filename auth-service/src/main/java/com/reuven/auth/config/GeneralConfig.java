package com.reuven.auth.config;

import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import tools.jackson.databind.DeserializationFeature;
import tools.jackson.databind.MapperFeature;
import tools.jackson.databind.SerializationFeature;
import tools.jackson.databind.json.JsonMapper;


@Configuration
public class GeneralConfig {

    @Bean
    public JsonMapper jsonMapper() {
        return JsonMapper.builder()
                // 1. הגדרות דסריאליזציה
                .configure(DeserializationFeature.FAIL_ON_UNKNOWN_PROPERTIES, false)
                .configure(DeserializationFeature.ACCEPT_SINGLE_VALUE_AS_ARRAY, true)

                // 2. הגדרות סריאליזציה (אין צורך ב-WRITE_DATES_AS_TIMESTAMPS, הוא כבר false כברירת מחדל!)
                .configure(SerializationFeature.FAIL_ON_EMPTY_BEANS, false)
                .configure(MapperFeature.DEFAULT_VIEW_INCLUSION, false)

                // 3. תוספות מבנה
//                .changeDefaultPropertyInclusion(incl -> incl.withValueInclusion(JsonInclude.Include.NON_NULL))
                .findAndAddModules() // דואג לטעינת כל מודולי הזמן המודרניים
//                .addModule(new DurationModule())
                .build();
    }

}
