package com.reuven.database;

import org.springframework.boot.autoconfigure.SpringBootApplication;

/**
 * infra-database has no {@code @SpringBootApplication} of its own — it is a library module,
 * not a service. The US2 integration tests (T021-T024) need a real Spring Boot context to prove
 * {@link SchemaMigrationAutoConfiguration} actually wires up through Boot's own
 * {@code LiquibaseAutoConfiguration}, so this minimal app exists for exactly that: component and
 * entity scanning stay confined to this test package.
 */
@SpringBootApplication
public class MinimalTestApplication {
}
