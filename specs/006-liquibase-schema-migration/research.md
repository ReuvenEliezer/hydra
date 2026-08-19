# Phase 0 Research: Liquibase Schema Migration Authority

**Date**: 2026-08-18 | **Branch**: `006-fix-liquibase-conf` | **Spec**: [spec.md](./spec.md)

Per Constitution Principle V (Audit Before Building), every statement below was confirmed
against source, POMs, or the actual artifacts in `~/.m2` — not against README or prior docs.

## R1. Why the changelogs never run under Spring Boot 4

**Finding**: `infra-database/pom.xml` declares `org.liquibase:liquibase-core` (resolved to
5.0.3 by the Boot 4.1.0 BOM), and both services depend on `infra-database`. Liquibase is
therefore on the classpath but nothing ever calls it: in Spring Boot 4 the Liquibase
auto-configuration lives in its own module, `org.springframework.boot:spring-boot-liquibase`
(class `org.springframework.boot.liquibase.autoconfigure.LiquibaseAutoConfiguration`,
registered in that jar's `META-INF/spring/org.springframework.boot.autoconfigure.AutoConfiguration.imports`).
Boot 4 split the monolithic `spring-boot-autoconfigure` into per-technology modules, so
`liquibase-core` alone no longer activates anything.

**Decision**: In `infra-database`, replace the raw `liquibase-core` dependency with the two
Boot-managed starters (both versionless — the BOM pins 4.1.0):

```xml
<!-- Liquibase runtime -->
<dependency>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-starter-liquibase</artifactId>
</dependency>

<!-- Liquibase test support -->
<dependency>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-starter-liquibase-test</artifactId>
    <scope>test</scope>
</dependency>
```

Contents verified from the resolved POMs, not assumed:
- `spring-boot-starter-liquibase` → `spring-boot-starter`, `spring-boot-starter-jdbc`,
  `spring-boot-jdbc`, `spring-boot-liquibase` (which brings `liquibase-core` 5.0.3, the
  `LiquibaseChangelogMissingFailureAnalyzer`, the Testcontainers/Docker-Compose connection-details
  factories, and the `AutoConfigureDataSourceInitialization` import that pulls Liquibase into
  `@DataJpaTest` / `@JdbcTest` slices).
- `spring-boot-starter-liquibase-test` → `spring-boot-starter-liquibase`,
  `spring-boot-starter-test`, `spring-boot-starter-jdbc-test`.

Both services inherit the runtime starter through `infra-database`, so no service POM changes.
The test starter is `infra-database`-only: it is what the guard's own test matrix (R5) runs on.
This mirrors the module's existing `spring-boot-starter-data-jpa-test` test-scoped dependency,
which is the same Boot 4 per-technology test-support convention.

**Rationale**: Both dependencies sit in the module that already owns persistence concerns
(Principle II). The starters are the supported entry points and keep the transitive set
(including the `jaxb-api` exclusion Boot applies) correct; declaring `liquibase-core` directly
is what produced a classpath that looked wired and did nothing.

**Alternatives considered**:
- `spring-boot-liquibase` without the starter — works, but the starter is the documented
  contract and adds nothing unwanted here.
- Adding the dependency to each service POM — duplicates a shared infra concern in two
  places and contradicts Principle II.

## R2. Where the changelog is looked up, and why order-service was invisible

**Finding**: `LiquibaseProperties.changeLog` defaults to
`classpath:/db/changelog/db.changelog-master.yaml`.
- auth-service already sat at that exact path
  (`auth-service/src/main/resources/db/changelog/db.changelog-master.yaml`, including
  `changes/001-init-auth-schema.yaml` and `changes/002-tenant-url-identifier.yaml`).
- order-service's master was at `order-service/src/main/resources/changes/db.changelog-master.yaml`
  — not the default path.

**Original decision (superseded — see below)**: Set `spring.liquibase.change-log` explicitly in
both services' `application.yaml`, order-service pointing at its non-default `changes/` location,
rather than moving the files.

**Revised decision**: order-service's changelog was moved to the default location
(`order-service/src/main/resources/db/changelog/db.changelog-master.yaml`, changeset at
`db/changelog/changes/001-init-order-schema.yaml`, `include:` updated to match), and the
`spring.liquibase.change-log` line was removed from **both** services' `application.yaml`.
Neither service configures Liquibase's changelog location at all now — both rely purely on
Boot's default. FR-003 ("discovered regardless of the default location") is satisfied by the
mechanism working with zero configuration, not by naming a path explicitly.

**Rationale for the reversal**: explicit configuration is only warranted when it changes
behavior or documents a genuinely non-default contract (project convention). Once order-service
sits at the default path, an explicit `change-log` line for either service is pure boilerplate —
it states the value Boot already assumes, with no behavioral effect. Removing it is a net
reduction in configuration surface with zero functional change to either service. The earlier
"leave the files where they are" alternative rejected the resource move on Principle III grounds
(load-path-authoritative paths) without weighing it against the cost of two redundant config
lines; the move is small (two files, one `include:` path) and the resulting uniformity is worth
more than avoiding the move. See R10/D4 below for the one place this move had a real
consequence — the cross-service test — and how that was resolved without reintroducing explicit
production config.

## R3. Pre-update guard hook (FR-005)

**Finding**: `LiquibaseAutoConfiguration`'s `SpringLiquibaseCustomizer` is package-private, so
it cannot be implemented from `infra-database`. However, Boot's `CustomizerConfiguration`
picks up any application bean of type `liquibase.integration.spring.Customizer<Liquibase>` and
sets it on the `SpringLiquibase`. Bytecode inspection of `liquibase-core` 5.0.3 confirms
`SpringLiquibase.createLiquibase(Connection)` invokes `customizer.customize(liquibase)` as its
last action before returning, i.e. **after** the `Liquibase` object (database + resource
accessor) is fully built and **before** `performUpdate` runs a single statement.

**Decision**: Implement the FR-005 guard as a `Customizer<Liquibase>` bean contributed by
`infra-database`'s own auto-configuration. It receives the live `Liquibase`/`Database` and can
inspect state and abort by throwing, before any changeset executes.

**Rationale**: Public API only; no duplication of Boot's ~25 lines of property wiring; a
single small bean rather than a parallel `SpringLiquibase` definition. Boot's bean backs off
on `@ConditionalOnMissingBean(SpringLiquibase.class)`, so any custom `SpringLiquibase`
subclass would force us to re-bind every `spring.liquibase.*` property by hand and re-audit it
on each Boot upgrade.

**Alternatives considered**:
- `BeanPostProcessor` on the `SpringLiquibase` bean — also runs before `afterPropertiesSet`,
  but only gives us the DataSource; the baseline step (R4) would then have to construct its
  own `ResourceAccessor`, and `SpringResourceAccessor` is package-private in Liquibase.
- A `preConditions` block at the top of each master changelog — runs *inside* the update,
  after `DATABASECHANGELOG`/`DATABASECHANGELOGLOCK` are created, which muddies the very state
  the guard tests. FR-005 also forbids pushing guards into the scripts.

## R4. The reconciliation action (FR-004, FR-008)

**Finding**: `Liquibase.changeLogSync(Contexts, LabelExpression)` and `Liquibase.tag(String)`
are public API in 5.0.3. `ChangeLogSyncVisitor` marks synced changesets with
`ChangeSet.ExecType.EXECUTED` — **identical** to a genuinely executed changeset, so `EXECTYPE`
alone cannot prove a row came from reconciliation.

**Decision**: Reconciliation is an in-service one-shot mode, not a separate artifact: starting
the service with `hydra.database.baseline.enabled=true` makes the guard call `changeLogSync`
and then `tag(...)` with a baseline tag (default `baseline-<UTC instant>`, overridable via
`hydra.database.baseline.tag`), log at WARN, and let the normal update proceed as a no-op. The
tag row plus `DATEEXECUTED`/`DEPLOYMENT_ID` in `DATABASECHANGELOG` is the audit record: which
database it ran against, and when. Running it again against a database that already has
history is a logged no-op.

**Rationale**: Reuses the service's own datasource configuration, so the reconciliation can
never drift from the connection settings the app actually uses, and it runs anywhere the
service image runs — no Maven, no repo checkout, no second copy of the changelog. FR-007's
"no new deployment artifact" is honored: it is the same artifact with a flag.

Because the mode runs inside a normal startup, Hibernate's `validate` executes moments later
in the *same* boot rather than on the next one. This is stricter than the clarification's
"verify at the next startup" and satisfies its intent (a mismatch fails loudly and
immediately); the operator does not have to remember to restart to learn the truth.

**Alternatives considered**:
- `liquibase-maven-plugin:changelogSync` (BOM-managed at 5.0.3) — zero custom code, but
  requires Maven, the repo, and a second declaration of URL/credentials/changelog path per
  environment. That duplication is exactly the drift this feature exists to remove, and
  deployed environments run containers, not Maven.
- Liquibase CLI Docker image — same duplication, plus mounting the changelog out of the jar.
- A dedicated `EXECTYPE`-based audit — not possible, per the `ChangeLogSyncVisitor` finding.

## R5. Detecting "legacy schema, no migration history" (FR-005)

**Decision**: Before any changeset runs, the guard asks two questions through JDBC metadata on
the Liquibase connection:
1. Does `DATABASECHANGELOG` exist and hold at least one row?
2. Does the schema contain any application table other than `DATABASECHANGELOG` /
   `DATABASECHANGELOGLOCK`?

Outcomes: no tables + no history → normal update (fresh environment). Tables + no history →
refuse to start with the "reconciliation required" message naming
`hydra.database.baseline.enabled=true`, unless that flag is set, in which case reconcile.
History present → normal update, flag ignored with a log line.

**Rationale**: An existing-but-empty `DATABASECHANGELOG` (created by an aborted first attempt)
must count as "no history", which is why the check is row-count based rather than
table-existence based. Keeping the guard generic — "any non-Liquibase table" — avoids a
hardcoded table list per service that would rot as the schema grows.

## R6. Concurrency and failure semantics (FR-007, FR-010)

**Finding**: Liquibase acquires `DATABASECHANGELOGLOCK` server-side before applying changes,
so N instances starting together serialize naturally; the losers wait and then find nothing to
run. No application-level read-modify-write is involved, which is the same property Principle
IV demands of shared-state mutations.

**Finding**: PostgreSQL has transactional DDL, so a changeset that fails partway is rolled
back by the database and is never recorded in `DATABASECHANGELOG`; the exception propagates
out of `SpringLiquibase.afterPropertiesSet()` and the context fails to start. H2 does not roll
back DDL, so a failed changeset can leave partial objects behind on a local file database —
acceptable, since local databases are disposable. Liquibase never auto-rolls-back previously
applied changesets. This matches FR-010 with no extra code.

## R7. Two defects found during the audit (not visible from the spec)

**D1 — order-service's changelog cannot run on a fresh database.**
`order-service/src/main/resources/changes/001-init-order-schema.yaml` declares
`addForeignKeyConstraint fk_orders_tenant` from `orders.tenant_id` to `tenants.id`. There is
no `tenants` table in order-service's database: auth-service uses `auth_db` / `~/data/auth_db`
and order-service uses `orders_db` / `~/data/orders_db` in every profile, and order-service has
no `Tenant` entity — `tenantId` is a plain `UUID` column derived from the JWT claim. The
constraint has never existed in any live schema, because Hibernate never created it. Left
as-is, the first fresh-database startup fails (SC-003) and every reconciled environment gets a
false record saying it was applied.

**Decision**: Delete that `addForeignKeyConstraint` block from `001-init-order-schema.yaml`
**before** any environment is reconciled. Editing is safe *only* until the first sync: no
database anywhere has ever recorded a checksum for these changesets, so no `validCheckSum`
handling is needed. After the first environment is baselined, the same edit would require a
new changeset instead. This ordering constraint is a hard sequencing rule for the task list.

**D2 — order-service has no `ddl-auto` at all in `application.yaml`.**
Only `application-local.yml` and `application-dev.yml` set it (`update`). With no property and
an embedded H2 datasource, Boot's default is `create-drop`. Adding Liquibase changes that
default on its own (`LiquibaseSchemaManagementProvider` makes Boot's Hibernate default `none`
when a schema management tool is present), but FR-006 wants the end state stated, not
inferred. `spring.jpa.hibernate.ddl-auto: validate` must be set explicitly in
order-service's `application.yaml` too.

## R8. Hibernate `validate` parity with the changelog-produced schema

**Finding**: Comparing every entity mapping against the changelogs, the only differences are
column *lengths* and *nullability*, never presence or type:

| Column | Changelog | Entity mapping |
|---|---|---|
| `tenants.status`, `users.status` | `varchar(30)` | enum, no explicit length (255) |
| `orders.status` | `varchar(20)` | enum, no explicit length (255) |
| `orders.order_number` | `varchar(50)` | no explicit length (255) |
| `orders.updated_at` | nullable | `nullable = false` |
| `orders.version` | `bigint` nullable, default 0 | `@Version Long` |

Hibernate's schema validator compares table/column presence and JDBC type, not declared
length or nullability, so these are expected to pass. **This is the one assumption in the plan
that must be proven by running, not by reading** — it is the single point where "cutover looks
fine" could turn into "every service fails to start". Phase 1's quickstart makes it the first
gate: boot each service against an empty database with `validate` on, and treat a failure as a
changelog correction (widen the column in the changeset, pre-sync only) rather than a reason
to loosen `validate`.

**Consequence to accept**: legacy environments keep the `varchar(255)` columns Hibernate made;
fresh environments get the narrower changelog widths. Both validate. Normalizing them is a
later changeset, deliberately out of scope here.

**S0 outcome (tasks.md T006–T008, run 2026-08-19)**: proven by running, not just reading. Both
services were booted with `spring.jpa.hibernate.ddl-auto=validate` against a brand-new empty
database, on both engines that matter:

- auth-service on Testcontainers PostgreSQL (`postgres:16-alpine`) — context started, all 3
  changesets applied and recorded in `DATABASECHANGELOG`, no Hibernate DDL.
- auth-service on H2 in PostgreSQL mode (`jdbc:h2:mem:...;MODE=PostgreSQL;DATABASE_TO_LOWER=TRUE`)
  — same result.
- order-service on Testcontainers PostgreSQL — context started, its 1 changeset applied and
  recorded, no Hibernate DDL. (Required adding the `org.testcontainers:postgresql` test-scope
  dependency to `order-service/pom.xml`, which auth-service already had; order-service had no
  Postgres Testcontainers module at all.)
- order-service on H2 in PostgreSQL mode — same result.

All four combinations passed on the first run. No column width or nullability correction was
needed to any changeset — the assumption in the table above held exactly as predicted. The
throwaway harnesses live at `S0ParityGatePostgresTest`/`S0ParityGateH2Test` in both services'
test trees and are deleted once Phases 3–7 land their permanent replacements (tasks.md T039).

## R9. Local development databases are "legacy", not fresh

**Finding**: `application-local.yml` in both services points at file-backed H2
(`~/data/auth_db`, `~/data/orders_db`) with schema built by `ddl-auto: update`. Under the new
rules these are exactly the FR-005 case, so every developer's next run refuses to start until
they either baseline once or delete the H2 files. This is intended (the clarification session
ruled that no environment is exempt) but it is a breaking change for anyone with a seeded local
tenant, so the rollout docs must say it plainly.

**Finding**: `AuthOrderCrossServiceIntegrationTest` overrides both datasources to throwaway
in-memory H2 via command-line args, so it is a fresh-database case and will exercise the
changelogs on H2 in PostgreSQL mode — which makes it a genuine test that the changelogs are
portable across both engines.

## R10. Two defects found during implementation verification (T035/T040)

**D3 — a JPA entity in a test package leaked into the real application's entity scan.**
The first version of the US4 drift test (T035/T036) put its throwaway `DriftWidget` entity
under `com.reuven.orderservice.drift` — a subpackage of `com.reuven.orderservice`, the package
`OrderServiceApplication`'s default component/entity scan covers recursively. That leaked
`DriftWidget` into the REAL application's entity set, and order-service's own pre-existing
tests (`OrderServiceApplicationTests`, `OrderApiIntegrationTest`) started failing Hibernate
`validate` with "missing table [drift_widgets]" — a regression this feature must not cause.
Fixed by moving the fixture entirely outside `com.reuven.orderservice`, into its own top-level
`com.reuven.schemadrift` package, so no real application ever scans it.

**D4 — a classpath collision between the two services' identically-named `application.yaml`,
made load-bearing by this feature.** `auth-service` and `order-service` each ship an
`application.yaml` at their classpath root. `AuthOrderCrossServiceIntegrationTest` runs both
real Spring Boot applications in one JVM (`integration-tests` depends on both modules), so both
files sit on the same classpath. Spring's config-data loading resolves a single winner across
that merged classpath for any key both files define, determined by classpath order — not by
which `SpringApplication.class` is running. Before this feature this was silently harmless: the
only genuinely colliding, consequential key was `ddl-auto`, and both services happened to say
`update`. Once `spring.liquibase.change-log` became a load-bearing key, the collision became
real: order-service's `SpringApplication` silently received auth-service's changelog path, so
order-service tried to run auth's changesets against its own database and its later Hibernate
`validate` failed with "missing table [orders]" — the schema it actually needed was never built.

**Root-caused (verified against bytecode, not assumed)**: `SpringLiquibase implements
ResourceLoaderAware`, so each `SpringApplication.run()` call correctly injects its OWN
`ApplicationContext` as the resource loader for that context's Liquibase bean —
`LiquibaseConfiguration.liquibase(...)` passes the property value through verbatim, with no
prefix validation, and `SpringLiquibase.createResourceOpener()` wraps it in a
`SpringResourceAccessor` that resolves locations via
`ResourcePatternUtils.getResourcePatternResolver(resourceLoader).getResources(location)` —
Spring's ordinary `Resource` abstraction, but note the **plural** `getResources`: even a bare,
non-wildcard `classpath:` location is resolved as a pattern search across the *whole* merged
classpath, not a single lookup. **This confirmed the collision is structurally impossible in
production**: real deployments run each service in its own JVM/container with its own
classloader, so that search only ever has one candidate to find there — the ambiguity exists
only where a test deliberately puts two services' output directories on one classpath.

**Decision — superseded once more, after order-service moved to the default changelog path
(R2 revised)**: with both services now at the identical default path
(`db/changelog/db.changelog-master.yaml`), that classpath search for either context now finds
**two** physical files, and Liquibase does not silently pick one — it fails loudly:
`ChangeLogParseException: ... Found 2 files with the path
'classpath:/db/changelog/db.changelog-master.yaml': ... You can limit the search path ... or,
if you KNOW these are the exact same file, set liquibase.duplicateFileMode=WARN` (message
observed verbatim running the suite, not assumed from reading bytecode alone). Two consequences
followed from this, both fixed by overriding `spring.liquibase.change-log` to a `file:` URL
instead of relying on `classpath:` at all — computed per service via
`ApplicationClass.getProtectionDomain().getCodeSource().getLocation()` (that class's own
`target/classes` directory), factored into a small shared `OwnChangelogFileUrl` helper. `file:`
resolution in `DefaultResourceLoader` builds a filesystem `Resource` directly and never touches
classloader/classpath scanning at all, so it is immune to the duplicate-match search by
construction, not by classpath ordering luck:

1. `AuthOrderCrossServiceIntegrationTest` — starts both services in one JVM; needed the override
   for both `authApp.run(...)` and `orderApp.run(...)`.
2. `EdgeConformanceFixture` — starts **only** auth-service, yet failed the same way. The
   duplicate-file search scans the whole classpath regardless of which `SpringApplication` asked
   for it, and `integration-tests` depends on order-service too (for
   `AuthOrderCrossServiceIntegrationTest`'s own imports), so order's identically-pathed
   changelog is on the classpath even for a fixture that never touches order-service. Any test
   in this module that boots a Liquibase-enabled context needs this override, not just the ones
   that intentionally colocate two services.

This keeps both services' production `application.yaml` fully default (no Liquibase config at
all) while making every test in this module that boots a real context deterministic, consistent
with the existing pattern of overriding exactly the properties this kind of in-JVM colocation
makes ambiguous (see the file's own comments on `DB_URL` and `AUTH_SERVICE_URL`).

**Consequence to note**: the underlying classpath collision is structural and applies to any
key both `application.yaml` files define identically — e.g. `hydra.cors.*`,
`hydra.tenant.base-domains`. For those (ordinary Spring config-data merging, not Liquibase's
stricter duplicate-file search) Spring picks a single winner *silently* rather than erroring,
so they are currently harmless only because both services' `local`-profile values happen to
match — coincidence, not a guarantee. Out of scope here; recorded so a future change to either
`application.yaml` doesn't reintroduce a silent miswiring in this module's tests by surprise.

## Resolved unknowns

No `NEEDS CLARIFICATION` items remain. Spec clarifications from 2026-08-18 covered failure
semantics, guard placement, per-instance application, verification timing, and local-dev
parity; R1–R9 close the technical side.
