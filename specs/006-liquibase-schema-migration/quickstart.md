# Quickstart: Validating Liquibase Schema Migration Authority

**Date**: 2026-08-18 | **Spec**: [spec.md](./spec.md) |
**Contracts**: [startup](./contracts/startup-schema-contract.md) ·
[baseline](./contracts/baseline-operation-contract.md)

Runnable scenarios that prove the feature. Each maps to a user story and a success criterion.
Run them in order — S0 is a gate: if it fails, the rest of the plan is built on a false
assumption and the changelogs need correcting before anything else proceeds.

## Prerequisites

- Java 25 (`/usr/bin/java`, Corretto 25) and Docker running (Testcontainers).
- Maven via the wrapper distribution — `mvn` is not on `PATH` and there is no `./mvnw`:

```bash
~/.m2/wrapper/dists/apache-maven-3.9.16-bin/5grr65jo27hi51sujmtcldfovl/apache-maven-3.9.16/bin/mvn -q -pl auth-service,order-service -am compile -DskipTests
```

- Reactor order: `infra-shared` → `infra-database` → `rate-limit-starter` → `auth-service` →
  `order-service` → `integration-tests`.
- **Back up local H2 files before starting**: `~/data/auth_db.mv.db`, `~/data/orders_db.mv.db`.
  They are legacy databases under the new rules (research R9) and the first run after cutover
  will refuse to start until they are baselined or deleted.

---

## S0 — Parity gate: does `validate` accept a changelog-built schema?

*The one assumption that cannot be settled by reading (research R8).*

Start each service against a brand-new empty database with `ddl-auto: validate`, and confirm
the context comes up. Both engines matter: PostgreSQL (Testcontainers) and H2 in PostgreSQL
mode, because the local profile and the cross-service test both run H2.

**Expected**: context starts; `DATABASECHANGELOG` holds every changeset; no Hibernate DDL in
the log.

**If it fails**: the fix is to widen/correct the *changeset* (allowed only before any
environment has been baselined — see the baseline contract's ordering rule), never to relax
`validate` or exempt a profile.

---

## S1 — Fresh database, schema built entirely by the changelogs
*User Story 1 · SC-003 · FR-001*

Point a service at an empty database and start it.

**Expected**: every changeset applies in changelog order; the resulting tables match
[data-model.md](./data-model.md); no manual database step was needed; for order-service, the
run succeeds *because* `fk_orders_tenant` is gone — with it present, this scenario fails on a
missing `tenants` table (research R7/D1).

## S2 — Restart applies nothing
*User Story 1 · FR-002*

Restart the service from S1 unchanged.

**Expected**: zero changesets applied; `DATABASECHANGELOG` row count unchanged; startup
otherwise identical.

## S3 — A new changeset applies alone
*User Story 1 · FR-001*

Append a throwaway changeset to a changelog, restart, then revert it (revert only against a
disposable database — a synced checksum outlives the edit).

**Expected**: exactly one new row in `DATABASECHANGELOG`.

---

## S4 — Legacy database refuses to start
*User Story 2 · FR-005*

Build a schema the old way (`ddl-auto: update` against an empty database, with real rows
inserted), then start the service with the new configuration and **no** baseline flag.

**Expected**: startup fails before any DDL is issued; the message names the reconciliation
step (`hydra.database.baseline.enabled=true`); the schema and the rows are untouched.

## S5 — Reconciliation, then a working service
*User Story 2 · SC-002 · FR-004, FR-008*

Against the S4 database:

```bash
java -jar <service>.jar --hydra.database.baseline.enabled=true
```

**Expected**: every changeset recorded as applied without executing; a baseline tag on the last
row; the same startup then runs `validate` and succeeds; **every pre-existing row still present
and unchanged** (count and compare before/after).

## S6 — Reconciliation is repeat-safe
*Spec Edge Cases · FR-004*

Run S5 a second time, then start normally once more.

**Expected**: no new `DATABASECHANGELOG` rows, no error, service starts.

## S7 — Reconciling a schema that does *not* match
*Spec Edge Cases*

Take the S4 database, hand-drop a column the entities require, then reconcile.

**Expected**: the sync itself succeeds (it does not pre-verify), and the same startup's
`validate` fails loudly, naming the missing column. The environment is never left silently
believing it is current.

---

## S8 — Both services' changelogs actually execute
*User Story 3 · SC-005 · FR-003*

Run S1 for **order-service specifically** — the service whose master changelog sits outside the
default path.

**Expected**: its changesets appear in its own `DATABASECHANGELOG`. Then, as a negative check,
point `spring.liquibase.change-log` at a nonexistent path: startup must fail with Boot's
"no changelog could be found at '<path>'" — proving a lost changelog is loud, not silent.

---

## S9 — Drift is caught, not patched
*User Story 4 · SC-004 · FR-006*

Add a field to an entity (e.g. a new column on `Order`) with no accompanying changeset, and
start the service — **including under the `local` profile on a developer machine**.

**Expected**: startup fails with Hibernate's mismatch error; the database is unchanged; no
column is created. Removing the field restores a clean start. Running this under `local` is the
part that proves FR-006's "no environment is exempt".

## S10 — Concurrent instances serialize
*FR-007*

Start two instances of the same service simultaneously against one empty database.

**Expected**: one applies the changesets, the other waits on `DATABASECHANGELOGLOCK` and then
finds nothing to run; both start; no duplicated or conflicting object.

## S11 — A failing changeset leaves a clean, recoverable state
*FR-010*

Against PostgreSQL, add a changeset that is guaranteed to fail (e.g. a column on a nonexistent
table), and start.

**Expected**: startup fails; that changeset is absent from `DATABASECHANGELOG`; its own
statements rolled back; previously applied changesets untouched. Correcting the changeset and
restarting succeeds — recovery is forward-only. (On H2, DDL is not transactional; partial
objects may remain, which is why this scenario is asserted against PostgreSQL.)

---

## Cross-service regression

```bash
~/.m2/wrapper/dists/apache-maven-3.9.16-bin/5grr65jo27hi51sujmtcldfovl/apache-maven-3.9.16/bin/mvn -q -pl integration-tests -am test
```

`AuthOrderCrossServiceIntegrationTest` boots both services against throwaway in-memory H2
databases, so after this feature it doubles as proof that both changelogs run cleanly on H2 in
PostgreSQL mode. Its passing is a required part of "done".

## Coverage map

| Scenario | Story | Requirements | Success criteria |
|---|---|---|---|
| S0 | — | FR-006 | precondition for SC-003, SC-004 |
| S1, S2, S3 | US1 | FR-001, FR-002 | SC-003 |
| S4, S5, S6, S7 | US2 | FR-004, FR-005, FR-008 | SC-002 |
| S8 | US3 | FR-003 | SC-005 |
| S9 | US4 | FR-006, FR-009 | SC-001, SC-004 |
| S10, S11 | — | FR-007, FR-010 | SC-002 |
