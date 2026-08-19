# Contract: Service Startup Against a Database

**Applies to**: auth-service, order-service (mechanism supplied by `infra-database`)

This is the contract every service start now honors. It is observable from outside the JVM —
by whether the process comes up, and by what it logs when it does not.

## Startup sequence (fixed order)

1. DataSource is created.
2. **Guard** runs — before any changeset statement is issued (implemented as a
   `Customizer<Liquibase>` bean, invoked by `SpringLiquibase.createLiquibase` before
   `performUpdate`).
3. Reconciliation, if and only if requested and applicable.
4. Liquibase `update` — applies exactly the changesets absent from `DATABASECHANGELOG`.
5. Hibernate `validate` — compares entity mappings to the resulting schema.
6. Application context finishes starting.

Steps 2–5 are all-or-nothing with respect to startup: any failure in them fails the boot.
No step in this sequence may create, alter, or drop a schema object except step 4.

## Guarantees

| # | Guarantee | Requirement |
|---|---|---|
| G1 | On an empty database, all changesets apply in changelog order | FR-001 |
| G2 | A changeset recorded in `DATABASECHANGELOG` never runs a second time | FR-002 |
| G3 | The changelog is located at the configured `spring.liquibase.change-log`, default or not; a missing file fails startup loudly | FR-003 |
| G4 | Tables present + no migration history ⇒ startup refused with the reconciliation message | FR-005 |
| G5 | Hibernate issues no DDL; a model/schema mismatch fails startup | FR-006 |
| G6 | Concurrent instances serialize on `DATABASECHANGELOGLOCK`; exactly one applies | FR-007 |
| G7 | A failed changeset is not recorded, its own statements roll back where the database supports it, and previously applied changesets are left alone | FR-010 |
| G8 | These guarantees are identical in every profile, local included | FR-006, FR-009 |

## Required configuration per service

```yaml
spring:
  jpa:
    hibernate:
      ddl-auto: validate
```

`ddl-auto: validate` must appear in the base `application.yaml` **and** in every profile file
that currently overrides it — a profile that still says `update` silently re-arms the mechanism
this feature exists to disarm.

`spring.liquibase.change-log` is deliberately **absent** from both services' configuration.
Both changelogs live at Liquibase's default classpath location
(`db/changelog/db.changelog-master.yaml`), so naming the path explicitly would only restate the
default with no behavioral effect (research.md R2, revised) — explicit configuration is added
only when it changes behavior or documents a genuinely non-default contract, and this is
neither. G3 below still holds: a wrong or missing changelog fails startup loudly regardless of
whether the path came from a default or an override.

## Failure contract

| Condition | Behavior | Message must name |
|---|---|---|
| Legacy schema, no history, no baseline flag | Startup fails before any DDL | the database, and `hydra.database.baseline.enabled=true` as the required next step |
| Changelog file not found | Startup fails | the configured changelog path |
| Changeset fails | Startup fails, nothing recorded for it | the changeset id and the underlying database error |
| Entity/schema mismatch after update | Startup fails at step 5 | the offending table/column (Hibernate's own message) |

No condition in this table may be downgraded to a warning, and none may be bypassed by an
environment-specific property. The only supported escape hatch is `spring.liquibase.enabled`,
which is not set by this project in any profile.
