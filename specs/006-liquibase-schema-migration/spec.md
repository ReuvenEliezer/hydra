# Feature Specification: Liquibase Schema Migration Authority

**Feature Branch**: `006-liquibase-schema-migration`

**Created**: 2026-08-18

**Status**: Draft

**Input**: User description: "Activate Liquibase as the authoritative schema-management mechanism for auth-service and order-service, which are currently running under Spring Boot 4 with Hibernate `ddl-auto: update` silently owning the schema instead. Liquibase's engine and changelog scripts are already present on disk (auth-service: `001-init-auth-schema.yaml`, `002-tenant-url-identifier.yaml`; order-service: its own master changelog at a non-default path) but never execute, because the auto-configuration module that wires Liquibase into Spring Boot 4 was never added as a dependency. The feature must: (1) make the existing changelog scripts actually run, (2) reconcile the change against databases whose schema was already created by Hibernate, without data loss or startup failure, (3) fix order-service's changelog so it is found at all, and (4) demote Hibernate to a verification-only role so schema drift is caught rather than silently patched."

## Clarifications

### Session 2026-08-18

- Q: If a migration script fails partway through execution against a real environment, what must happen to the database afterward? → A: Fail loud, fix forward — the failed script's own statements roll back where the database supports it, the service stays down until a human corrects and re-runs it, and no automatic undo of previously-applied scripts is attempted.
- Q: How should a service detect that it's starting against a database that already has its tables but has never been through the reconciliation step? → A: A single up-front guard before any script runs — if the database has existing tables but no migration history, refuse to start with an explicit "reconciliation required" message. Migration scripts are not individually self-guarding.
- Q: Where should migration scripts actually be applied — inside each service instance as it starts up, or by a separate one-time migration run? → A: At service startup in every instance, serialized so only one applies while the others wait. No separate deployment artifact is introduced by this feature; whether the Kubernetes lab later fronts it with a dedicated job is a decision for that feature, not this one.
- Q: When the reconciliation step runs, must it first verify that the existing schema genuinely matches what the migration scripts describe? → A: Mark, then verify at startup — reconciliation marks the scripts as applied, and the very next service startup runs the schema verification check, so any mismatch fails startup immediately and loudly rather than staying hidden.
- Q: After cutover, should local development also require a migration script for every entity change, or keep generating the schema automatically from entities? → A: Local behaves identically to every other environment — migration scripts are the only way schema changes happen, and a missing script fails local startup too. No environment is exempt.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Schema changes are tracked and repeatable (Priority: P1)

As a platform engineer operating auth-service and order-service, I want every schema
change to be captured in a versioned, ordered migration script and applied
automatically when a service starts, so that the schema's history is auditable and a
new environment can be stood up without manual database work or guessing what the
current schema looks like.

**Why this priority**: This is the core value of the feature — without it, the
changelog scripts remain decorative, and the risk called out during audit (someone
"fixing" the missing dependency one day and triggering an unreviewed schema change
against production) stays live.

**Independent Test**: Can be fully tested by starting each service against a brand
new, empty database and confirming the schema that results is created entirely by
the changelog scripts executing in order, with no manual intervention.

**Acceptance Scenarios**:

1. **Given** a brand-new, empty database, **When** the service starts for the first
   time, **Then** every migration script for that service runs in order and the
   resulting schema matches what the service's data model expects.
2. **Given** a schema that already reflects all currently-defined migration scripts,
   **When** the service restarts, **Then** no migration script re-runs and startup is
   not slowed or altered by the migration mechanism.
3. **Given** a new migration script is added to the changelog, **When** the service
   next starts, **Then** only that new script executes against environments that
   don't yet have it applied.

---

### User Story 2 - Existing environments upgrade without data loss (Priority: P1)

As a platform engineer, I want the cutover to the migration mechanism to run safely
against the dev, staging, and production databases that already have their schema
in place (created previously by automatic mapping-derived schema generation), so
that turning this on does not wipe, duplicate, or corrupt existing tables and data.

**Why this priority**: Every environment this project runs today already has a live
schema and real data. A cutover that assumes "empty database" would break every
existing environment on the next deploy — this has to be safe before the mechanism
can be trusted anywhere.

**Independent Test**: Can be fully tested by taking a copy of an existing database
(with data) whose schema was produced by automatic mapping-derived generation,
performing the reconciliation step, and confirming the service starts successfully
afterward with all pre-existing data intact and unchanged.

**Acceptance Scenarios**:

1. **Given** an existing database whose schema already matches the currently-defined
   migration scripts (because it was previously created by other means), **When**
   the reconciliation step runs, **Then** the database is marked as up to date
   without re-running any script that would recreate or alter existing objects.
2. **Given** an existing database with real rows in its tables, **When** the
   reconciliation step and subsequent service startup complete, **Then** every
   pre-existing row is still present and unchanged.
3. **Given** the reconciliation step has not yet been performed on a given
   environment, **When** the service attempts to start using the new mechanism,
   **Then** the service fails to start with an explicit message naming the
   reconciliation action as the required next step, and no schema-creation is
   attempted against the objects that already exist.

---

### User Story 3 - Every service's migration scripts are actually discovered (Priority: P2)

As a platform engineer, I want each service's migration scripts to be found at
startup regardless of where they live in that service's resources, so that a
service isn't silently skipped just because its changelog isn't at the tool's
default location.

**Why this priority**: order-service's changelog was found at a non-default location
before this feature. Fixing the dependency without fixing this would have made that
service look migrated while its scripts still never executed — the same
looks-correct-but-isn't trap the feature exists to close.

**Independent Test**: Can be fully tested by starting that service against an empty
database and confirming its migration scripts run, not just the other service's; and,
separately, by configuring the discovery mechanism to look for a changelog that isn't
there and confirming startup fails loudly rather than silently skipping that
service's migrations.

**Acceptance Scenarios**:

1. **Given** a service's changelog is not at the tool's default location, **When**
   the service starts, **Then** its migration scripts are still located and executed
   the same as any other service's.
2. **Given** the configured changelog path names nothing that exists, **When** the
   service starts, **Then** startup fails with an explicit message naming the missing
   path, rather than silently skipping that service's migrations.

> **Implementation note**: order-service's changelog was ultimately moved to the
> tool's default location rather than being discovered dynamically at its original
> non-default path (research.md R2, revised) — the concrete defect ("its scripts
> never execute") is resolved either way. The discovery mechanism itself remains
> location-agnostic and is exercised by its negative case (Scenario 2 above,
> quickstart S8), so this story stays valid for any future service that does end up
> at a non-default path.

---

### User Story 4 - Schema drift is caught, not silently patched (Priority: P2)

As a platform engineer, I want the schema-generation-from-mapping mechanism to run
in a verification-only mode after cutover, so that a data-model change that isn't
accompanied by a matching migration script is caught as a startup failure instead of
being silently applied to the live schema.

**Why this priority**: Without this, both mechanisms keep making decisions about the
schema at the same time, defeating the purpose of having a single authoritative,
auditable source of schema changes.

**Independent Test**: Can be fully tested by introducing a data-model change with no
corresponding migration script and confirming the service fails to start with a
clear mismatch error, rather than starting successfully with an altered schema —
and that this happens on a developer's own machine, not only in deployed
environments.

**Acceptance Scenarios**:

1. **Given** the data model and the applied schema are in agreement, **When** the
   service starts, **Then** startup succeeds and no schema object is created,
   altered, or dropped by the verification step.
2. **Given** the data model has changed without an accompanying migration script,
   **When** the service starts, **Then** startup fails with a clear mismatch error
   and no schema object is altered.

---

### Edge Cases

- What happens if a migration script fails partway through on one instance while
  another instance of the same service is starting concurrently? Only one instance
  may apply changes at a time; the other must wait or fail safely rather than racing
  to apply the same or a conflicting change.
- What happens if a migration script fails partway through execution? The failed
  script's own statements are undone where the database supports undoing them, the
  script is not recorded as applied, the service does not start, and it stays down
  until a person corrects the script and re-runs it. Migration scripts that had
  already succeeded before it are left in place — there is no automatic multi-step
  undo.
- What happens if the reconciliation step is run twice against the same database?
  It must be safe to repeat — it must not fail, and must not re-apply anything
  already marked as applied.
- What happens if a new migration script is added to the shared changelog and only
  one of the two services is meant to receive it? Each service's changelog and
  migration history must be independent, even though both services depend on the
  same shared module for the mechanism itself.
- What happens if reconciliation is attempted against an environment whose schema
  does *not* already match the current migration scripts (e.g. a partially-applied
  or hand-edited environment)? Reconciliation itself proceeds, but the next service
  startup's verification check fails loudly on the discrepancy — the environment is
  never left silently believing it is up to date when it is not.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The system MUST apply each service's versioned migration scripts
  automatically, in defined order, when that service starts against a database that
  does not yet have them applied.
- **FR-002**: The system MUST NOT re-apply a migration script that has already been
  recorded as applied against a given database.
- **FR-003**: The system MUST discover and execute a service's migration scripts
  regardless of whether they live at that mechanism's conventional default location
  within the service, correcting the case where a service's changelog currently goes
  unfound.
- **FR-004**: The system MUST provide a one-time, explicit reconciliation action per
  environment that marks migration scripts whose effects already exist in that
  environment's schema as applied, without re-executing their schema-creating
  statements and without altering existing data. The reconciliation action itself
  is not required to pre-verify that the live schema matches those scripts; that
  verification MUST instead occur on the next service startup (FR-006), so any
  discrepancy fails startup immediately rather than remaining hidden.
- **FR-005**: Before any migration script runs, the system MUST check whether the
  target database already contains the service's tables while having no migration
  history. If it does, the system MUST refuse to start and MUST report an explicit
  message identifying the one-time reconciliation action (FR-004) as the required
  next step, rather than attempting a schema-creation action against objects that
  already exist. Individual migration scripts MUST NOT carry their own
  already-exists guards, so that an unexpected schema state surfaces as this
  explicit failure rather than being quietly absorbed.
- **FR-006**: After cutover, the system MUST restrict the data-model-driven schema
  mechanism to verification only — it MUST be able to detect and fail startup on a
  mismatch between the data model and the applied schema, and MUST NOT create,
  alter, or drop schema objects itself. This MUST apply uniformly to every
  environment, local development included; no environment may retain
  entity-driven schema generation.
- **FR-007**: Migration scripts MUST be applied by the service instances themselves
  as they start, with no separate deployment artifact required. When several
  instances of the same service start at once against the same database, the system
  MUST ensure only one applies migrations while the others wait for it to finish,
  and MUST NOT allow two instances to apply changes concurrently.
- **FR-008**: The reconciliation action MUST be auditable — it MUST be possible to
  determine, after the fact, which environment it was run against and when.
- **FR-009**: All future schema changes MUST be expressed as new versioned migration
  scripts; the data-model-driven mechanism MUST NOT be relied upon to produce or
  change schema going forward.
- **FR-010**: When a migration script fails, the system MUST fail the service's
  startup, MUST NOT record that script as applied, and MUST undo that script's own
  statements where the database supports undoing them. The system MUST NOT attempt
  to automatically undo migration scripts that had already been applied
  successfully; recovery is by correcting the script and re-running forward.

### Key Entities

- **Migration script (changeset)**: A single, versioned, ordered unit of schema
  change belonging to one service, uniquely identified so it can be applied at most
  once per database.
- **Migration history record**: Per-database bookkeeping of which migration scripts
  have been applied and when, used to decide what still needs to run and to prevent
  re-application.
- **Reconciliation baseline**: A one-time record, created per environment, marking
  the set of migration scripts whose effects already existed in that environment's
  schema before the mechanism was activated there.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: 100% of schema changes made after cutover are traceable to a specific,
  versioned migration script rather than to an incidental data-model change.
- **SC-002**: Every existing environment (dev, staging, production) completes
  cutover with zero data loss and zero unplanned service downtime.
- **SC-003**: A brand-new environment can be stood up with a fully correct schema
  using only the migration scripts, verified by successful service startup with no
  manual database steps.
- **SC-004**: A data-model change introduced without a matching migration script is
  caught as a startup failure in 100% of cases, rather than being silently applied.
- **SC-005**: Both in-scope services (auth-service and order-service) have their
  migration scripts executing after cutover — measured by each environment's
  migration history record showing all currently-defined scripts as applied for
  both services.

## Assumptions

- Both auth-service and order-service are in scope; order-service's changelog being
  at a non-default location is a defect to fix as part of this feature, not a
  reason to exclude it.
- Every environment in use today (including production) already has a live schema
  and real data produced by the data-model-driven mechanism; none can be treated as
  starting from empty.
- Cutover is performed environment by environment with an explicit reconciliation
  step per environment, not a single global switch flipped everywhere at once.
- The verification-only mode for the data-model-driven mechanism is the intended
  end state for both services in every environment after cutover — including local
  development — and it is not expected to return to being schema-authoritative
  afterward. Developers accept writing a migration script for every entity change,
  including local experiments, in exchange for local and deployed environments
  behaving identically.
- The two services' migration histories and changelogs remain independent of each
  other even though the underlying mechanism is provided by a shared module.
- This feature introduces no new deployment artifact. Whether the Kubernetes lab
  (`005-k8s-production-lab`) later fronts startup migration with a dedicated
  one-time job is a decision belonging to that feature; this one must be shippable
  and verifiable on its own without it.
