# Contract: The One-Time Reconciliation (Baseline) Operation

**Applies to**: any environment whose schema predates this feature — including every
developer's local H2 files.

## Invocation

The same deployable artifact, started once with one flag:

```bash
java -jar <service>.jar --hydra.database.baseline.enabled=true
```

or, equivalently, `HYDRA_DATABASE_BASELINE_ENABLED=true` in the environment. No separate
image, job, or migration artifact is introduced (FR-007).

| Property | Default | Meaning |
|---|---|---|
| `hydra.database.baseline.enabled` | `false` | Reconcile this database during this startup |
| `hydra.database.baseline.tag` | `baseline-<UTC instant>` | Tag written to `DATABASECHANGELOG` after the sync |

The flag must never be baked into a profile YAML or a deployment manifest. It is a deliberate,
per-environment, one-time human act; a persisted flag turns "reconcile once" into "reconcile
whatever state you find", which is precisely the silent-patching behavior being removed.

## Behavior

| Precondition | Effect |
|---|---|
| Tables exist, no migration history | Every changeset in the changelog is recorded as applied **without executing its statements**, then the baseline tag is written, then startup continues into normal update (a no-op) and Hibernate `validate` |
| Migration history already present | No sync, no tag; logged as a no-op; startup proceeds normally (repeat-safe) |
| Empty database | No sync; logged; the normal update creates the schema from scratch |

**No data is read, written, or altered in application tables in any of these paths.**

## Post-conditions

1. `DATABASECHANGELOG` contains one row per changeset defined at baseline time.
2. The last of those rows carries the baseline tag.
3. The same startup then proves the schema really matches the model: Hibernate `validate` runs
   in step 5 of the [startup contract](./startup-schema-contract.md) and fails the boot on any
   discrepancy. Reconciliation therefore never leaves an environment quietly believing it is up
   to date (FR-004, spec Edge Cases).
4. Re-running the operation changes nothing (idempotent).

## Audit answers this operation must support (FR-008)

- *Which environment was reconciled?* — the database holding the tagged rows.
- *When?* — `DATEEXECUTED` on those rows.
- *What was assumed already present?* — the set of rows sharing that `DEPLOYMENT_ID`.
- *Real execution or reconciliation?* — the baseline `TAG`. `EXECTYPE` cannot answer this:
  Liquibase writes `EXECUTED` for both (research R4).

## Ordering rule for the rollout

Every changelog correction — notably removing `fk_orders_tenant` (research R7/D1) — must land
**before the first environment is reconciled anywhere**. Once a changeset has been synced, its
checksum is recorded, and editing it turns every subsequent startup into a checksum-validation
failure that has to be resolved with a new changeset or an explicit `validCheckSum`.

## Order of environments

Cutover proceeds one environment at a time — local → dev → staging → production — with a
successful startup (update + validate) observed before moving to the next.
