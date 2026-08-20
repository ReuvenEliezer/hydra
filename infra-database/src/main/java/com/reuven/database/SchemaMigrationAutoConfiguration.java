package com.reuven.database;

import liquibase.Liquibase;
import liquibase.integration.spring.Customizer;
import org.springframework.boot.autoconfigure.AutoConfiguration;
import org.springframework.boot.autoconfigure.condition.ConditionalOnClass;
import org.springframework.boot.autoconfigure.condition.ConditionalOnMissingBean;
import org.springframework.boot.context.properties.EnableConfigurationProperties;
import org.springframework.boot.liquibase.autoconfigure.LiquibaseAutoConfiguration;
import org.springframework.context.annotation.Bean;

/**
 * Discovered automatically via {@code META-INF/spring/...AutoConfiguration.imports}, mirroring
 * {@code rate-limit-starter}'s pattern — no {@code @ComponentScan} needed in either service.
 * Registers before {@link LiquibaseAutoConfiguration} so its {@code Customizer<Liquibase>} bean
 * is a known bean definition by the time Boot's {@code CustomizerConfiguration} looks for one.
 */
@AutoConfiguration(before = LiquibaseAutoConfiguration.class)
@ConditionalOnClass(Liquibase.class)
@EnableConfigurationProperties(SchemaMigrationProperties.class)
public class SchemaMigrationAutoConfiguration {

    @Bean
    @ConditionalOnMissingBean
    public SchemaStateInspector schemaStateInspector() {
        return new LiquibaseSchemaStateInspector();
    }

    @Bean
    @ConditionalOnMissingBean
    public Customizer<Liquibase> schemaMigrationGuard(
            SchemaStateInspector schemaStateInspector, SchemaMigrationProperties properties) {
        return new SchemaMigrationGuard(schemaStateInspector, properties);
    }
}
