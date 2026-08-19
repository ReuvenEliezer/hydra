package com.reuven.database;

import org.junit.jupiter.api.Test;
import org.springframework.boot.SpringApplication;
import org.springframework.context.ConfigurableApplicationContext;
import org.testcontainers.containers.PostgreSQLContainer;

import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.ResultSet;
import java.sql.Statement;
import java.util.List;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.TimeUnit;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * FR-007/G6: two service instances starting together against one empty database serialize on
 * {@code DATABASECHANGELOGLOCK} with no application-level coordination — exactly one applies
 * the changesets, the other waits and then finds nothing left to run, and both start.
 */
class ConcurrentMigrationTest {

    @Test
    void twoInstancesStartingTogether_exactlyOneApplies_bothStart() throws Exception {
        try (PostgreSQLContainer<?> postgres = new PostgreSQLContainer<>("postgres:16-alpine")) {
            postgres.start();

            CountDownLatch startGate = new CountDownLatch(1);
            ExecutorService executor = Executors.newFixedThreadPool(2);
            try {
                List<Future<ConfigurableApplicationContext>> futures = List.of(
                        executor.submit(() -> startInstance(postgres, startGate)),
                        executor.submit(() -> startInstance(postgres, startGate)));

                startGate.countDown(); // release both threads as close to simultaneously as possible

                ConfigurableApplicationContext context1 = futures.get(0).get(60, TimeUnit.SECONDS);
                ConfigurableApplicationContext context2 = futures.get(1).get(60, TimeUnit.SECONDS);
                try {
                    assertThat(context1.isActive()).isTrue();
                    assertThat(context2.isActive()).isTrue();

                    try (Connection connection = DriverManager.getConnection(
                            postgres.getJdbcUrl(), postgres.getUsername(), postgres.getPassword())) {
                        assertThat(changesetCount(connection)).isEqualTo(1);
                        assertThat(tableCount(connection, "widgets")).isEqualTo(1);
                    }
                } finally {
                    context1.close();
                    context2.close();
                }
            } finally {
                executor.shutdownNow();
            }
        }
    }

    private static ConfigurableApplicationContext startInstance(
            PostgreSQLContainer<?> postgres, CountDownLatch startGate) throws InterruptedException {
        startGate.await();
        return withRetryOnLoggingInitRace(() -> {
            SpringApplication app = new SpringApplication(MinimalTestApplication.class);
            return app.run(
                    "--spring.datasource.url=" + postgres.getJdbcUrl(),
                    "--spring.datasource.username=" + postgres.getUsername(),
                    "--spring.datasource.password=" + postgres.getPassword(),
                    "--spring.liquibase.change-log=classpath:changelog/base.yaml",
                    "--spring.jpa.hibernate.ddl-auto=none");
        });
    }

    /**
     * Spring Boot's {@code LoggingApplicationListener} mutates a shared, JVM-wide Logback
     * {@code LoggerContext} while handling {@code ApplicationEnvironmentPreparedEvent}, with no
     * synchronization of its own. Two {@code SpringApplication.run()} calls released as close to
     * simultaneously as possible — the whole point of this test — occasionally race on that
     * shared state and fail with a {@code ConcurrentModificationException}, before either
     * context has done anything Liquibase-related. This is a known Spring Boot limitation for
     * concurrent app bootstraps sharing one JVM, not a defect in the guard or in Liquibase's own
     * locking (what this test actually verifies) — retrying the whole, idempotent startup once
     * is the standard, safe way past it.
     */
    private static ConfigurableApplicationContext withRetryOnLoggingInitRace(
            java.util.function.Supplier<ConfigurableApplicationContext> starter) {
        try {
            return starter.get();
        } catch (RuntimeException e) {
            if (isConcurrentModificationRace(e)) {
                return starter.get();
            }
            throw e;
        }
    }

    private static boolean isConcurrentModificationRace(Throwable e) {
        for (Throwable cause = e; cause != null; cause = cause.getCause()) {
            if (cause instanceof java.util.ConcurrentModificationException) {
                return true;
            }
        }
        return false;
    }

    private static int changesetCount(Connection connection) throws Exception {
        try (Statement statement = connection.createStatement();
             ResultSet resultSet = statement.executeQuery("select count(*) from databasechangelog")) {
            resultSet.next();
            return resultSet.getInt(1);
        }
    }

    private static int tableCount(Connection connection, String tableName) throws Exception {
        try (ResultSet resultSet = connection.getMetaData()
                .getTables(null, null, tableName, new String[]{"TABLE"})) {
            int count = 0;
            while (resultSet.next()) {
                count++;
            }
            return count;
        }
    }
}
