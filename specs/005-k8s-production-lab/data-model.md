# Phase 1 Data Model: Kubernetes Production Lab

**Feature**: `005-k8s-production-lab` | **Date**: 2026-08-18

This lab's "data model" is not a database schema — it is the set of artifacts the platform creates, reads and validates. Each of the spec's thirteen Key Entities is mapped below to where it physically lives, what fields it carries, what validates it, and how it changes state. Nothing here duplicates the services' own schemas; those are owned by `auth-service` and `order-service` and are unchanged by this feature.

---

## 1. Version Matrix

**Lives in**: `k8s-lab/versions.env` (authoritative, machine-readable) rendered into `k8s-lab/docs/versions.md` (human-readable, generated — never hand-edited).

| Field | Type | Rule |
|---|---|---|
| `component` | key | One of the fourteen components FR-005 enumerates, plus the Maven toolchain image (D2) and the OTel Java agent (D10) |
| `version` | pinned string | Exact release. A tag containing `latest`, `stable`, `main` or a bare major is invalid |
| `compatibility_basis` | string | What this version was checked against — the upstream support matrix, a release note, or a tested combination |
| `exception` | optional string | The documented reason a moving reference is permitted; absent means none is |

**Validation**: a `make verify-versions` check asserts that every version referenced anywhere in `k8s-lab/` — chart values, Helm `--version` flags, image tags, CRD URLs — resolves to the matrix entry, and that zero moving references exist outside recorded exceptions (SC-022). Scripts **read** `versions.env`; they never hard-code a version. That is what keeps documentation and reality from diverging.

**State**: static per release of the lab. Changing a version is an edit to `versions.env` plus a re-recorded compatibility basis — never an edit to a script.

---

## 2. Checkpoint

**Lives in**: `k8s-lab/scripts/lib/checkpoint.sh`, consumed by every setup script.

| Field | Type | Rule |
|---|---|---|
| `name` | string | Unique, ordered — `cluster`, `cilium`, `gateway-api`, `registry`, `certs`, `backing-services`, `observability`, `argocd`, `console`, `migrate`, `fixture`, `apps` |
| `precondition` | checkpoint name | The checkpoint that must have passed first |
| `action` | command | The work |
| `validation` | command | A **condition-based wait** with a bounded timeout (FR-015). A fixed sleep is never a validation |
| `summary` | string | Concise output printed on success |
| `on_failure` | halt | Prints failure with diagnostic context and stops; later checkpoints report nothing, not "not run yet as success" |

**State transitions**: `PENDING → RUNNING → PASSED` or `PENDING → RUNNING → FAILED (terminal for the run)`. There is no `SKIPPED-BUT-OK`. A checkpoint whose dependency failed is `BLOCKED` and reports as such.

**Invariant (FR-098, SC-015)**: a checkpoint may only report `PASSED` if its `validation` command exited zero. No checkpoint asserts its own success.

---

## 3. Environment Diagnostic Report

**Lives in**: stdout of `k8s-lab/scripts/doctor.sh`, plus an exit code.

| Field | Type | Rule |
|---|---|---|
| `check` | string | One per FR-001 item: container CLI, container daemon, kind, kubectl, helm, Java toolchain + version, Maven + the Java version it will actually use, CPU, memory, architecture, free ports (443, 80, registry port), container storage |
| `required` | bool | Optional checks may warn without failing the run |
| `observed` | string | What was found |
| `expected` | string | What is required |
| `verdict` | `PASS` \| `FAIL` \| `WARN` | — |

**Output contract**: one line per check, then a single readiness statement (`ENVIRONMENT READY` / `ENVIRONMENT NOT READY`). Exit non-zero if any required check failed (FR-002).

**Invariant (FR-003)**: the diagnostic installs, modifies and upgrades nothing. It reports and instructs. This is testable — the seeded-failure cases of SC-002 confirm it names the missing tool and exits non-zero without side effects.

---

## 4. Service Image

**Lives in**: the local registry, built from `auth-service/Dockerfile` and `order-service/Dockerfile`.

| Field | Type | Rule |
|---|---|---|
| `service` | enum | `auth-service` \| `order-service` |
| `tag` | string | Revision-derived and immutable — `<git-short-sha>` plus a `-dirty` suffix when the tree is not clean. Never `latest` (FR-017) |
| `modules_included` | set | Must equal the service's actual reactor dependency set: `infra-shared`, `infra-database`, `rate-limit-starter`, `browser-edge-starter` (research.md A2) |
| `builder_toolchain` | string | The pinned Maven/JDK image, printed by the build (FR-004, D2) |
| `agent_path` | path | `/opt/otel/opentelemetry-javaagent.jar`, inert unless `JAVA_TOOL_OPTIONS` activates it (D10) |
| `runtime_user` | uid:gid | A dedicated non-root identity with explicit numeric ids, so `runAsUser` in the pod spec matches the image (FR-057) |

**Validation**: `docker build --no-cache` from a clean state must succeed (FR-018), and the resulting image must run the full integration flow — which is what proves the classpath layout survived the build, including the `lua/*.lua` load sites (Constitution Principle III).

**State**: immutable once published. A change produces a new tag; a tag is never re-pushed.

---

## 5. Tenant Address

**Lives in**: DNS (RFC 6761 loopback resolution), the wildcard certificate, and the `Tenant` rows the fixture seeds.

| Field | Type | Rule |
|---|---|---|
| `hostname` | FQDN | `<identifier>.localhost` — one label in front of the base domain |
| `identifier` | string | The DNS label; must match a seeded tenant's `url_identifier` and must not collide with `hydra.tenant.reserved-identifiers` |
| `certificate_coverage` | derived | Covered by the single `*.localhost` wildcard — no per-tenant certificate entry (FR-040) |
| `gateway_config` | derived | **None.** A tenant requires no route, no listener and no certificate of its own |

**Invariant (FR-040, SC-007)**: adding a tenant is a database insert. If any gateway object must change for a new tenant to work, Clause 5 of the transparent edge contract has been violated and the lab has found something.

**Minimum population**: three — `acme` and `beta` seeded up front (matching `EdgeConformanceFixture`'s constants exactly), and `gamma` added *after* the gateway is running, which is how SC-007 is demonstrated rather than asserted.

---

## 6. Lab Fixture

**Lives in**: `k8s-lab/charts/hydra-lab/templates/job-fixture.yaml` plus the SQL and verification it runs.

| Field | Type | Rule |
|---|---|---|
| `tenants` | list | `acme`, `beta` (+ `gamma` applied later by the SC-007 test) — every hostname FR-033 requires |
| `users` | list | Per tenant, with **pre-computed BCrypt hashes** matching the encoder the services use |
| `ordering` | constraint | Strictly after the migration Job, strictly before any Deployment pod accepts traffic |
| `idempotency` | constraint | `ON CONFLICT DO NOTHING` — identical on every recreation, no manual step (FR-052a) |
| `success_condition` | executed check | **A real sign-in must succeed.** Row counts are not success (research.md D7) |

**Why the success condition is part of the entity, not the test**: the spec names fixture drift as an edge case precisely because a fixture can apply cleanly and still produce accounts that cannot authenticate. Seeding that cannot sign in is a failed seed, and the Job — not a later suite — is where that must surface.

**Documented coverage gap (FR-052b)**: this fixture is *why* `auth-service`'s first-boot bootstrap never runs in the lab. The concurrent-bootstrap race is neither proven safe nor proven broken here.

---

## 7. Backing Service

**Lives in**: StatefulSets in the `hydra-data` namespace.

| Field | Type | Rule |
|---|---|---|
| `kind` | enum | `postgres` \| `redis` |
| `image` | pinned | Same as `docker-compose.yml`: `postgres:16-alpine`, `redis:8.8-alpine` (D14) |
| `credentials` | Secret ref | Never in source, manifests, charts, images or version control (FR-053, FR-076) |
| `readiness` | probe | `pg_isready` / `redis-cli ping` — a real check, not a TCP open |
| `permitted_callers` | NetworkPolicy | Postgres: both services and the migration/fixture Jobs. Redis: both services. Everything else denied (FR-054) |
| `production_equivalent` | doc ref | Managed Postgres / managed cache, with the differences that do not transfer stated (FR-112) |

**Deliberate failure mode (FR-056)**: Redis unavailability is a *drill*, not an accident. Because rate limiting fails closed by default (`rate-limit.fail-open: false`), losing Redis rejects requests rather than passing them through. The lab demonstrates this on purpose so the behaviour is a known property.

---

## 8. Secret Material

**Lives in**: Kubernetes Secrets created by `setup`, referenced (never contained) by the tracked GitOps tree.

| Item | Consumed as | Production equivalent |
|---|---|---|
| JWT signing key (RSA private key, PEM) | File mount read via `jwt.private-key-path` by `LocalKeyProvider` under the `test` profile (research.md D5) | AWS Secrets Manager via `CloudKeyProvider` — the code path already exists |
| Postgres credentials | `SPRING_DATASOURCE_USERNAME` / `_PASSWORD` | Managed database credentials from a secret store |
| Redis credentials | `SPRING_DATA_REDIS_PASSWORD` | Managed cache auth token |
| Lab CA + wildcard certificate | Gateway listener `certificateRefs` | ACM / cert-manager with a real issuer |

**Invariant (FR-047)**: every `auth-service` replica mounts the **same** Secret, so a token issued by one replica validates against the key set published by any other. Making the key a mounted Secret rather than per-pod material is what makes this true by construction rather than by coincidence.

**Invariant (FR-085, SC-022 sibling)**: `git grep` over the tracked tree finds no secret value. The GitOps tree carries Secret *names*.

**Documentation obligation (FR-055)**: the mapping above, plus a plain statement that the lab's secret handling is not itself a production pattern.

---

## 9. Edge Conformance Result

**Lives in**: Maven surefire output from Hydra's **existing** `edge-conformance` suite, captured into `k8s-lab/results/edge-conformance/`.

| Field | Type | Rule |
|---|---|---|
| `target` | enum | `lab-gateway` \| `hostile-gateway` — **both are required** |
| `base_url` | URL | `https://acme.localhost`, passed as `-Dedge.base-url` |
| `truststore` | path | The lab CA, passed as `-Djavax.net.ssl.trustStore`. Verification is never disabled |
| `clause_results` | 5 verdicts | Clauses 1–5 of the transparent edge contract, plus the suite's addendum assertions |
| `expected` | derived | `lab-gateway` → all pass. `hostile-gateway` → **fails, naming the violated clause** |
| `suite_modifications` | must be empty | Zero assertion changes (SC-020) |

**Why both targets are the entity, not just the pass**: a suite that only ever meets a correct edge cannot distinguish "the edge is transparent" from "the assertions no longer work." The pass alone proves nothing (FR-042).

---

## 10. Failure Drill

**Lives in**: `k8s-lab/tests/failure/`, one script per drill.

| Field | Type | Rule |
|---|---|---|
| `name` | string | One of the nine below |
| `trigger` | command | The controlled fault |
| `expected_observable` | assertion | What must be seen — not merely that nothing crashed |
| `restore` | command | Returns the environment to its pre-drill state |
| `restore_verification` | executed check | The standard health checks must pass afterwards (FR-097, SC-014) |
| `client_load` | bool | Whether an external client issues continuous requests throughout |

| Drill | Expected observable | Success criterion |
|---|---|---|
| `pod-delete` | Replacement Ready; client sees no sustained loss | SC-008: ≥99% success over 60s |
| `bad-image` | `ImagePullBackOff`; healthy pods keep serving; restore recovers | FR-097 |
| `readiness-fail` | Replica stops receiving traffic while still running; resumes on ready | FR-064 (gated behind a non-production profile) |
| `network-policy` | Unauthorised workload denied; authorised succeeds | SC-013: 100% / 0%, repeatable |
| `rolling-update` | New pods ready before old terminate; migration safe; zero failed requests | SC-009 |
| `cache-down` | Requests **rejected**, not passed through — fail-closed observed | FR-056 |
| `concurrent-rotation` | Exactly one rotation succeeds | SC-010: ≥100 concurrent attempts, zero double-honoured |
| `cross-replica-limit` | At most N per window **across all replicas** | SC-011 |
| `node-stop` | Scheduling and availability behaviour reported, with the difference from a real cloud node failure stated | FR-097, FR-112 |

**Invariant**: a drill that cannot restore the environment fails — leaving the lab broken is a drill failure, not a side effect.

---

## 11. Validation Result

**Lives in**: stdout of `k8s-lab/tests/*` aggregated by `make validate`, plus an exit code.

| Field | Type | Rule |
|---|---|---|
| `component` | string | One row per checked component |
| `verdict` | `PASS` \| `FAIL` \| `SKIPPED-BY-CONFIGURATION` | The third exists only for reduced mode (D18) and is never presentable as a pass |
| `evidence` | string | The command whose exit status produced the verdict |
| `overall` | single verdict | — |
| `exit_code` | int | Non-zero if any required check failed (FR-098, FR-101, SC-015) |

**Invariant, and it is the one that makes the whole lab trustworthy**: no component is reported passing without an executed check behind it. `evidence` is a required field precisely so that an asserted pass is structurally impossible to express.

---

## 12. Benchmark Report

**Lives in**: `k8s-lab/results/benchmark/<timestamp>/report.md`.

| Field group | Contents |
|---|---|
| Configuration | Concurrency mode, replica count, resource limits, GC selection (**held constant across concurrency comparisons** — FR-104a), sampling settings, agent overhead |
| Hardware | CPU model, cores, memory, architecture, container runtime version |
| Load profile | Endpoints (must block on Postgres **and** Redis — FR-104), concurrency, duration, warm-up |
| Results | RPS, throughput, p50/p95/p99 latency, error rate, **throttled counted separately from errors** (FR-105) |
| Resource observations | CPU, memory, JVM heap, GC behaviour, container memory, replica count |
| Repetition | Repeated runs with observed variance — never a single unqualified figure (SC-017) |
| Limitations | Workstation hardware, workload shape, concurrency, latency, downstream behaviour, runtime configuration, resource limits, agent overhead (FR-106) |

**Prohibitions, enforced by review of the generated report (FR-107)**: no conclusion the measurements do not support; no generalisation from workstation to production; **no claim that the lightweight thread model reduces memory consumption** (FR-050, FR-062).

---

## 13. Edge Finding

**Lives in**: `k8s-lab/docs/edge-finding.md`.

| Section | Contents |
|---|---|
| What the lab demonstrated | Contract clauses satisfied by a real Cilium/Envoy gateway over TLS, with the conformance run as evidence |
| What it could not demonstrate locally | Real load-balancer behaviour, real node failure, managed control plane, multi-zone, real certificate issuance — and any of D12/D13 that did not land |
| What would still require cloud verification | The list a reader would need before the constitution's open question could be closed |
| Framing | **Evidence toward** the Kubernetes-versus-compose question. Not a resolution of it (FR-113) |

**Readability invariant (SC-023)**: a reader can state what the lab proved and what it did not without opening any other document.

---

## Entity relationships

```text
Version Matrix ──drives──> every Checkpoint, Service Image, Backing Service
Environment Diagnostic Report ──gates──> Checkpoint(cluster)
Checkpoint(migrate) ──precedes──> Checkpoint(fixture) ──precedes──> Checkpoint(apps)
Lab Fixture ──creates──> Tenant Address rows
Secret Material ──consumed by──> Service Image at runtime, Backing Service, Gateway listener
Tenant Address + Service Image ──serve──> Edge Conformance Result (lab + hostile)
Failure Drill ──asserts on──> running Service Images ──restores to──> Validation Result PASS
Benchmark Report + Edge Conformance Result ──feed──> Edge Finding
Validation Result ──aggregates──> every executed check in the lab
```
