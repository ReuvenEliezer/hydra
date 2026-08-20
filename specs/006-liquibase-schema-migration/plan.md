# Implementation Plan: Liquibase Schema Migration Authority

**Branch**: `006-fix-liquibase-conf` | **Date**: 2026-08-18 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/006-liquibase-schema-migration/spec.md`

## Summary

Liquibase is on the classpath of both services and has never executed a single statement:
Spring Boot 4 moved Liquibase auto-configuration into its own module
(`spring-boot-liquibase`), which was never added, so `spring.jpa.hibernate.ddl-auto: update`
has been the real schema authority all along. This feature activates the changelogs, hands
them the authority, and demotes Hibernate to `validate`.

Technical approach, in four moves:

1. **Activate** — in `infra-database`, replace `liquibase-core` with
   `spring-boot-starter-liquibase` (runtime) plus `spring-boot-starter-liquibase-test`
   (test scope, for the module's own guard tests); both services inherit the runtime starter.
2. **Discover** — order-service's changelog is relocated to Liquibase's default
   classpath location, mirroring auth-service, so it is found with zero configuration
   (FR-003; see the implementation note under Project Structure below).
3. **Reconcile** — `infra-database` contributes a `Customizer<Liquibase>` guard that runs
   before any changeset: a database with tables but no migration history refuses to start and
   names the fix; with `hydra.database.baseline.enabled=true` it instead runs `changeLogSync`,
   tags the baseline, and lets startup continue.
4. **Demote** — `ddl-auto: validate` in every profile of both services, plus removal of the
   `fk_orders_tenant` constraint that would make order-service's changelog fail on any fresh
   database.

Point 4's second half is a defect the audit turned up, not something the spec anticipated —
see [research.md](./research.md) R7. It must land before any environment is reconciled.

## Technical Context

**Language/Version**: Java 25 (Corretto)

**Primary Dependencies**: Spring Boot 4.1.0, `spring-boot-starter-liquibase` (Liquibase 5.0.3),
Spring Data JPA / Hibernate, Lombok

**Storage**: PostgreSQL 16 (dev/staging/prod, one database per service: `auth_db`, `orders_db`);
file-backed H2 in PostgreSQL mode for the `local` profile (`~/data/auth_db`, `~/data/orders_db`);
in-memory H2 for the cross-service test

**Testing**: JUnit 5, Testcontainers 1.21.4 (`PostgreSQLContainer`, `RedisContainer`), AssertJ,
`spring-boot-starter-liquibase-test` (test scope in `infra-database`; brings
`spring-boot-starter-test` + `spring-boot-starter-jdbc-test` alongside the runtime starter);
real infrastructure rather than mocks, per constitution

**Target Platform**: Linux/macOS JVM services, multi-instance, started from the same artifact
in every environment

**Project Type**: Maven multi-module backend (shared infra modules + two Spring Boot services)

**Performance Goals**: No measurable startup cost once a database is current — Liquibase's
no-op path is a single lock acquisition plus one `DATABASECHANGELOG` read (spec US1 scenario 2)

**Constraints**: Zero data loss and zero unplanned downtime during cutover (SC-002); no new
deployment artifact (FR-007); identical behavior in every environment including local (FR-006);
migrations applied by service instances themselves, serialized across instances

**Scale/Scope**: 2 services, 5 tables total, 3 existing changesets plus 1 correction, 5 config
files carrying `ddl-auto`, 3 deployed environments plus every developer's local database

## Constitution Check

*GATE: checked before Phase 0 and re-checked after Phase 1 design.*

| Principle | Assessment | Verdict |
|---|---|---|
| **I. Framework-Free Shared Core** | `infra-shared` is not touched. The guard, the Liquibase dependency, and all auto-configuration go into `infra-database`, which already depends on Spring Data JPA. | PASS |
| **II. Dedicated Modules for Cross-Cutting Concerns** | Schema management is owned end-to-end by `infra-database`, which gains its first `src/main/java` and its own `META-INF/spring/org.springframework.boot.autoconfigure.AutoConfiguration.imports`. Guard policy is expressed against a small `SchemaStateInspector` abstraction, with the Liquibase-backed implementation behind it, so the mechanism can be swapped without touching the policy. Neither service POM changes. | PASS |
| **III. Load-Path-Authoritative Paths** | Changelog locations are classpath contracts. order-service's changelog was relocated to Liquibase's default path (mirroring auth-service) rather than pinned via explicit config; every load site — the `include:` path inside the master, both services' `application.yaml`, and the two test fixtures that boot real contexts (`AuthOrderCrossServiceIntegrationTest`, `EdgeConformanceFixture`) — was updated in the same change, per the principle's requirement. A wrong path fails startup loudly (Boot's `LiquibaseChangelogMissingFailureAnalyzer`). | PASS |
| **IV. Atomic Distributed State Mutations** | The analogous concern here is concurrent migration across instances. It is handled server-side by `DATABASECHANGELOGLOCK` — no application-level read-modify-write, matching the principle's intent. No Redis state is involved. | PASS |
| **V. Audit Before Building** | The plan is built on a source audit, not on README claims: the missing Boot 4 module, the package-private `SpringLiquibaseCustomizer`, the `Customizer<Liquibase>` hook point, `ChangeLogSyncVisitor` writing `EXECTYPE=EXECUTED`, order-service's impossible foreign key, and its missing `ddl-auto` default. All recorded in research.md with the evidence. | PASS |

**Post-Phase-1 re-check**: no gate changed. The design adds one module's worth of code to an
existing dedicated module, introduces no framework dependency into `infra-shared`, moves no
classpath resource, and adds no non-atomic shared-state mutation. Complexity Tracking stays
empty.

## Project Structure

### Documentation (this feature)

```text
specs/006-liquibase-schema-migration/
├── plan.md                                 # This file
├── spec.md
├── research.md                             # Phase 0 output
├── data-model.md                           # Phase 1 output
├── quickstart.md                           # Phase 1 output
├── contracts/                              # Phase 1 output
│   ├── startup-schema-contract.md
│   └── baseline-operation-contract.md
├── checklists/
│   └── requirements.md
└── tasks.md                                # Phase 2 (/speckit-tasks — not created here)
```

### Source Code (repository root)

```text
infra-database/                             # owns the mechanism (Principle II)
├── pom.xml                                 # liquibase-core → spring-boot-starter-liquibase (+ -test, test scope)
└── src/
    ├── main/
    │   ├── java/com/reuven/database/
    │   │   ├── SchemaMigrationProperties.java      # hydra.database.baseline.*
    │   │   ├── SchemaStateInspector.java           # abstraction: history? tables?
    │   │   ├── LiquibaseSchemaStateInspector.java  # JDBC-metadata implementation
    │   │   ├── SchemaMigrationGuard.java           # Customizer<Liquibase>: guard + baseline
    │   │   └── SchemaMigrationAutoConfiguration.java
    │   └── resources/META-INF/spring/
    │       └── org.springframework.boot.autoconfigure.AutoConfiguration.imports
    └── test/java/com/reuven/database/       # guard matrix on H2 + Testcontainers Postgres

auth-service/src/main/resources/
├── application.yaml                        # ddl-auto: validate (no liquibase.change-log — default path)
├── application-local.yml                   # ddl-auto: validate
├── application-test.yml                    # ddl-auto: validate
└── db/changelog/                           # unchanged, already at the default path
    ├── db.changelog-master.yaml
    └── changes/{001-init-auth-schema,002-tenant-url-identifier}.yaml

order-service/src/main/resources/
├── application.yaml                        # + ddl-auto: validate (absent today; no liquibase.change-log — default path)
├── application-local.yml                   # ddl-auto: validate
├── application-dev.yml                     # ddl-auto: validate
└── db/changelog/                           # moved here from changes/ to match the default path
    ├── db.changelog-master.yaml
    └── changes/001-init-order-schema.yaml  # remove fk_orders_tenant (research R7/D1)

integration-tests/                          # cross-service regression, now exercising both changelogs on H2
```

> **Implementation note (post-plan revision)**: order-service's changelog was moved to
> `db/changelog/` (Liquibase's default path, mirroring auth-service) rather than staying at
> `changes/` with an explicit `spring.liquibase.change-log` override. Neither service's
> `application.yaml` sets that property at all in the final implementation — both rely purely on
> the Boot default, per the "explicit config only when it changes behavior" principle. See
> [research.md](./research.md) R2 (revised) and R10/D4 for the full rationale and the one
> consequence this had for `AuthOrderCrossServiceIntegrationTest`.

**Structure Decision**: The existing multi-module layout is kept as-is. `infra-database` is the
natural and constitutionally required home for this concern — it already exists as the
persistence module, already carries the Liquibase dependency, and gains the auto-configuration
that makes it a real module rather than a dependency aggregator. Service changes are limited to
configuration plus one changelog correction; neither service POM is touched.

## Phase 0 — Research

Complete: [research.md](./research.md). Nine findings (R1–R9), all verified against source or
the resolved artifacts, covering the missing Boot 4 module, changelog discovery, the pre-update
hook point, the reconciliation mechanism and its audit trail, guard detection logic, concurrency
and failure semantics, two newly discovered defects, `validate` parity risk, and the local-dev
impact. No `NEEDS CLARIFICATION` items remain.

## Phase 1 — Design & Contracts

Complete:
- [data-model.md](./data-model.md) — bookkeeping entities, configuration model, the guard's
  decision matrix, and the schema the changelogs describe.
- [contracts/startup-schema-contract.md](./contracts/startup-schema-contract.md) — the fixed
  startup sequence, eight guarantees mapped to requirements, and the failure contract.
- [contracts/baseline-operation-contract.md](./contracts/baseline-operation-contract.md) — the
  one-time reconciliation operation, its post-conditions, audit answers, and the rollout
  ordering rule.
- [quickstart.md](./quickstart.md) — twelve runnable validation scenarios (S0–S11) mapped to
  stories, requirements, and success criteria.

### Design decisions worth carrying into tasks

1. **The guard is a `Customizer<Liquibase>` bean.** Boot 4.1's `LiquibaseAutoConfiguration`
   picks up any such bean and `SpringLiquibase.createLiquibase` invokes it after the `Liquibase`
   object is built and before `performUpdate` — the exact "before any script runs" point FR-005
   asks for, using public API only, with no duplication of Boot's property wiring.
2. **Reconciliation is a flag on the same artifact**, not a second deliverable
   (`--hydra.database.baseline.enabled=true`), so it can never drift from the connection config
   the service actually uses.
3. **`EXECTYPE` cannot mark a reconciliation** — Liquibase writes `EXECUTED` for synced rows —
   so the audit trail is a baseline `TAG` plus `DATEEXECUTED`/`DEPLOYMENT_ID`.
4. **Verification happens in the same startup as the baseline**, one boot earlier than the
   clarification's "next startup", and strictly stronger: an operator cannot walk away from a
   reconciled-but-wrong environment without seeing the failure.
5. **Sequencing rule**: all changelog corrections land before the first environment is
   reconciled anywhere. After a sync, a changeset's checksum is recorded and editing it breaks
   every later startup.
6. **S0 is a gate, not a test.** Whether Hibernate `validate` accepts a changelog-built schema
   whose columns are narrower than the entity defaults is the one unproven assumption; it is
   settled by running, before the rest of the cutover is built on it.

## Complexity Tracking

No constitution violations. Table intentionally empty.
