# Phase 1 Data Model: Liquibase Schema Migration Authority

**Date**: 2026-08-18 | **Spec**: [spec.md](./spec.md) | **Research**: [research.md](./research.md)

This feature adds no business entity. It introduces bookkeeping state (owned by Liquibase),
one configuration object, and one runtime decision model. The application schema itself is
unchanged by this feature — it only changes *who is allowed to change it*.

## 1. Bookkeeping entities (created and owned by Liquibase, per database)

### DATABASECHANGELOG

One row per applied changeset. Created automatically on first run.

| Column | Meaning for this feature |
|---|---|
| `ID`, `AUTHOR`, `FILENAME` | Composite identity of a changeset — what makes "applied at most once" enforceable |
| `DATEEXECUTED` | When it was applied *or reconciled* — half of the FR-008 audit trail |
| `ORDEREXECUTED` | Application order within a database |
| `EXECTYPE` | `EXECUTED` for both real execution and reconciliation (see research R4) — not a reconciliation marker |
| `MD5SUM` | Checksum captured at apply/sync time; a later edit to an applied changeset fails validation |
| `TAG` | Carries the baseline tag written by the reconciliation action — the other half of the audit trail |
| `DEPLOYMENT_ID` | Groups everything applied in one run |

**Rules**
- Rows are never written by application code, only by Liquibase.
- A changeset already present here MUST NOT run again (FR-002).
- Zero rows (whether or not the table exists) means "no migration history" for guard purposes (FR-005).
- Each service has its own database and therefore its own, independent table (spec Edge Cases).

### DATABASECHANGELOGLOCK

Single-row advisory lock table. Liquibase acquires it before applying anything and releases it
after, which is what makes FR-007's "only one instance applies, the others wait" true without
any application-level coordination.

### Reconciliation baseline (not a table)

The spec's "reconciliation baseline" entity is realized as **state, not storage**: the set of
`DATABASECHANGELOG` rows written by one `changeLogSync` run, identified by their shared
`DEPLOYMENT_ID` and by the baseline `TAG` written immediately afterwards.

| Attribute | Realization |
|---|---|
| Which environment | The database the rows live in |
| When | `DATEEXECUTED` on those rows |
| Which scripts were baselined | The rows themselves |
| Distinguishable from real execution | The baseline `TAG` (default `baseline-<UTC instant>`) |

## 2. Configuration model (`infra-database`)

| Property | Type | Default | Purpose |
|---|---|---|---|
| `hydra.database.baseline.enabled` | boolean | `false` | Turns this startup into the one-time reconciliation run (FR-004) |
| `hydra.database.baseline.tag` | string | `baseline-<UTC instant>` | Tag written to `DATABASECHANGELOG` after sync (FR-008) |

Existing Spring properties this feature starts relying on:

| Property | auth-service | order-service |
|---|---|---|
| `spring.liquibase.change-log` | Boot default (`classpath:/db/changelog/db.changelog-master.yaml`) — not set in either service's `application.yaml` (research R2 revised) | same default |
| `spring.jpa.hibernate.ddl-auto` | `validate` (all profiles) | `validate` (all profiles) |

## 3. Runtime decision model (the FR-005 guard)

Two observations, taken before any changeset runs:

- **H** = `DATABASECHANGELOG` exists **and** has ≥ 1 row.
- **T** = the schema contains ≥ 1 table that is not `DATABASECHANGELOG` / `DATABASECHANGELOGLOCK`.

| H | T | `baseline.enabled` | Outcome |
|---|---|---|---|
| false | false | false | Fresh environment → normal update applies every changeset (FR-001) |
| false | false | true | Nothing to reconcile → log, skip sync, normal update |
| false | true | false | **Refuse to start**: "reconciliation required" naming the flag (FR-005) |
| false | true | true | `changeLogSync` + `tag`, then normal update (a no-op), then Hibernate `validate` in the same startup (FR-004) |
| true | any | false | Normal update: only not-yet-applied changesets run (FR-001, FR-002) |
| true | any | true | Already has history → log the no-op, normal update (repeat-safe, spec Edge Cases) |

State transitions of a database under this model:

```
  legacy (T, no H) --[baseline run]--> managed (H)
  empty (no T, no H) --[first startup]--> managed (H)
  managed (H) --[new changeset added]--> managed (H, +1 row)
  managed (H) --[changeset fails]--> managed (H, unchanged) + startup failure
```

There is no transition back out of `managed`, and no automatic transition out of `legacy` —
that edge is exactly the human decision FR-004 requires.

## 4. Application schema described by the changelogs

Unchanged by this feature; listed so the parity check in
[quickstart.md](./quickstart.md) has a reference. Divergences from the Hibernate-built legacy
schema are noted — all are length/nullability only (research R8).

**auth-service** (`db/changelog/`)
- `tenants` — `id uuid PK`, `name varchar(100)`, `status varchar(30)`†, `created_at timestamp`,
  `url_identifier varchar(63) NOT NULL UNIQUE` (uk_tenants_url_identifier)
- `users` — `id uuid PK`, `tenant_id uuid → tenants.id` (fk_users_tenant), `username varchar(50)`,
  `password_hash varchar(255)`, `status varchar(30)`†, unique (`tenant_id`,`username`)
- `user_roles` — `user_id uuid → users.id` (fk_user_roles_user), `role varchar(30)`
- `reserved_tenant_identifiers` — `identifier varchar(63) PK`, `tenant_id uuid NULL` (no FK, by design),
  `reserved_at timestamp NOT NULL`

**order-service** (`db/changelog/`, moved from `changes/` during implementation — research R2 revised)
- `orders` — `id uuid PK`, `tenant_id uuid`, `order_number varchar(50)`†, `total_amount decimal(19,2)`,
  `status varchar(20)`†, `created_by uuid`, `version bigint default 0`,
  `created_at`/`updated_at timestamp default CURRENT_TIMESTAMP`,
  indexes `idx_orders_tenant_id`, `idx_orders_tenant_created`
- **Removed by this feature**: `fk_orders_tenant` → `tenants.id`. That table does not exist in
  order-service's database and never has (research R7/D1).

† narrower than the entity's implicit `varchar(255)`; legacy environments keep 255. Hibernate
`validate` checks presence and type, not length — the assumption the quickstart proves first.
