---
description: "Task list for Liquibase Schema Migration Authority"
---

# Tasks: Liquibase Schema Migration Authority

**Input**: Design documents from `/specs/006-liquibase-schema-migration/`

**Prerequisites**: [plan.md](./plan.md), [spec.md](./spec.md), [research.md](./research.md),
[data-model.md](./data-model.md), [contracts/](./contracts/), [quickstart.md](./quickstart.md)

**Tests**: Test tasks ARE included. The plan calls for a guard test matrix in `infra-database`
(`plan.md` Project Structure) and the constitution requires real infrastructure via
Testcontainers rather than mocks. Quickstart scenarios S0–S11 are the acceptance surface.

**Organization**: Tasks are grouped by user story. Two hard sequencing rules from the design
override the usual "stories are independent" freedom — see **Dependencies & Execution Order**.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: `[US1]`–`[US4]`, mapping to spec.md user stories

## Build command

`mvn` is not on `PATH` and there is no `./mvnw` — use the wrapper distribution directly:

```bash
~/.m2/wrapper/dists/apache-maven-3.9.16-bin/5grr65jo27hi51sujmtcldfovl/apache-maven-3.9.16/bin/mvn -q -pl infra-database -am test
```

Reactor order: `infra-shared` → `infra-database` → `rate-limit-starter` → `auth-service` →
`order-service` → `integration-tests`.

---

## Phase 1: Setup (Dependency Activation)

**Purpose**: Put Spring Boot 4's Liquibase auto-configuration module on the classpath so the
existing changelogs can execute at all (research R1). Nothing else in this feature works until
this is true.

- [X] T001 Finish the Liquibase dependency swap in `infra-database/pom.xml`: confirm the working-tree change from `org.liquibase:liquibase-core` to `org.springframework.boot:spring-boot-starter-liquibase` (runtime, versionless — the Boot 4.1.0 BOM pins it), and add `org.springframework.boot:spring-boot-starter-liquibase-test` with `<scope>test</scope>` alongside the existing `spring-boot-starter-data-jpa-test`, per research R1
- [X] T002 Verify Boot's Liquibase auto-configuration actually resolves by running `mvn -pl infra-database -am dependency:tree` and confirming `org.springframework.boot:spring-boot-liquibase` (containing `LiquibaseAutoConfiguration`) appears on the compile/runtime path of `infra-database`, `auth-service`, and `order-service` — with neither service POM modified
- [X] T003 [P] Create the module source roots `infra-database/src/main/java/com/reuven/database/` and `infra-database/src/test/java/com/reuven/database/` (the module has no `src` directory today; it is a dependency aggregator that this feature turns into a real module per Constitution Principle II)

**Checkpoint**: The changelogs now run. Both services will attempt Liquibase on next startup —
which is exactly why Phase 2 must land before anyone starts a service against a real database.

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Two things that MUST be true before any story is implemented or any environment is
touched: the changelogs must be *correct* (they can never be edited again after the first
environment is baselined), and the `validate` parity assumption must be *proven by running*.

**⚠️ CRITICAL**: T004 is a hard sequencing gate — the changelog correction must land before the
first environment is reconciled anywhere (research R7/D1, baseline contract "Ordering rule").
T005–T008 are the S0 gate: if parity fails, the fix is to correct the changeset, never to relax
`validate` (quickstart S0).

- [X] T004 Delete the `addForeignKeyConstraint` block naming `fk_orders_tenant` (base `orders.tenant_id` → referenced `tenants.id`) from `order-service/src/main/resources/changes/001-init-order-schema.yaml`, leaving `createTable orders` and both `createIndex` blocks intact — order-service's database has no `tenants` table and never has, so this constraint makes every fresh-database startup fail (research R7/D1)
- [X] T005 [P] Verify the `include:` paths inside both master changelogs resolve to files that exist: `auth-service/src/main/resources/db/changelog/db.changelog-master.yaml` (→ `db/changelog/changes/001-init-auth-schema.yaml`, `db/changelog/changes/002-tenant-url-identifier.yaml`) and `order-service/src/main/resources/changes/db.changelog-master.yaml` (→ `changes/001-init-order-schema.yaml`), per Constitution Principle III — move no resource
- [X] T006 S0 parity gate on PostgreSQL: add a throwaway harness (a `@SpringBootTest` in `auth-service/src/test/java/com/reuven/auth/` and one in `order-service/src/test/java/com/reuven/orderservice/`, or an equivalent scratch run) that boots each service against an empty Testcontainers `PostgreSQLContainer` with `spring.jpa.hibernate.ddl-auto=validate`, and confirm the context starts, `DATABASECHANGELOG` holds every changeset, and no Hibernate DDL appears in the log
- [X] T007 [P] S0 parity gate on H2 in PostgreSQL mode: repeat T006's check against a throwaway in-memory H2 URL (`jdbc:h2:mem:...;MODE=PostgreSQL;DATABASE_TO_LOWER=TRUE`) for both services, since the `local` profile and `AuthOrderCrossServiceIntegrationTest` both run H2
- [X] T008 Record the S0 outcome in `specs/006-liquibase-schema-migration/research.md` under R8; if either engine rejects a column (the `varchar(30)`/`varchar(20)`/`varchar(50)` vs entity-default `varchar(255)` and `orders.updated_at` nullability divergences listed in data-model.md §4), fix it by editing the changeset in place — legal only now, before any environment is baselined — and re-run T006/T007

**Checkpoint**: Changelogs are correct and provably compatible with `validate`. Story work can
begin.

---

## Phase 3: User Story 1 - Schema changes are tracked and repeatable (Priority: P1) 🎯 MVP

**Goal**: Every schema change is captured in a versioned, ordered changeset that applies
automatically at startup, so a new environment can be stood up with no manual database work.

**Independent Test**: Start auth-service against a brand-new empty database and confirm the
schema that results was created entirely by the changesets executing in order, with no manual
intervention (quickstart S1).

### Tests for User Story 1

- [X] T009 [P] [US1] Fresh-database test (S1) in `auth-service/src/test/java/com/reuven/auth/SchemaMigrationIntegrationTest.java`: boot against an empty Testcontainers PostgreSQL database and assert `tenants`, `users`, `user_roles`, `reserved_tenant_identifiers` exist per data-model.md §4, with one `DATABASECHANGELOG` row per changeset in `ORDEREXECUTED` order
- [X] T010 [P] [US1] Restart no-op test (S2) in `auth-service/src/test/java/com/reuven/auth/SchemaMigrationIntegrationTest.java`: restart the context against the same database and assert the `DATABASECHANGELOG` row count and `DEPLOYMENT_ID` set are unchanged (FR-002)
- [X] T011 [US1] Incremental-changeset test (S3) in `infra-database/src/test/java/com/reuven/database/IncrementalChangesetTest.java`: against a disposable H2 database, apply a changelog, then apply a superset changelog with one extra changeset and assert exactly one new `DATABASECHANGELOG` row (FR-001) — use a test-only changelog under `infra-database/src/test/resources/`, never a service changelog

### Implementation for User Story 1

- [X] T012 [US1] Add an explicit `spring.liquibase.change-log: classpath:/db/changelog/db.changelog-master.yaml` under `spring:` in `auth-service/src/main/resources/application.yaml`, making the changelog location a reviewable contract rather than an implicit convention (research R2, Constitution Principle III)
- [X] T013 [US1] Run the existing auth-service suite (`mvn -pl auth-service -am test`) and confirm `BaseIntegrationTest`-derived tests still pass now that the `test` profile's Testcontainers PostgreSQL schema is built by the changelogs rather than by `ddl-auto: update`

**Checkpoint**: auth-service's changesets execute, are recorded, and never re-run. US1 is
demonstrable on its own.

---

## Phase 4: User Story 2 - Existing environments upgrade without data loss (Priority: P1)

**Goal**: A database whose schema was already built by Hibernate refuses to start until an
explicit one-time reconciliation is performed, and that reconciliation marks the changesets
applied without executing them and without touching a single row.

**Independent Test**: Take a database with a Hibernate-built schema and real rows, run the
reconciliation, and confirm the service starts afterward with every pre-existing row intact
(quickstart S4–S7).

### Implementation for User Story 2

- [X] T014 [P] [US2] Create `infra-database/src/main/java/com/reuven/database/SchemaMigrationProperties.java` as a `@ConfigurationProperties("hydra.database.baseline")` record with `enabled` (boolean, default `false`) and `tag` (String, default `baseline-<UTC instant>` computed when absent), per data-model.md §2 — record, not getters/setters
- [X] T015 [P] [US2] Create `infra-database/src/main/java/com/reuven/database/SchemaStateInspector.java`, the abstraction Constitution Principle II requires: two queries — `hasMigrationHistory(Database)` (true when `DATABASECHANGELOG` exists **and** has ≥ 1 row) and `hasApplicationTables(Database)` (true when ≥ 1 table exists that is not `DATABASECHANGELOG`/`DATABASECHANGELOGLOCK`)
- [X] T016 [US2] Create `infra-database/src/main/java/com/reuven/database/LiquibaseSchemaStateInspector.java` implementing T015 over JDBC metadata on the live Liquibase connection, row-count based rather than table-existence based so an empty `DATABASECHANGELOG` left by an aborted first attempt still counts as "no history" (research R5)
- [X] T017 [US2] Create `infra-database/src/main/java/com/reuven/database/SchemaMigrationGuard.java` as a `liquibase.integration.spring.Customizer<Liquibase>` bean implementing the full six-row decision matrix in data-model.md §3: refuse startup with an explicit exception naming the database and `hydra.database.baseline.enabled=true` when tables exist with no history; when the flag is set in that state call `Liquibase.changeLogSync(Contexts, LabelExpression)` then `Liquibase.tag(...)` with the baseline tag and log at WARN; log and no-op in every other combination (FR-004, FR-005, FR-008)
- [X] T018 [US2] Create `infra-database/src/main/java/com/reuven/database/SchemaMigrationAutoConfiguration.java` registering the properties, the inspector, and the guard as beans, constructor-injected, guarded by `@ConditionalOnClass(Liquibase.class)` and `@ConditionalOnMissingBean` for each contributed type
- [X] T019 [US2] Register T018 in `infra-database/src/main/resources/META-INF/spring/org.springframework.boot.autoconfigure.AutoConfiguration.imports` (new file — mirror `rate-limit-starter`'s, one fully-qualified class name per line)

### Tests for User Story 2

- [X] T020 [P] [US2] Decision-matrix test in `infra-database/src/test/java/com/reuven/database/SchemaMigrationGuardTest.java`: drive all six rows of data-model.md §3 against in-memory H2 (empty DB, legacy tables without history, history present) and assert the outcome — proceed, refuse, or sync — for each with `baseline.enabled` both false and true
- [X] T021 [P] [US2] Legacy-refusal test (S4) in `infra-database/src/test/java/com/reuven/database/SchemaMigrationBaselineTest.java` against a Testcontainers `PostgreSQLContainer`: build a schema the old way with rows in it, start with no baseline flag, and assert startup fails before any DDL is issued, that the message names `hydra.database.baseline.enabled=true`, and that the schema and rows are untouched (FR-005)
- [X] T022 [US2] Reconciliation test (S5) in `infra-database/src/test/java/com/reuven/database/SchemaMigrationBaselineTest.java`: against the T021 database with `hydra.database.baseline.enabled=true`, assert every changeset is recorded in `DATABASECHANGELOG` without its statements executing, that a baseline `TAG` is present, that the same startup then completes, and that every pre-existing row is present and byte-for-byte unchanged (FR-004, SC-002)
- [X] T023 [US2] Repeat-safety test (S6) in `infra-database/src/test/java/com/reuven/database/SchemaMigrationBaselineTest.java`: run the reconciliation a second time and then start normally, asserting no new `DATABASECHANGELOG` rows, no error, and a successful start (spec Edge Cases)
- [X] T024 [US2] Mismatch test (S7) in `infra-database/src/test/java/com/reuven/database/SchemaMigrationBaselineTest.java`: drop a column the entities require from the legacy schema, reconcile, and assert the sync itself succeeds while the *same* startup's Hibernate `validate` fails naming the missing column — the environment is never left silently believing it is current (spec Edge Cases, plan design decision 4)

**Checkpoint**: Legacy environments are safe. The cutover can be performed on a real database.

---

## Phase 5: User Story 3 - Every service's migration scripts are discovered (Priority: P2)

**Goal**: order-service's changelog, which sits outside Liquibase's default path, is found and
executed like any other.

**Independent Test**: Start order-service against an empty database and confirm its changesets
run — not just auth-service's (quickstart S8).

### Implementation for User Story 3

- [X] T025 [US3] Add `spring.liquibase.change-log: classpath:/changes/db.changelog-master.yaml` under `spring:` in `order-service/src/main/resources/application.yaml`, pointing at the non-default location where the master already lives — leave the file where it is (research R2, FR-003)

### Tests for User Story 3

- [X] T026 [P] [US3] Fresh-database test (S8) in `order-service/src/test/java/com/reuven/orderservice/SchemaMigrationIntegrationTest.java`: boot against an empty database and assert `orders` exists with `idx_orders_tenant_id` and `idx_orders_tenant_created`, no `fk_orders_tenant`, and order-service's own `DATABASECHANGELOG` holding its changesets (SC-005)
- [X] T027 [P] [US3] Negative discovery test (S8) in `order-service/src/test/java/com/reuven/orderservice/SchemaMigrationIntegrationTest.java`: override `spring.liquibase.change-log` to a nonexistent classpath path and assert startup fails with Boot's `LiquibaseChangelogMissingFailureAnalyzer` message naming that path — proving a lost changelog is loud, not silent (G3)

**Checkpoint**: Both services' changelogs execute. SC-005 is satisfiable.

---

## Phase 6: User Story 4 - Schema drift is caught, not silently patched (Priority: P2)

**Goal**: Hibernate is demoted to verification only, in every profile of both services,
including local — an entity change without a matching changeset fails startup instead of being
silently applied.

**Independent Test**: Add a field to an entity with no changeset and confirm startup fails with
a mismatch error, on a developer's own machine under the `local` profile as well as in deployed
environments (quickstart S9).

### Implementation for User Story 4

- [X] T028 [P] [US4] Change `spring.jpa.hibernate.ddl-auto` from `update` to `validate` in `auth-service/src/main/resources/application.yaml` (line 19)
- [X] T029 [P] [US4] Change `spring.jpa.hibernate.ddl-auto` from `update` to `validate` in `auth-service/src/main/resources/application-local.yml` (line 14)
- [X] T030 [P] [US4] Change `spring.jpa.hibernate.ddl-auto` from `update` to `validate` in `auth-service/src/main/resources/application-test.yml` (line 10)
- [X] T031 [P] [US4] Add a `spring.jpa.hibernate.ddl-auto: validate` block to `order-service/src/main/resources/application.yaml`, which has no `jpa` section at all today — with an embedded H2 datasource and no property, Boot's default would otherwise be inferred rather than stated (research R7/D2, FR-006)
- [X] T032 [P] [US4] Change `spring.jpa.hibernate.ddl-auto` from `update` to `validate` in `order-service/src/main/resources/application-local.yml` (line 14)
- [X] T033 [P] [US4] Change `spring.jpa.hibernate.ddl-auto` from `update` to `validate` in `order-service/src/main/resources/application-dev.yml` (line 10)
- [X] T034 [US4] Audit every remaining profile file for a surviving `ddl-auto` override — `auth-service/src/main/resources/application-prod.yml`, `order-service/src/test/resources/application.yml`, `integration-tests/src/test/resources/application.yml` — and confirm each either says `validate` or inherits it, since one profile still saying `update` re-arms the mechanism this feature disarms (startup contract, "Required configuration per service")

### Tests for User Story 4

- [X] T035 [P] [US4] Drift-detection test (S9) in `order-service/src/test/java/com/reuven/orderservice/SchemaDriftTest.java`: boot against a changelog-built schema with an entity mapping that declares a column no changeset creates, and assert startup fails with Hibernate's mismatch error naming the column and that no column is created (SC-004, FR-006)
- [X] T036 [US4] Local-profile drift check (S9, the "no environment is exempt" half): run the same drift scenario under the `local` profile against a throwaway H2 file database and assert the identical failure, proving FR-006 holds on a developer machine (G8)

**Checkpoint**: All four stories are functional. Liquibase is the sole schema authority.

---

## Phase 7: Polish & Cross-Cutting Concerns

- [X] T037 [P] Concurrency test (S10) in `infra-database/src/test/java/com/reuven/database/ConcurrentMigrationTest.java`: start two contexts simultaneously against one empty Testcontainers PostgreSQL database and assert both start, that exactly one applied the changesets, and that the other serialized on `DATABASECHANGELOGLOCK` with no duplicated object (FR-007, G6)
- [X] T038 [P] Failure-semantics test (S11) in `infra-database/src/test/java/com/reuven/database/FailedChangesetTest.java` against Testcontainers PostgreSQL: apply a changelog whose last changeset is guaranteed to fail, assert startup fails, that the failed changeset is absent from `DATABASECHANGELOG`, that its own statements rolled back, that previously applied changesets are untouched, and that correcting it and restarting succeeds (FR-010, G7)
- [X] T039 Remove the throwaway S0 harness from T006/T007 once its findings are recorded in T008, keeping only the permanent tests from Phases 3–7
- [X] T040 Run the cross-service regression (`mvn -pl integration-tests -am test`) and confirm `AuthOrderCrossServiceIntegrationTest` passes — after this feature it doubles as proof that both changelogs are portable to H2 in PostgreSQL mode (research R9)
- [X] T041 [P] Document the local-development breaking change in `RUNNING.md`: every developer's `~/data/auth_db.mv.db` and `~/data/orders_db.mv.db` is a legacy database under the new rules and the next run refuses to start until it is baselined once (`--hydra.database.baseline.enabled=true`) or deleted; back the files up first (research R9)
- [X] T042 [P] Document the schema-change workflow in `README.md`: all future schema changes are new changesets under each service's changelog, Hibernate never generates DDL again, and the `hydra.database.baseline.*` flag is a one-time per-environment human act that must never be baked into a profile YAML or deployment manifest (FR-009, baseline contract)
- [X] T043 Write the per-environment cutover runbook in `specs/006-liquibase-schema-migration/quickstart.md` (or a sibling `rollout.md`): local → dev → staging → production, one environment at a time, each with a successful update-plus-validate startup observed before moving to the next, and the audit query that answers "which environment was reconciled, and when" from the baseline `TAG` and `DATEEXECUTED` (FR-008, baseline contract "Order of environments")
- [X] T044 Run the full reactor build (`mvn -q clean test`) and then walk quickstart.md S0–S11 end to end, confirming each scenario's expected outcome before declaring the feature done

---

## Dependencies & Execution Order

### Hard sequencing rules (override normal story independence)

1. **T004 before any baseline anywhere.** Once a changeset has been synced into an environment,
   its checksum is recorded and editing it turns every later startup into a checksum-validation
   failure. The `fk_orders_tenant` removal — and any T008 column correction — must land before
   the first reconciliation is run in *any* environment, local included.
2. **S0 (T006–T008) before Phases 3–6 are built on.** Whether Hibernate `validate` accepts a
   changelog-built schema is the one unproven assumption in the plan; if it fails, the response
   is a changeset correction, not a relaxed `validate` or an exempt profile.

### Phase Dependencies

- **Setup (Phase 1)**: no dependencies — start immediately.
- **Foundational (Phase 2)**: depends on Phase 1 (the S0 gate cannot run until Liquibase
  actually executes). **Blocks all four stories.**
- **US1 (Phase 3)**: after Phase 2. No dependency on other stories.
- **US2 (Phase 4)**: after Phase 2. Independent of US1, US3, US4 in code; its baseline tests
  are what make the cutover safe, so it is the second P1 and part of the shippable increment.
- **US3 (Phase 5)**: after Phase 2. Independent — touches only order-service configuration.
- **US4 (Phase 6)**: after Phase 2, but its `validate` flips make US1's and US3's fresh-database
  tests meaningful, so completing it last gives the strongest end state. Note T030 changes the
  profile auth-service's existing suite runs under, so run T013 again after T030.
- **Polish (Phase 7)**: after all stories.

### Within Each User Story

- Guard implementation order in US2 is strict: T014/T015 (types) → T016 (implementation) →
  T017 (policy) → T018 (wiring) → T019 (registration) → T020–T024 (tests).
- Elsewhere, tests and implementation may be written in either order; the tests must pass
  against the implemented behavior before the phase checkpoint.

### Parallel Opportunities

- **Phase 2**: T005 and T007 run alongside T006.
- **Phase 3**: T009 and T010 (same new file — write together, not concurrently); T011 is a
  different module and genuinely parallel.
- **Phase 4**: T014 and T015 are separate files with no dependency on each other; T020 and T021
  are separate test files.
- **Phase 5**: T026 and T027 land in one new file — write together.
- **Phase 6**: T028–T033 are six distinct config files with no interdependency — fully parallel.
- **Phase 7**: T037, T038, T041, T042 are four distinct files.
- **Across stories**: once Phase 2 is done, US1, US2, US3 and US4 can be staffed in parallel —
  US2 is the only one with meaningful code volume.

---

## Parallel Example: Phase 6 (User Story 4)

```bash
# Six independent config files, one property each:
Task: "ddl-auto: validate in auth-service/src/main/resources/application.yaml"
Task: "ddl-auto: validate in auth-service/src/main/resources/application-local.yml"
Task: "ddl-auto: validate in auth-service/src/main/resources/application-test.yml"
Task: "Add ddl-auto: validate block to order-service/src/main/resources/application.yaml"
Task: "ddl-auto: validate in order-service/src/main/resources/application-local.yml"
Task: "ddl-auto: validate in order-service/src/main/resources/application-dev.yml"
```

## Parallel Example: Phase 4 (User Story 2)

```bash
# The two abstraction-level types, before the implementation that uses them:
Task: "Create SchemaMigrationProperties in infra-database/src/main/java/com/reuven/database/"
Task: "Create SchemaStateInspector in infra-database/src/main/java/com/reuven/database/"
```

---

## Implementation Strategy

### MVP (both P1 stories)

The MVP here is **US1 + US2 together**, not US1 alone. US1 without US2 activates Liquibase
against databases that already have their schema, which is precisely the failure US2 exists to
prevent — shipping it alone would break every existing environment on the next deploy.

1. Phase 1: Setup — Liquibase actually executes.
2. Phase 2: Foundational — changelogs corrected, `validate` parity proven.
3. Phase 3: US1 — changesets apply, are recorded, never re-run.
4. Phase 4: US2 — legacy databases refuse to start; reconciliation is safe and repeatable.
5. **STOP and VALIDATE**: quickstart S1–S7 against a copy of a real database.

### Incremental Delivery

1. Setup + Foundational → the mechanism is live and the scripts are correct.
2. US1 + US2 → shippable: any environment can be cut over safely (MVP).
3. US3 → order-service stops being silently skipped; SC-005 becomes satisfiable.
4. US4 → Hibernate demoted; drift becomes a startup failure instead of a silent patch.
5. Polish → concurrency and failure semantics proven, docs and runbook written.

### Rollout (after all phases are green)

Cutover is per-environment and manual, in this order, with a successful update-plus-validate
startup observed before moving on: **local → dev → staging → production**. Each environment
gets exactly one run with `--hydra.database.baseline.enabled=true`, and that flag is never
persisted into a profile or manifest.

---

## Notes

- `[P]` = different files, no dependencies.
- No service POM carries the Liquibase *runtime* dependency; both services inherit
  `spring-boot-starter-liquibase` through `infra-database` (Constitution Principle II).
  `order-service/pom.xml` did gain one test-scope addition during implementation
  (`org.testcontainers:postgresql`, matching what `auth-service` already had) — required by
  T006/T007/T021's Testcontainers Postgres harnesses; `infra-database/pom.xml` gained the same
  plus `spring-boot-testcontainers` and `testcontainers:junit-jupiter`, test-scope only, for its
  own guard test matrix (T020-T024, T037, T038). Neither is a production dependency.
- The working tree already carries T001's runtime-starter swap plus unrelated `DB_URL`
  overrides in both `application-local.yml` files — the latter are not part of this feature.
- Commit after each task or logical group; T004 deserves its own commit given rule 1 above.

**Post-completion amendment (after all 44 tasks above were done and verified)**: T012 and T025's
"pin `spring.liquibase.change-log` explicitly in both services" and the "no classpath resource
is moved" note above were both reversed. order-service's changelog was moved to Liquibase's
default path (`db/changelog/`, mirroring auth-service) and the explicit `change-log` line was
removed from *both* services' `application.yaml` — neither configures it at all now, per
"explicit configuration only when it changes behavior or documents a non-default contract."
This required reworking `AuthOrderCrossServiceIntegrationTest` to use `file:`-URL overrides
(computed from each application class's own classpath location, factored into the new shared
`OwnChangelogFileUrl` helper) instead of `classpath:` overrides, since both services now share
one relative changelog path and that test runs both real contexts in one JVM. The same override
was also needed in `EdgeConformanceFixture` — it starts only auth-service, but
`integration-tests` depends on order-service too, so order's identically-pathed changelog is
still on the classpath and Liquibase's own resource resolution (`getResources`, not
`getResource`) throws `ChangeLogParseException: Found 2 files with the path '...'` rather than
silently picking one, even when only one `SpringApplication` is actually running. Full
rationale, the verified Spring/Liquibase resource-loading chain, and why this is safe in
production: [research.md](./research.md) R2 (revised) and R10/D4.

Separately, this verification pass also surfaced and fixed a pre-existing, unrelated flaky test:
`ConcurrentMigrationTest` (T037) occasionally failed with `ConcurrentModificationException` from
Spring Boot's `LoggingApplicationListener` racing on a shared, JVM-wide Logback context when its
two `SpringApplication.run()` calls are released simultaneously — a known Boot limitation for
concurrent app bootstraps in one JVM, not a defect in the guard or in Liquibase's own locking
(what the test verifies). Fixed with a retry-once wrapper around the specific
`ConcurrentModificationException` case; the test's actual assertions are unchanged.

The task checkboxes above are left as the historical record of what was executed and verified at
the time; this note is the amendment.
