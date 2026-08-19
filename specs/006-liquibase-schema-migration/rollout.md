# Rollout: Cutting Environments Over to Liquibase

**Spec**: [spec.md](./spec.md) | **Contracts**: [startup](./contracts/startup-schema-contract.md) ·
[baseline](./contracts/baseline-operation-contract.md) | **Quickstart**: [quickstart.md](./quickstart.md)

Every environment whose schema predates this feature — local, dev, staging, production — is a
"legacy" database in FR-005's sense: tables exist, no `DATABASECHANGELOG`. Each one needs
exactly one reconciliation run before it can start normally again. This is that cutover, done
one environment at a time, in order.

## Order of environments

**local → dev → staging → production.** Never skip ahead. Each environment gets a successful
*update-plus-validate* startup observed — the same run that reconciles it also proves, via
Hibernate `validate` in the same boot, that the resulting schema actually matches the entity
mappings (baseline contract, "Post-conditions" §3) — before the next environment is touched.
This is the point of doing it serially: a mismatch caught in dev never reaches staging or
production, because the reconciliation and the proof are the same startup.

## Per-environment procedure

1. **Back up.** A logical/volume snapshot of the database, taken before this run. Reconciliation
   touches no application data (baseline contract: "no data is read, written, or altered in
   application tables"), but back up anyway — this is the one irreversible-feeling step in the
   whole rollout and a snapshot makes it not irreversible.
2. **Confirm no changelog edits are pending.** Once this environment is reconciled, every
   changeset's checksum is recorded; editing an already-synced changeset breaks every later
   startup for this environment (research R7's ordering rule). If a changeset still needs
   correcting, correct it now, in a fresh commit, before step 3 — never after.
3. **Run the reconciliation**, once, against this environment's real connection settings:

   ```bash
   java -jar <service>.jar --hydra.database.baseline.enabled=true
   ```

   or `HYDRA_DATABASE_BASELINE_ENABLED=true` in the environment for that one run. This is the
   same artifact every other startup uses — no separate migration job or image.
4. **Watch the one boot.** Expect, in order: the guard's WARN log naming the baseline tag, a
   normal Liquibase `update` that finds nothing left to do, and Hibernate `validate` completing
   without error. All three happen before the application finishes starting.
   - **If `validate` fails**: the reconciliation itself already succeeded (the changesets are
     recorded) — the schema just does not match the entity mappings. Fix the mismatch with a new
     changeset (never edit the synced one) and restart; do not proceed to the next environment
     until this one's `validate` passes cleanly (spec Edge Cases, quickstart S7).
5. **Remove the flag.** `hydra.database.baseline.enabled=true` must never be committed into a
   profile YAML, a Helm value, or a deployment manifest — it is a one-shot human act for this
   run only. Restart the service normally (flag unset) and confirm it comes up the same way.
6. **Move to the next environment** only after this one's normal (unflagged) restart succeeds.

## Local development

Same procedure, applied to `~/data/auth_db.mv.db` / `~/data/orders_db.mv.db` (or delete and let
bootstrap reseed — see [RUNNING.md](../../RUNNING.md)). Every developer's machine is its own
"environment" here: FR-006 exempts none of them, local included.

## Audit: which environment was reconciled, and when

Answered entirely from `DATABASECHANGELOG`, per FR-008 and the baseline contract's "Audit
answers" section — no separate log or ledger:

```sql
select tag, dateexecuted, deployment_id
from databasechangelog
where tag is not null
order by dateexecuted desc;
```

- **Which environment** — the database this query was run against *is* the answer; there is one
  independent `DATABASECHANGELOG` per service per database (spec Edge Cases).
- **When** — `dateexecuted` on the tagged row.
- **What was assumed already present** — every row sharing that row's `deployment_id`.
- **Real execution or reconciliation** — the presence of a non-null `tag`. `exectype` alone
  cannot answer this: Liquibase writes `EXECUTED` for both a real run and a sync (research R4).

A normal (non-reconciled) environment has no tagged rows at all — the query above simply
returns nothing there, which is itself the answer ("never reconciled; every changeset actually
ran").
