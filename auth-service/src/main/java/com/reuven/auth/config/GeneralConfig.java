package com.reuven.auth.config;

import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import tools.jackson.databind.DeserializationFeature;
import tools.jackson.databind.MapperFeature;
import tools.jackson.databind.SerializationFeature;
import tools.jackson.databind.json.JsonMapper;

import java.time.Clock;


@Configuration
public class GeneralConfig {

    // Real wall-clock time everywhere except tests, which construct their own
    // JwtProvider with a Clock.fixed(...) instance to mint already-expired tokens
    // deterministically (see AuthIntegrationTest.expiredToken_returns401).
    @Bean
    public Clock clock() {
        return Clock.systemUTC();
    }

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
                .findAndAddModules() // ensures all modern time modules are loaded
//                .addModule(new DurationModule())
                .build();
    }

}
