---

description: "Task list for 005-k8s-production-lab"
---

# Tasks: Kubernetes Production Lab

**Input**: Design documents from `/specs/005-k8s-production-lab/`

**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/

**Tests**: This feature's *deliverables include* executable suites (FR-092..FR-102). Those suites appear below as implementation tasks inside the story that owns them — they are not TDD scaffolding, and no separate "write a failing test first" phase is generated.

**Organization**: Tasks are grouped by user story (US1..US8, priorities P1..P8) so each story can be implemented, run and validated independently.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependency on an incomplete task)
- **[Story]**: `[US1]`..`[US8]`; Setup / Foundational / Polish tasks carry no story label
- Every task names an exact file path

## Path Conventions

Everything the lab owns lives under `k8s-lab/` at the repository root. The **only** files touched outside it are `auth-service/Dockerfile` and `order-service/Dockerfile` (plan.md, Structure Decision). No Maven module is added; no service source or resource is edited (FR-044, SC-020).

## Binding rules for every task below

| Rule | Source |
|---|---|
| No script hard-codes a version — all read `k8s-lab/versions.env` | FR-006, SC-022 |
| Every wait is condition-based with a bounded timeout; a fixed sleep is never a readiness signal | FR-015 |
| No target reports a component as passing without an executed check behind it | FR-098, SC-015 |
| No secret value is written to the tracked tree | FR-053, FR-076, FR-085 |
| Every new file is `git add`-ed in the same step that creates it | repo convention |
| Nothing is reported complete on the strength of generated files — the environment must have been executed | FR-116 |

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Create the lab tree, the authoritative version matrix and the single developer entry point.

- [X] T001 Create the full `k8s-lab/` directory tree per plan.md (`scripts/lib/`, `cluster/`, `platform/{cilium,gateway-api,observability,argocd,headlamp}/`, `charts/hydra-lab/templates/`, `gitops/`, `tests/{smoke,integration,failure,perf}/`, `hostile-edge/`, `docs/`, `results/`) and `git add k8s-lab`
- [X] T002 [P] Author the pinned version matrix in `k8s-lab/versions.env` covering all sixteen components (FR-005 fourteen + Maven toolchain image per D2 + OTel Java agent per D10), each with a `# compatibility_basis:` comment and no moving reference (FR-006, FR-007)
- [X] T003 [P] Author `k8s-lab/.gitignore` excluding `.certs/` and `results/` so generated TLS material and run output can never be committed (FR-053, FR-085)
- [X] T004 Create `k8s-lab/Makefile` declaring **every** target in contracts/developer-interface.md as `.PHONY`, each delegating to a script under `k8s-lab/scripts/`, plus a `help` target listing them. The full surface is: `doctor`, `setup`, `setup-reduced`, `cleanup`, `verify-versions`; `cluster-create`, `cluster-delete`, `cluster-recreate`, `cluster-status`, `cluster-health`; `registry-create`, `registry-status`; `net-status`, `net-test`; `gw-status`, `gw-test`; `platform-install`, `platform-status`; `image-build`, `image-build-clean`, `image-publish`; `app-build`, `app-deploy`, `app-status`; `test`, `test-smoke`, `test-integration`, `test-failure`, `test-pod-failure`, `test-netpol`, `test-scaling`, `test-rolling-update`, `test-edge-conformance`, `test-hostile-edge`; `validate`, `validate-full`; `load-test`, `bench`; `dump`, `logs`, `debug`; `console-cluster`, `console-metrics`, `console-delivery`, `argocd-status`. Stubs are acceptable at this stage, the target surface is not (FR-089, SC-019)
- [X] T005 [P] Create `k8s-lab/scripts/render-versions.sh` rendering `k8s-lab/versions.env` into the generated, never-hand-edited `k8s-lab/docs/versions.md` (data-model §1)
- [X] T006 Create `k8s-lab/scripts/verify-versions.sh` behind `make verify-versions`, asserting every version referenced anywhere under `k8s-lab/` resolves to a `versions.env` entry and that zero moving references exist outside recorded exceptions (SC-022)

**Checkpoint**: `make help` and `make verify-versions` run; the version matrix is the single source of truth.

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: The shared Bash substrate every later script depends on — logging vocabulary, bounded waits, the checkpoint state machine, the setup orchestrator and the diagnostic dump.

**⚠️ CRITICAL**: No user story work can begin until this phase is complete.

- [X] T007 [P] Implement `k8s-lab/scripts/lib/log.sh` with the contract verdict vocabulary — `PASS`, `FAIL`, `SKIPPED-BY-CONFIGURATION`, `BLOCKED`, deliberately no `WARN` at suite level — emitting one line per check plus a summary (contracts/developer-interface.md)
- [X] T008 [P] Implement `k8s-lab/scripts/lib/assert.sh` with the assertion helpers the suites share (`assert_eq`, `assert_http_status`, `assert_header_absent`, `assert_exit_nonzero`), each recording a verdict through `log.sh`
- [X] T009 [P] Implement `k8s-lab/scripts/lib/wait.sh` providing only condition-based waits with mandatory bounded timeouts, printing diagnostic context on expiry; it MUST expose no sleep-based helper at all (FR-015)
- [X] T010 Implement `k8s-lab/scripts/lib/checkpoint.sh` as the `PENDING → RUNNING → PASSED|FAILED` state machine with `BLOCKED` propagation to dependents, where `PASSED` is reachable only when the validation command exited zero (data-model §2, FR-014, FR-098)
- [X] T011 Implement `k8s-lab/scripts/lib/versions.sh` as the sole loader of `k8s-lab/versions.env`, so no other script reads or hard-codes a version (FR-006)
- [X] T012 Implement `k8s-lab/scripts/setup.sh` as the ordered checkpoint runner over the registry `cluster → namespaces → cilium → gateway-api → gateway → registry → certs → backing-services → observability → argocd → console → migrate → fixture → apps`, halting at the first failure with diagnostic context and reporting later checkpoints as `BLOCKED` (FR-014). This extends data-model §2's list with `namespaces` (so Secrets have a namespace to land in, T025) and `gateway` (so the Gateway exists before the umbrella chart, T039/T040) — record both additions in data-model §2 when implementing
- [X] T013 Implement `k8s-lab/scripts/dump.sh` behind `make dump`, printing nodes, pods, services, endpoints, gateways, routes, network policies, events, deployments, autoscalers cluster-wide plus Cilium diagnostics (FR-090)
- [X] T014 Implement `k8s-lab/scripts/cleanup.sh` behind `make cleanup`, removing the cluster, the registry and lab-created local state so the first-run path works again (FR-109)

**Checkpoint**: Foundation ready — user story implementation can begin.

---

## Phase 3: User Story 1 - Reproducible platform from a clean machine (Priority: P1) 🎯 MVP

**Goal**: One diagnostic command names what is missing; one setup command produces a three-node cluster with Cilium as the sole networking layer, a local registry, lab TLS material and a programmed Gateway reachable from the workstation.

**Independent Test**: On a machine with only the documented prerequisites, run `make doctor`, then `make setup`, then `make cluster-status`, `make net-status`, `make gw-status`. All report healthy, and `make gw-test` receives a response produced inside the cluster.

### Environment diagnostic (FR-001..FR-004, SC-002)

- [X] T015 [US1] Implement the container-CLI and container-daemon checks in `k8s-lab/scripts/doctor.sh`, distinguishing "not installed" from "installed but not running" (spec Edge Cases → Environmental)
- [X] T016 [P] [US1] Add kind, kubectl and helm presence-and-version checks to `k8s-lab/scripts/doctor.sh`, comparing against `versions.env` rather than a literal
- [X] T017 [P] [US1] Add the Java toolchain check and the "which Java will Maven actually use" check to `k8s-lab/scripts/doctor.sh` (FR-001, FR-004)
- [X] T018 [P] [US1] Add CPU, memory, host-architecture, free-port (443, 80, registry port) and container-storage checks to `k8s-lab/scripts/doctor.sh` (FR-001, spec Edge Cases → port conflicts)
- [X] T019 [US1] Add the per-check `PASS`/`FAIL`/`WARN` line format, the concluding `ENVIRONMENT READY` / `ENVIRONMENT NOT READY` statement and the non-zero exit on any required failure to `k8s-lab/scripts/doctor.sh` (FR-002, data-model §3)
- [X] T020 [US1] Add an install-nothing guard to `k8s-lab/scripts/doctor.sh` — the script reports and instructs only, never installing, modifying or upgrading anything on the host (FR-003)
- [X] T021 [US1] Create `k8s-lab/tests/smoke/doctor-seeded-failures.sh` driving SC-002: for each seeded missing-prerequisite case the diagnostic names that tool and exits non-zero with no host side effect

### Cluster lifecycle (FR-010..FR-013)

- [X] T022 [US1] Author `k8s-lab/cluster/kind-cluster.yaml` — 1 control-plane + 2 workers with configurable worker count, `disableDefaultCNI: true`, `kubeProxyMode: none`, and `extraPortMappings` binding host 443 and 80 to fixed control-plane node ports (D1, D8)
- [X] T023 [US1] Implement `cluster-create` in `k8s-lab/scripts/cluster.sh`, verifying every expected node reaches Ready before reporting success (FR-013)
- [X] T024 [US1] Implement `cluster-delete`, `cluster-recreate`, `cluster-status` and `cluster-health` in `k8s-lab/scripts/cluster.sh`, keeping status (what exists) and health (whether it works) genuinely distinct (FR-012)
- [X] T025 [US1] Create the four lab namespaces `hydra-app`, `hydra-data`, `hydra-obs`, `hydra-delivery` (Cilium's own components stay in `kube-system`) as the `namespaces` checkpoint in `k8s-lab/scripts/platform.sh`, applied from `k8s-lab/platform/namespaces.yaml` immediately after cluster bootstrap and **before** the `certs`, `backing-services` and `observability` checkpoints, so every Secret those checkpoints create has a namespace to land in. Namespaces MUST NOT be an umbrella-chart template — the chart installs last and cannot create the namespace its own prerequisites already needed. Assert no application workload lands in `default` (FR-074, contracts/platform-topology.md)
- [X] T026 [US1] Make `cluster-create` idempotent against stale state in `k8s-lab/scripts/cluster.sh` — converge or fail with a clear instruction, never half-adopt a previous run (spec Edge Cases → stale state)

### Registry (FR-016, FR-019..FR-021)

- [X] T027 [US1] Implement `registry-create` in `k8s-lab/scripts/registry.sh` — a local registry container wired into the kind network and configured in the nodes' containerd
- [X] T028 [US1] Implement the addressing reconciliation in `k8s-lab/scripts/registry.sh` so the workstation address, the registry address, the node-container address and the in-node runtime address are each handled explicitly, never assuming loopback means the same thing inside a pod (FR-019)
- [X] T029 [P] [US1] Implement `registry-status` in `k8s-lab/scripts/registry.sh`, proving by an executed pull that the cluster can reach the registry
- [X] T030 [P] [US1] Implement the direct `kind load` fallback path in `k8s-lab/scripts/registry.sh`, documented in `k8s-lab/docs/registry.md` as a fallback and never as the primary path (FR-020)

### Networking layer (FR-011, FR-022..FR-025)

- [X] T031 [US1] Author `k8s-lab/platform/cilium/values.yaml` with `kubeProxyReplacement: true`, `l7Proxy: true`, `gatewayAPI.enabled: true`, `envoy.enabled: true`, policy enforcement and Hubble relay + UI enabled (D4, FR-023)
- [X] T032 [US1] Implement the `cilium` checkpoint in `k8s-lab/scripts/platform.sh` — Helm install at the pinned chart version, waiting on agent readiness on every node with a bounded timeout
- [X] T033 [P] [US1] Implement `net-status` in `k8s-lab/scripts/platform.sh` reporting Cilium health per node
- [X] T034 [US1] Implement `net-test` in `k8s-lab/tests/smoke/net-test.sh` exercising real pod-to-pod **and** pod-to-service traffic, not a configuration inspection (FR-024)

### TLS material (FR-032, FR-032a, FR-032b)

- [X] T035 [US1] Implement `k8s-lab/scripts/certs.sh` generating a lab CA and one wildcard certificate for `*.localhost`, idempotently, renewing material that is expired or within 30 days of expiry (FR-032a, D9)
- [X] T036 [US1] Extend `k8s-lab/scripts/certs.sh` to write the PKCS#12 truststore to `k8s-lab/.certs/lab-truststore.p12` and emit the password to an untracked file for later `-Djavax.net.ssl.*` handoff (FR-032b, D9)
- [X] T037 [US1] Extend `k8s-lab/scripts/certs.sh` to create the Kubernetes TLS Secret in `hydra-app` referenced by the Gateway's `certificateRefs`, with no certificate or key material entering the tracked tree (FR-053)

### Gateway (FR-026..FR-030, FR-034)

- [X] T038 [US1] Install the pinned standard-channel Gateway API CRDs from `k8s-lab/platform/gateway-api/crds/` via the `gateway-api` checkpoint in `k8s-lab/scripts/platform.sh`, using stable API versions where available (FR-027)
- [X] T039 [US1] Author `k8s-lab/platform/gateway-api/gatewayclass.yaml` and `k8s-lab/platform/gateway-api/gateway.yaml` — Cilium `GatewayClass` plus one `Gateway` in `hydra-app` with a single HTTPS listener on 443, `hostname: "*.localhost"` and `certificateRefs` to the lab TLS Secret, with no standalone gateway controller installed. These are **platform** objects applied by the `gateway` checkpoint, deliberately not umbrella-chart templates: the gateway must exist and be `Programmed` at the end of US1, and the chart is not installed until T073 in US2 (FR-029, contracts/platform-topology.md)
- [X] T040 [US1] Author `k8s-lab/platform/gateway-api/gateway-service.yaml` exposing the Gateway on the fixed NodePort that `kind-cluster.yaml` maps host 443 to — the one deterministic exposure mechanism — and implement the `gateway` checkpoint in `k8s-lab/scripts/platform.sh` applying `gatewayclass.yaml`, `gateway.yaml` and `gateway-service.yaml`, waiting on `Programmed` with a bounded timeout (FR-030, D8)
- [X] T041 [P] [US1] Implement `gw-status` in `k8s-lab/scripts/platform.sh` asserting the GatewayClass exists, the Gateway reports `Programmed`, and every HTTPRoute present reports `Accepted` — zero routes is a valid US1 state, since routes arrive with the chart in US2 (FR-034)
- [X] T042 [US1] Implement `gw-test` in `k8s-lab/tests/smoke/gw-test.sh` — a request from the workstation to `https://acme.localhost` completes a TLS handshake against the lab CA and receives a response produced by the in-cluster Cilium Envoy listener, proving the full host→NodePort→Envoy path with no chart installed. `make gw-test` MUST pass at the end of US1 (FR-034; upgraded to real application traffic by T072)
- [X] T043 [US1] Register the `cluster`, `namespaces`, `cilium`, `gateway-api`, `gateway`, `registry` and `certs` checkpoints in `k8s-lab/scripts/setup.sh` — the complete US1 slice of `make setup` — and implement `platform-install` / `platform-status` plus the `make doctor`, `make cluster-*`, `make registry-*`, `make net-*`, `make gw-*` wiring in `k8s-lab/Makefile` (FR-089)
- [X] T044 [US1] Write `k8s-lab/docs/north-south-path.md` documenting every hop from `https://acme.localhost` to the serving pod — resolver, kind port mapping, NodePort, Cilium Envoy listener, TLS termination, HTTPRoute, ClusterIP, endpoint (FR-030, contracts/platform-topology.md)

**Checkpoint**: US1 is independently deliverable and independently testable — `make doctor`, `make setup`, `make cluster-health`, `make net-test`, `make gw-status` and `make gw-test` all pass with **no umbrella chart installed**. The gateway objects live in `k8s-lab/platform/gateway-api/` precisely so this is true. This is the MVP.

---

## Phase 4: User Story 2 - Hydra's real services running in Kubernetes (Priority: P2)

**Goal**: `auth-service` and `order-service` build from this repository's own reactor, publish to the lab registry under immutable tags, and run against in-cluster Postgres and Redis, with sign-in → create order → list orders working end to end through the gateway.

**Independent Test**: `make image-build-clean && make image-publish && make app-deploy && make test-integration` — the full flow succeeds through the gateway, and neither service is reachable from outside the cluster except through it.

### Container build — resolves research.md A1, A2, A5 (FR-004, FR-017, FR-018, FR-057..FR-059)

- [X] T045 [US2] Run `docker run --rm <pinned runtime image> java -XX:+UseZGC -XX:+ZGenerational -version` and record in `k8s-lab/docs/jvm-flags.md` whether the JVM warns or refuses to start — if it refuses, the current images are a live bug and that fact goes in the commit message (D3 validation obligation, research.md A5)
- [X] T046 [US2] Rewrite the builder stage of `auth-service/Dockerfile` to `FROM maven:<pinned>-eclipse-temurin-25 AS builder`, deleting `COPY mvnw .` and `COPY .mvn .mvn`, invoking `mvn` directly, and printing `mvn -version` as the first build step (D2, research.md A1, FR-004)
- [X] T047 [US2] Rewrite the builder stage of `order-service/Dockerfile` identically to T046 (D2, research.md A1)
- [X] T048 [US2] Add `browser-edge-starter` to both the POM-copy layer and the source-copy layer of `auth-service/Dockerfile` and `order-service/Dockerfile` (research.md A2, FR-018) — without it the services emit no CORS headers and the edge contract fails from the inside
- [X] T049 [US2] Remove `-XX:+ZGenerational` from the runtime stage of both `auth-service/Dockerfile` and `order-service/Dockerfile`, leaving `-XX:+UseZGC` untouched (FR-059, D3)
- [X] T050 [US2] Evaluate `-Djava.security.egd=file:/dev/./urandom` against the same inertness test in both Dockerfiles, removing it only if startup measurement shows no difference, and record the measurement in `k8s-lab/docs/jvm-flags.md` (FR-059, D3)
- [X] T051 [US2] Harden the runtime stage of `auth-service/Dockerfile` and `order-service/Dockerfile` — minimal base, dedicated non-root uid/gid, exec-form entrypoint so the JVM receives SIGTERM (FR-057, FR-058)
- [X] T052 [US2] Bake the pinned OpenTelemetry Java agent into the runtime stage of `auth-service/Dockerfile` and `order-service/Dockerfile` at `/opt/otel/opentelemetry-javaagent.jar`, left **inert** with no `JAVA_TOOL_OPTIONS` set in the image (D10, contracts/observability-contract.md)
- [X] T053 [US2] Implement `image-build` and `image-publish` in `k8s-lab/scripts/images.sh` with immutable revision-derived tags, refusing or visibly marking a build from a dirty working tree (FR-017, FR-021, spec Edge Cases → uncommitted changes)
- [X] T054 [US2] Implement `image-build-clean` in `k8s-lab/scripts/images.sh` running `docker build --no-cache` for both services — the FR-018 verification, which MUST pass before any deployment task begins (D2 validation obligation)
- [X] T055 [US2] Document the complete image lifecycle from source to running pod in `k8s-lab/docs/images.md` (FR-021)

### Umbrella chart scaffold (FR-084)

- [X] T055a [US2] Scaffold the umbrella chart — `k8s-lab/charts/hydra-lab/Chart.yaml` at a pinned chart version with no sub-charts, and the **base** `k8s-lab/charts/hydra-lab/values.yaml` exposing image, replica count, resources, environment, probes, service, gateway, route, network policy and secret references, plus `templates/_helpers.tpl` as the only permitted template indirection. Every later chart task edits or adds to this scaffold; nothing in `charts/hydra-lab/` may be authored before it exists (FR-084)

### Backing services (FR-051, FR-053, FR-054, D14)

- [X] T056 [P] [US2] Author `k8s-lab/charts/hydra-lab/templates/postgres-statefulset.yaml` using the same pinned `postgres:16-alpine` as `docker-compose.yml`, with a `pg_isready` readiness probe and credentials from a Secret (D14, FR-051)
- [X] T057 [P] [US2] Author `k8s-lab/charts/hydra-lab/templates/redis-statefulset.yaml` using the same pinned `redis:8.8-alpine` as `docker-compose.yml`, with a `redis-cli ping` readiness probe and credentials from a Secret (D14, FR-051)
- [X] T058 [US2] Implement Secret creation for datastore credentials, cache credentials and the RSA signing key in `k8s-lab/scripts/platform.sh`, generated at setup time and never present in source, manifests, charts, images or version control (FR-053, FR-076, FR-085)
- [X] T059 [US2] Author `k8s-lab/charts/hydra-lab/templates/networkpolicy.yaml` with default-deny in `hydra-app` and `hydra-data` plus exactly the permitted edges in contracts/platform-topology.md (FR-054, FR-073)

### Schema migration and fixture (FR-052, FR-052a, D6, D7)

- [X] T060 [US2] Author `k8s-lab/charts/hydra-lab/templates/job-migrate.yaml` as a Helm pre-install/pre-upgrade hook Job running one instance of each service image with `spring.jpa.hibernate.ddl-auto=update` and an exit-after-startup marker, per service, per database (D6, FR-052)
- [X] T061 [US2] Author `k8s-lab/charts/hydra-lab/templates/job-fixture.yaml` applying tenants `acme`, `beta`, `gamma` and their users with pre-computed BCrypt hashes, idempotently via `ON CONFLICT DO NOTHING`, ordered after the migration Job (D7, FR-052a, data-model §6)
- [X] T062 [US2] Add the anti-drift guard to `k8s-lab/charts/hydra-lab/templates/job-fixture.yaml` — the Job ends by performing one real sign-in and fails if the credential is rejected, so a seed that cannot authenticate is a failed seed (D7, spec Edge Cases → fixture drift)

### Deployments and configuration (FR-043..FR-049, FR-061..FR-065)

- [X] T063 [US2] Author `k8s-lab/charts/hydra-lab/templates/configmap-app.yaml` supplying the lab's Spring configuration for mounting at `/config/` via `SPRING_CONFIG_ADDITIONAL_LOCATION`, overriding `refresh-token.cookie.secure=true`, `refresh-token.grace-ttl=PT5S`, `spring.jpa.hibernate.ddl-auto=validate`, the datastore URLs and the actuator health-group exposure (D5, FR-044)
- [X] T064 [US2] Author `k8s-lab/charts/hydra-lab/templates/deployment-auth.yaml` with `SPRING_PROFILES_ACTIVE=test`, 3 replicas, the RSA key Secret mounted at `jwt.private-key-path` so every replica serves identical signing material, and `TENANT_BASE_DOMAINS=localhost` (D5, FR-047, research.md A4)
- [X] T065 [US2] Author `k8s-lab/charts/hydra-lab/templates/deployment-order.yaml` with 3 replicas, `AUTH_SERVICE_URL=http://auth-service.hydra-app.svc.cluster.local:8083` resolved by cluster DNS, and `AUTH_SERVICE_ISSUER=hydra-auth-service` kept as an opaque identifier never turned into a resolvable address (FR-045, FR-046, contracts/platform-topology.md)
- [X] T065a [P] [US2] Author `k8s-lab/charts/hydra-lab/templates/service-auth.yaml` and `k8s-lab/charts/hydra-lab/templates/service-order.yaml` — ClusterIP Services named `auth-service` (port 8083) and `order-service` (port 8082) in `hydra-app`, the selectors matching the Deployment pod labels. These are what T071's HTTPRoute `backendRefs` resolve to, what `order-service` reaches over cluster DNS at `auth-service.hydra-app.svc.cluster.local`, and what T074's Service-existence check asserts (FR-045, contracts/platform-topology.md)
- [X] T066 [US2] Add resource requests **and** limits, startup/readiness/liveness probes on `/actuator/health`, `/actuator/health/readiness` and `/actuator/health/liveness`, and a sized `terminationGracePeriodSeconds` to `k8s-lab/charts/hydra-lab/templates/deployment-auth.yaml` and `deployment-order.yaml` (FR-061, FR-063, contracts/platform-topology.md)
- [X] T067 [US2] Add PodDisruptionBudgets, topology spread across the two workers and `maxUnavailable: 0` / `maxSurge: 1` rolling-update bounds in `k8s-lab/charts/hydra-lab/templates/pdb.yaml` and both Deployment templates (FR-065, SC-009)
- [X] T068 [US2] Add the security context to `k8s-lab/charts/hydra-lab/templates/deployment-auth.yaml` and `deployment-order.yaml` — non-root with explicit uid/gid matching the image, all capabilities dropped, read-only root filesystem with a writable `/tmp` emptyDir, seccomp `RuntimeDefault`, never privileged (FR-058)
- [X] T069 [P] [US2] Author `k8s-lab/charts/hydra-lab/templates/serviceaccounts.yaml` giving each workload a dedicated least-privilege service identity, never cluster-admin (FR-075)
- [X] T070 [US2] Add the virtual-thread / platform-thread switch as a configuration-only value in `k8s-lab/charts/hydra-lab/values.yaml`, with the active mode observable at runtime (FR-049)
- [X] T071 [US2] Author `k8s-lab/charts/hydra-lab/templates/httproute.yaml` routing `/api/v1/auth/**` → the `auth-service` Service and `/api/v1/orders/**` → the `order-service` Service (T065a) by path under a single tenant hostname, attached to the platform-installed Gateway (T039) via `parentRefs`, demonstrating header manipulation and a route-level timeout (FR-028, FR-031)
- [X] T072 [US2] Upgrade `k8s-lab/tests/smoke/gw-test.sh` to assert the gateway carries real application traffic rather than a placeholder response (FR-034)
- [X] T073 [US2] Implement `app-deploy` and `app-status` in `k8s-lab/scripts/app.sh`, ordering migration Job → fixture Job → Deployments so no pod accepts traffic before both Jobs complete, and register the `backing-services`, `migrate`, `fixture` and `apps` checkpoints in `k8s-lab/scripts/setup.sh` (FR-052, FR-052a)

### Suites for US2 (FR-093..FR-095)

- [X] T074 [US2] Implement the smoke suite in `k8s-lab/tests/smoke/run.sh` covering every FR-094 check — cluster API, node readiness, Cilium health, Gateway API installation, GatewayClass, Gateway programming, route acceptance, gateway reachability, Postgres and Redis readiness, application readiness, Service existence, HTTP routing, service-to-service communication, and availability of Prometheus, Grafana, Tempo and Argo CD (reusing `argocd-status` from T134a for the last of these rather than a bare pod-readiness check)
- [X] T074a [US2] Extend `k8s-lab/tests/smoke/run.sh` with two assertions the FR-094 list does not imply: (a) **both** `https://acme.localhost` and `https://beta.localhost` route to the services and resolve to their own tenant rather than `unknown`, with the check recording that no host resolution file was modified and no privilege was elevated (FR-033); and (b) zero `Ingress` objects exist cluster-wide, proving the Gateway API is the primary north-south model rather than merely the preferred one (FR-026)
- [X] T075 [US2] Implement the integration suite in `k8s-lab/tests/integration/run.sh` driving sign in → create order → list orders entirely through the gateway, asserting the JWKS fetch happened over cluster DNS by service name (FR-095, SC-004)
- [X] T076 [US2] Extend `k8s-lab/tests/integration/run.sh` to cover readiness behaviour, network-policy effects, graceful shutdown and error handling, and to assert the Lua rotation scripts load by classpath path through the real image (FR-095, Constitution III guard in plan.md)
- [X] T077 [US2] Add a check to `k8s-lab/tests/smoke/run.sh` asserting neither service is reachable from outside the cluster except through the gateway (US2 Independent Test)

**Checkpoint**: US1 + US2 both work. Hydra's real services run in Kubernetes with real backing services, ClusterIP Services, HTTPRoutes attached to the US1 gateway, and a working end-to-end flow.

---

## Phase 5: User Story 3 - The gateway proves it is transparent (Priority: P3)

**Goal**: Hydra's **existing** edge-conformance suite passes against the lab gateway over TLS with verification enabled and zero assertion changes, and fails against a deliberately hostile gateway configuration naming the violated clause.

**Independent Test**: `make test-edge-conformance` passes; `make test-hostile-edge` fails and names the clause; reverting returns the environment to a passing state.

- [X] T078 [US3] Implement `test-edge-conformance` in `k8s-lab/scripts/edge-conformance.sh`, invoking `mvn -pl integration-tests test -Dgroups=edge-conformance -Dedge.base-url=https://acme.localhost` with `-Djavax.net.ssl.trustStore`, `-DtrustStorePassword` and `-DtrustStoreType=PKCS12` pointing at `k8s-lab/.certs/lab-truststore.p12` (contracts/edge-conformance-reuse.md, FR-096, FR-032b)
- [X] T079 [US3] Add a guard to `k8s-lab/scripts/edge-conformance.sh` that fails the run if certificate verification is disabled or the base URL is not HTTPS — a harness that skips verification cannot test the `Secure` credential clause it exists to test (FR-032, FR-032b)
- [X] T080 [US3] Capture surefire output into `k8s-lab/results/edge-conformance/` as the Edge Conformance Result entity, recording both the lab-gateway and hostile-gateway outcomes (data-model §9)
- [X] T081 [US3] Add a `git diff --exit-code integration-tests/` assertion to `k8s-lab/scripts/edge-conformance.sh` proving zero assertions were modified to accommodate the lab (SC-020, FR-102)
- [X] T082 [US3] Explicitly disable any CORS handling Cilium's Gateway API implementation enables by default, in `k8s-lab/platform/cilium/values.yaml` or the Gateway template, and assert its absence in `k8s-lab/tests/integration/edge-headers.sh` (FR-037)
- [X] T083 [US3] Implement the `X-Forwarded-For` replace-not-append configuration in `k8s-lab/charts/hydra-lab/templates/httproute.yaml` using a `RequestHeaderModifier` `set` operation — route (1) of D12, keeping Gateway API as the primary configuration model (FR-041)
- [X] T084 [US3] If route (1) does not produce replace semantics, implement route (2) in `k8s-lab/platform/cilium/xff-envoy-config.yaml` — a `CiliumClusterwideEnvoyConfig` overriding `use_remote_address`, `xff_num_trusted_hops` and `skip_xff_append` (D12 escape hatch, still no standalone controller)
- [X] T085 [US3] Implement the forged-header test in `k8s-lab/tests/integration/xff-forgery.sh` — send `X-Forwarded-For: 1.2.3.4` from a known client address, exceed the per-address limit, and assert the limiter counted against the address the gateway observed, in 100% of attempts (FR-041, SC-006, D12 validation obligation)
- [X] T086 [US3] If neither D12 route yields replace semantics, record the failure verbatim in `k8s-lab/results/` and carry it into `k8s-lab/docs/edge-finding.md` as evidence against Kubernetes-as-edge — never smoothed over as a lab defect (D12, FR-113, FR-116)
- [X] T087 [US3] Author `k8s-lab/hostile-edge/host-rewrite.yaml` — an `HTTPRoute` `RequestHeaderModifier` rewriting `Host` to the backend service name, violating Clause 1 (contracts/edge-conformance-reuse.md, FR-042)
- [X] T088 [P] [US3] Author `k8s-lab/hostile-edge/gateway-cors.yaml` making the gateway emit its own CORS response headers, violating Clause 2 (FR-042)
- [X] T089 [US3] Implement `test-hostile-edge` in `k8s-lab/scripts/edge-conformance.sh` — one documented command applies `k8s-lab/hostile-edge/`, runs the same suite, asserts it **fails** naming the violated clause, and reverts to a state where the conformance run passes again (FR-042, SC-005)
- [X] T090 [US3] Implement the new-tenant check in `k8s-lab/tests/integration/new-tenant.sh` — add a tenant after the gateway was programmed and assert it works with zero gateway object changes (FR-040, SC-007)
- [X] T091 [US3] Implement the end-to-end `Host` preservation check from the workstation over TLS in `k8s-lab/tests/integration/host-preservation.sh`, asserting tenant resolution yields the tenant rather than `unknown` (FR-036 addendum)

**Checkpoint**: The transparent edge contract has met a real gateway. This is the story that makes the lab worth building for Hydra specifically.

---

## Phase 6: User Story 4 - The platform explains itself (Priority: P4)

**Goal**: Rate, errors and latency per service, JVM and container resource signals, structured logs carrying trace ids, and one external request retrievable as one connected trace across gateway, `order-service` and `auth-service`.

**Independent Test**: Generate a known number of requests; confirm RED, JVM and container panels populate; retrieve one specific request's trace by identifier within 30 seconds.

- [X] T092 [P] [US4] Author `k8s-lab/platform/observability/prometheus-values.yaml` at the pinned chart version, scraping the OTel Collector's Prometheus endpoint plus kube-state-metrics and cAdvisor (FR-077)
- [X] T093 [P] [US4] Author `k8s-lab/platform/observability/otel-collector-values.yaml` receiving OTLP/gRPC on 4317, exporting metrics to a Prometheus endpoint and traces to Tempo (contracts/observability-contract.md)
- [X] T094 [P] [US4] Author `k8s-lab/platform/observability/tempo-values.yaml` as the only trace store, with no parallel tracing UI installed (FR-080a, D10)
- [X] T095 [P] [US4] Author `k8s-lab/platform/observability/grafana-values.yaml` with Prometheus and Tempo datasources — Grafana is the only UI (FR-088, FR-080a)
- [X] T096 [US4] Implement the `observability` checkpoint in `k8s-lab/scripts/platform.sh` installing Prometheus, Grafana, the OTel Collector and Tempo into `hydra-obs`, waiting on readiness with bounded timeouts
- [X] T097 [US4] Activate the agent from the charts in `k8s-lab/charts/hydra-lab/values.yaml` — `JAVA_TOOL_OPTIONS=-javaagent:/opt/otel/opentelemetry-javaagent.jar`, `OTEL_SERVICE_NAME` per service, `OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector.hydra-obs:4317`, `OTEL_TRACES_SAMPLER=always_on` (FR-080b, contracts/observability-contract.md)
- [X] T098 [US4] Configure structured JSON logging carrying `timestamp`, `level`, `service`, `trace_id`, `span_id`, `message` through `k8s-lab/charts/hydra-lab/templates/configmap-app.yaml`, never by editing service resources (FR-082)
- [X] T099 [US4] Author the RED dashboard per service in `k8s-lab/platform/observability/dashboards/red.json`, with 429s plotted separately from 5xx (FR-078, FR-079, D11)
- [X] T100 [US4] Author the resource-tuning dashboard in `k8s-lab/platform/observability/dashboards/runtime.json` placing JVM heap, GC count and duration, container CPU and memory versus limits, replica count, HPA state and restart counts alongside RED on the same board (FR-078)
- [X] T101 [US4] Attempt the Envoy tracing provider attachment in `k8s-lab/platform/cilium/tracing-envoy-config.yaml` via `CiliumClusterwideEnvoyConfig` so the trace begins at the gateway (D13, FR-080)
- [X] T102 [US4] Implement the end-to-end trace check in `k8s-lab/tests/integration/trace-e2e.sh` — issue one request, retrieve one trace by identifier within 30 seconds containing connected gateway, `order-service` and `auth-service` spans (SC-012)
- [X] T103 [US4] Make `k8s-lab/tests/integration/trace-e2e.sh` report `FAIL` with the cause named if the gateway span cannot be attached — a trace beginning at `order-service` is a miss, never a partial pass (D13, FR-116)
- [X] T104 [US4] Add the rate-limit-rejection distinguishability check to `k8s-lab/tests/integration/rate-limit-metrics.sh`, asserting 429s are separable from application errors in both metrics and dashboards (FR-079, SC-017 input)

**Checkpoint**: The platform can be operated rather than guessed about. This is the precondition for US5 and US6.

---

## Phase 7: User Story 5 - Multi-instance correctness under failure (Priority: P5)

**Goal**: Nine controlled drills, each with an executed assertion and a verified restore — including the two properties Hydra's design depends on and has never observed: atomic concurrent credential rotation and cross-replica rate limiting.

**Independent Test**: Run each drill against a healthy environment with an external client issuing continuous requests. Each reports its own verdict, restores to a verified healthy state, and records the observed success rate.

- [X] T105 [US5] Implement the shared drill harness in `k8s-lab/tests/failure/lib/drill.sh` providing trigger → expected observable → assertion → restore → restore verification, where a drill that cannot restore the environment **fails** (data-model §10, FR-097, SC-014)
- [X] T106 [US5] Implement the continuous external client in `k8s-lab/tests/failure/lib/client-load.sh` measuring observed success rate over a window through the gateway
- [X] T107 [P] [US5] Implement `k8s-lab/tests/failure/pod-delete.sh` — delete one application pod, assert a replacement reaches Ready and the client's success rate stays ≥99% over 60 seconds (FR-066, SC-008)
- [X] T108 [P] [US5] Implement `k8s-lab/tests/failure/bad-image.sh` — deploy an invalid image reference, assert `ImagePullBackOff`, assert previously healthy pods keep serving, restore and re-verify (FR-097)
- [X] T109 [US5] Add the readiness toggle gated behind a non-production profile, off by default, to `k8s-lab/charts/hydra-lab/values.yaml` and the Deployment templates (FR-064)
- [X] T110 [US5] Implement `k8s-lab/tests/failure/readiness-fail.sh` — force one replica unready, assert it stops receiving traffic while still running and resumes only on ready (FR-064)
- [X] T111 [P] [US5] Implement `k8s-lab/tests/failure/network-policy.sh` — a real unauthorised workload attempts Postgres, Redis and `auth-service`, each failing 100% of attempts while the authorised equivalents succeed 100%, repeatably (FR-073, SC-013)
- [X] T112 [US5] Implement `k8s-lab/tests/failure/rolling-update.sh` — roll version N → N+1 under continuous client load, asserting new pods ready before old terminate, migration safe under concurrent replica startup, and zero failed requests observed (SC-009)
- [X] T113 [P] [US5] Implement `k8s-lab/tests/failure/cache-down.sh` — remove Redis and assert requests are **rejected** rather than passed through, so the fail-closed limiter posture is observed rather than assumed (FR-056)
- [X] T114 [US5] Implement `k8s-lab/tests/failure/concurrent-rotation.sh` — present one renewal credential concurrently to different `auth-service` replicas across ≥100 attempts via `xargs -P` over `curl`, asserting exactly one rotation succeeds and zero credentials are double-honoured (FR-067, SC-010, D17)
- [X] T115 [US5] Implement `k8s-lab/tests/failure/cross-replica-limit.sh` — assert a per-address limit of N admits at most N per window across all replicas combined, not N per replica (FR-068, SC-011)
- [X] T116 [US5] Add a replica-count precondition to `k8s-lab/tests/failure/concurrent-rotation.sh` and `cross-replica-limit.sh` refusing to report a verdict against a single-replica deployment (FR-069)
- [X] T117 [P] [US5] Implement `k8s-lab/tests/failure/node-stop.sh` — stop or isolate a worker node, report the resulting scheduling and availability behaviour, and reference how this differs from a real cloud node failure (FR-097, FR-112)
- [X] T118 [US5] Implement `test-failure` plus the individually runnable `test-pod-failure`, `test-netpol` and `test-rolling-update` entry points in `k8s-lab/tests/failure/run.sh` and wire them in `k8s-lab/Makefile` (FR-093, FR-097)

**Checkpoint**: The constitution's non-negotiable atomicity principle is now an observation rather than an argument.

---

## Phase 8: User Story 6 - Load, scale and measure honestly (Priority: P6)

**Goal**: Replica count responds to real observed metrics under load through the actual gateway, and a repeatable benchmark compares both concurrency models on endpoints that block on Postgres and Redis, reporting its own limitations.

**Independent Test**: Run the load test and observe replica count respond to real metrics. Run the benchmark in both modes and confirm the report contains every declared field and no unqualified conclusion.

- [X] T119 [US6] Author `k8s-lab/charts/hydra-lab/templates/hpa.yaml` for both services driven by real observed metrics, with no simulated or hard-coded replica changes (FR-070)
- [X] T120 [US6] Implement `load-test` in `k8s-lab/tests/perf/load-test.sh` driving traffic through the actual gateway (FR-071)
- [X] T121 [US6] Implement `test-scaling` in `k8s-lab/tests/perf/scaling.sh` asserting replica count rises above baseline under sustained load and returns toward it afterwards (SC-016)
- [X] T122 [US6] Add the constraint-reporting path to `k8s-lab/tests/perf/scaling.sh` — when workstation resources prevent scaling, report the constraint explicitly and distinguish "did not scale" from "could not observe"; never a false PASS (FR-072, SC-016)
- [X] T123 [US6] Implement `bench` in `k8s-lab/tests/perf/bench.sh` running the same workload in both concurrency modes against endpoints that block on Postgres and Redis (FR-103, FR-104)
- [X] T124 [US6] Hold the garbage-collector selection constant across the concurrency-mode comparison in `k8s-lab/tests/perf/bench.sh`, so no published figure varies two settings at once (FR-104a)
- [X] T125 [US6] Implement metric collection in `k8s-lab/tests/perf/bench.sh` for RPS, throughput, p50/p95/p99 latency, error rate, CPU, memory, JVM heap, GC behaviour, container memory and replica count, reporting throttled 429s separately from errors (FR-105, D11)
- [X] T126 [US6] Implement report generation to `k8s-lab/results/benchmark/<timestamp>/report.md` stating configuration, hardware, load profile, results, observations and limitations, including the OTel agent's own overhead, and reporting repeated runs with observed variance rather than a single unqualified figure (FR-106, SC-017, data-model §12)
- [X] T127 [US6] Add a conclusion guard to `k8s-lab/tests/perf/bench.sh` and the report template — no claim the measurements do not support, no generalisation from a workstation result to production, and never a claim that virtual threads inherently reduce memory consumption (FR-107, FR-050)
- [X] T128 [US6] Run the separate ZGC-versus-runtime-default experiment via `k8s-lab/tests/perf/gc-comparison.sh` and publish it in `k8s-lab/docs/jvm-flags.md` as a recommendation feeding a **separate** decision this feature does not make (FR-059a, D3)

**Checkpoint**: Scaling and concurrency claims in this repository now have measurements behind them.

---

## Phase 9: User Story 7 - Declarative delivery and a way to look inside (Priority: P7)

**Goal**: A tracked change converges without a deploy command, and three consoles are each reachable by their own documented access operation.

**Independent Test**: Commit a change to a tracked manifest, observe Argo CD detect it and the cluster converge; open each console by its documented command and inspect a live pod's logs.

- [X] T129 [US7] Author `k8s-lab/platform/argocd/values.yaml` at the pinned chart version and implement the `argocd` checkpoint in `k8s-lab/scripts/platform.sh` (FR-083, D15)
- [X] T130 [US7] Author the root Application in `k8s-lab/platform/argocd/root-application.yaml` reconciling the `hydra-lab` umbrella chart from `k8s-lab/gitops/` (FR-083)
- [X] T131 [US7] Populate `k8s-lab/gitops/` as the tracked desired state, referencing Secret **names** created out of band by setup and containing no secret value (FR-085, D15)
- [X] T132 [US7] Implement the delivery-loop demonstration in `k8s-lab/tests/integration/gitops-converge.sh` — change a tracked non-secret value (replica count), assert Argo CD reports the deviation and the cluster converges with no deploy command (FR-083)
- [X] T133 [P] [US7] Author `k8s-lab/platform/headlamp/values.yaml` and implement the `console` checkpoint in `k8s-lab/scripts/platform.sh` installing Headlamp in-cluster (FR-087, D16)
- [X] T134 [US7] Implement `console-cluster`, `console-metrics` and `console-delivery` in `k8s-lab/scripts/consoles.sh`, each by a deterministic documented mechanism, with traces reached through Grafana and no fourth console introduced (FR-088)
- [X] T134a [US7] Implement `argocd-status` in `k8s-lab/scripts/consoles.sh` reporting, per Argo CD Application, its sync status (`Synced` / `OutOfSync`) and health status (`Healthy` / `Progressing` / `Degraded` / `Missing`), plus the last reconciliation time — read from the Application resources with a bounded wait, never from the UI. Exits non-zero when any Application is `OutOfSync` or not `Healthy`, so the delivery controller cannot report green without an executed check. This is FR-086's *status* half; T134's `console-delivery` is its *access* half (FR-086, FR-098)
- [X] T135 [P] [US7] Implement `make logs` in `k8s-lab/scripts/consoles.sh` returning structured logs for a named workload (FR-089)
- [X] T136 [US7] Implement `make debug` in `k8s-lab/scripts/debug.sh` as the guided diagnosis entry point, and add a no-committed-secrets assertion over `k8s-lab/gitops/` to `k8s-lab/tests/smoke/run.sh` (FR-085, FR-089)

**Checkpoint**: The lab is a sustainable practice rather than a sequence of shell commands.

---

## Phase 10: User Story 8 - Documentation, production mapping and a settled edge decision (Priority: P8)

**Goal**: A reader unfamiliar with the project can set up, break, diagnose and recover the environment from documentation alone, and the Edge Finding records what the lab demonstrated about Kubernetes as Hydra's edge.

**Independent Test**: Give the documentation to an engineer unfamiliar with the project and ask them to set up the environment, break one component, diagnose it and recover it, using documentation alone and without reading any manifest.

- [X] T137 [US8] Write `k8s-lab/README.md` — what the project is, how to install prerequisites, how to run the environment, how to run tests and benchmarks, how to access the consoles, how to debug failures (FR-110)
- [X] T138 [US8] Write `k8s-lab/docs/technology-choices.md` giving the rationale for each chosen technology and for each deliberate exclusion — no standalone gateway controller, no legacy ingress as the primary API, no service mesh, no Bitnami charts, no Jaeger, no Loki (FR-110, D4, D10, D14)
- [X] T139 [P] [US8] Write the per-component pages under `k8s-lab/docs/components/` — one per major component, each covering what it is, why it exists, what problem it solves, how it works, how to inspect it, how to break it, how to recover it, and its production equivalent (FR-111, SC-021)
- [X] T140 [P] [US8] Write `k8s-lab/docs/networking.md` documenting network provider, kube-proxy replacement, kernel datapath, service and pod networking, network policy, the L7 proxy and its relationship to the Gateway (FR-025)
- [X] T141 [P] [US8] Write `k8s-lab/docs/observability.md` explaining traces, spans, context propagation, sampling (and that `always_on` is a lab setting, never a production recommendation), trace identifiers and log/trace correlation (FR-081, FR-080b)
- [X] T142 [P] [US8] Write `k8s-lab/docs/memory.md` accounting for heap, class metadata, code cache, direct buffers, native memory, thread-related memory and runtime overhead, and explicitly not equating the container memory limit with maximum heap size without a stated reason (FR-060)
- [X] T143 [P] [US8] Write `k8s-lab/docs/concurrency.md` on platform threads, virtual threads, blocking I/O, scheduler behaviour, pinning, daemon-thread behaviour and limitations — including when virtual threads do and do not help, and never claiming they inherently reduce memory consumption (FR-050)
- [X] T144 [US8] Write `k8s-lab/docs/production-mapping.md` mapping local cluster → managed Kubernetes, local registry → managed registry, in-cluster Postgres/Redis → managed equivalents, hostPath storage → network-attached storage, Kubernetes Secrets → a managed secret store, stating which differences do not transfer and never claiming the local cluster behaves identically to a managed cloud cluster (FR-112, FR-055)
- [X] T145 [US8] Write the coverage-gap and divergence record in `k8s-lab/docs/known-gaps.md` — first-boot bootstrap deliberately bypassed and neither proven safe nor proven broken (FR-052b); Hibernate-authored DDL through a Job with Liquibase unadopted and the `spring-boot-liquibase` upgrade hazard (D6, research.md A3); the services running under a profile named `test` as a naming accident of this repository (D5); agent-only instrumentation's ceiling on domain-intent signals; production log-storage options documented rather than installed (FR-082)
- [X] T145a [P] [US8] Write `k8s-lab/docs/resource-tuning.md` defining the measurement-based path for revising the initial resource requests and limits — which Grafana panels to read (T100), how to drive representative load (T120) and how to read the benchmark report (T126), how to tell a genuine headroom signal from noise across repeated runs, and the explicit rule that **lowering a limit MUST be supported by measurement and MUST NOT be justified by the choice of concurrency model**. States plainly that the values shipped in `values.yaml` are starting points, not measured settings (FR-062)
- [X] T146 [US8] Write `k8s-lab/docs/edge-finding.md` stating what the lab demonstrated about Kubernetes as Hydra's edge, what it could not demonstrate locally, and what would still require verification in a real cloud environment — framed as evidence toward the constitution's open question, not as a unilateral resolution, and readable standalone (FR-113, SC-023, data-model §13)
- [X] T147 [US8] Verify every document is written in English and add the check to `k8s-lab/tests/smoke/run.sh` (FR-114)

**Checkpoint**: The lab's actual output — understanding and a decision — exists in writing.

---

## Phase 11: Polish & Cross-Cutting Concerns

**Purpose**: Aggregate verdicts, reduced-footprint mode, reproducibility, and the executed validation FR-116 requires before this feature may be called complete.

- [X] T148 Implement `make test` in `k8s-lab/scripts/test.sh` as the fast validation path — smoke, integration, edge conformance and the relevant failure tests, in that order, returning non-zero if any required check fails. It MUST NOT destroy or recreate the cluster, and MUST NOT run `validate-full` (FR-099)
- [X] T148a Implement `make validate` in `k8s-lab/scripts/validate.sh` as the verdict aggregator over the suites `make test` runs — a per-component `PASS`/`FAIL`/`SKIPPED-BY-CONFIGURATION`/`BLOCKED` line plus one overall verdict and a single exit code. `validate` reports; `test` executes (FR-101, SC-015, data-model §11)
- [X] T149 Implement `make validate-full` in `k8s-lab/scripts/validate.sh` — destroy → remove local state → recreate → install platform → deploy applications → wait for readiness → smoke + integration + conformance, never running as part of `make test` (FR-100)
- [X] T150 Add seeded-component-failure cases to `k8s-lab/tests/smoke/validate-seeded-failures.sh` proving `make test` and `make validate` each return non-zero for 100% of them and never reports a component passing without an executed check (SC-015)
- [X] T151 Author `k8s-lab/charts/hydra-lab/values-reduced.yaml` — replicas 2 (never 1, since FR-069 needs real multi-instance), Tempo and Hubble UI disabled, trimmed resource requests, with workloads, Deployments, Services, Gateway API, Cilium, network policy, Postgres, Redis and autoscaling all retained (FR-091, D18)
- [X] T152 Implement `setup-reduced` in `k8s-lab/scripts/setup.sh` printing which components were disabled and which scenarios are consequently unavailable, and make `make test` report SC-012 as `SKIPPED-BY-CONFIGURATION` in that mode — never `PASS` (FR-091, D18)
- [X] T153 Verify SC-018 by seeding one fault from each class — scheduling, image, readiness, routing, DNS, network policy, autoscaling, datastore, cache — and confirming `make dump` output alone lets a reader name the failing component; extend `k8s-lab/scripts/dump.sh` wherever it does not
- [X] T154 Verify SC-019 by executing every target listed in contracts/developer-interface.md against a healthy environment and confirming each exists, is documented and exits zero; record the results in `k8s-lab/results/`
- [X] T155 Run Hydra's existing test suites unchanged via `mvn -f pom.xml test` and confirm they pass with zero assertions modified, recording the output in `k8s-lab/results/existing-suites/` (FR-102, SC-020)
- [X] T156 Execute `make validate-full` three consecutive times with no manual intervention between passes and record the outcomes in `k8s-lab/results/reproducibility/` (FR-108, SC-003)
- [X] T157 Time a full clean-machine run from `make doctor` to a validated environment and record the wall-clock result against the 45-minute budget in `k8s-lab/results/setup-timing.md` (SC-001)
- [X] T158 Walk `specs/005-k8s-production-lab/quickstart.md` end to end against the built lab, correcting any step that does not work as written
- [X] T159 Record the executed run results in `k8s-lab/results/` and confirm no requirement is reported satisfied on the strength of generated files alone (FR-116)

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies — start immediately
- **Foundational (Phase 2)**: Depends on Setup — **BLOCKS all user stories**
- **US1 (Phase 3)**: Depends on Foundational. Blocks every later story — nothing can run without a cluster
- **US2 (Phase 4)**: Depends on US1
- **US3 (Phase 5)**: Depends on US2 (there must be a real service to route to)
- **US4 (Phase 6)**: Depends on US2 (the agent JAR is baked in by T052)
- **US5 (Phase 7)**: Depends on US2; the netpol drill needs T059, the trace-backed diagnosis is easier after US4 but not blocked by it
- **US6 (Phase 8)**: Depends on US2 and US4 (autoscaling needs observed metrics; the benchmark needs the resource dashboards)
- **US7 (Phase 9)**: Depends on US2 (there must be desired state to reconcile)
- **US8 (Phase 10)**: Depends on the stories it documents; T146 in particular depends on US3 (T085/T086) and US4 (T103)
- **Polish (Phase 11)**: Depends on all desired stories

### Critical cross-story dependencies

| Blocker | Blocks | Why |
|---|---|---|
| T054 (`image-build-clean`) | T073 and everything downstream | D2 validation obligation — the clean-state build must pass before any deployment task begins |
| T045 (ZGenerational probe) | T049 | Whether removal is a cleanup or a live bug fix changes the commit message and the docs |
| T052 (agent baked in) | T097 and all of US4 | Nothing is observable without it |
| T035–T037 (TLS material) | T078 | The conformance suite cannot run over TLS without the truststore |
| T083/T084 (XFF) | T085, T086 | The check is meaningless before the configuration exists |
| T025 (`namespaces` checkpoint) | T037, T058, T096 | Every Secret and every namespaced install needs its namespace to already exist; the chart runs last and cannot supply it |
| T039, T040 (`gateway` checkpoint) | T041, T042, T071 | US1 must reach a `Programmed` Gateway without the chart; US2's HTTPRoutes attach to it by `parentRefs` |
| T055a (chart scaffold) | T056–T071, T151 | Nothing under `charts/hydra-lab/` may be authored before `Chart.yaml` and the base `values.yaml` exist |
| T065a (ClusterIP Services) | T071, T074, T075 | The HTTPRoute `backendRefs` and the cluster-DNS JWKS fetch both resolve to these Services |
| T059 (NetworkPolicy) | T111 | A policy that has never been tested against a real caller is a YAML file, not a control |
| T085, T103 | T146 (Edge Finding) | The two at-risk requirements (D12, D13) are the Finding's substance |

### Parallel Opportunities

- **Phase 1**: T002, T003, T005 in parallel
- **Phase 2**: T007, T008, T009 in parallel; T010–T012 follow
- **US1**: T016, T017, T018 in parallel (independent doctor checks); T029, T030 in parallel; T033, T041 in parallel
- **US2**: T056, T057 in parallel (Postgres and Redis templates), both after T055a; T065a parallel with T066–T068; T069 parallel with the Deployment work
- **US3**: T087, T088 in parallel (the two hostile-edge manifests)
- **US4**: T092, T093, T094, T095 all in parallel (four independent values files)
- **US5**: T107, T108, T111, T113, T117 in parallel (independent drill scripts)
- **US8**: T139, T140, T141, T142, T143, T145a in parallel (independent documents)

### Within Each User Story

Chart scaffold before chart templates (T055a gates all of `charts/hydra-lab/`); namespaces before anything namespaced (T025); configuration and manifests before scripts; scripts before the suites that call them; every suite's assertion written against an executed check, never an asserted one.

---

## Parallel Example: User Story 4

```bash
# Four independent platform values files, no shared file:
Task: "Author k8s-lab/platform/observability/prometheus-values.yaml"
Task: "Author k8s-lab/platform/observability/otel-collector-values.yaml"
Task: "Author k8s-lab/platform/observability/tempo-values.yaml"
Task: "Author k8s-lab/platform/observability/grafana-values.yaml"
```

## Parallel Example: User Story 5

```bash
# Five independent drill scripts, each its own file:
Task: "Implement k8s-lab/tests/failure/pod-delete.sh"
Task: "Implement k8s-lab/tests/failure/bad-image.sh"
Task: "Implement k8s-lab/tests/failure/network-policy.sh"
Task: "Implement k8s-lab/tests/failure/cache-down.sh"
Task: "Implement k8s-lab/tests/failure/node-stop.sh"
```

---

## Implementation Strategy

### MVP First (User Story 1 only)

1. Phase 1: Setup
2. Phase 2: Foundational (blocks everything)
3. Phase 3: US1
4. **STOP and VALIDATE**: `make doctor`, `make setup`, `make cluster-health`, `make net-test`, `make gw-status`, `make gw-test` on a clean machine — all pass with no umbrella chart installed
5. A reproducible three-node cluster with Cilium, a registry, lab TLS and a programmed gateway is a genuine deliverable on its own

### Incremental Delivery

1. Setup + Foundational → substrate ready
2. US1 → reproducible platform (**MVP**)
3. US2 → Hydra's real services running, end-to-end flow through the gateway
4. US3 → the transparent edge contract meets a real gateway (**the story that justifies the feature for Hydra**)
5. US4 → the platform explains itself
6. US5 → multi-instance correctness observed rather than argued
7. US6 → scaling and concurrency measured rather than assumed
8. US7 → declarative delivery and consoles
9. US8 → documentation, production mapping, Edge Finding
10. Polish → aggregate verdicts, reduced mode, three-pass reproducibility, executed validation

### Honest-failure obligations that override "make it green"

Three requirements are expected to be genuinely at risk, and each has a defined failure report rather than a workaround:

- **T085/T086 (FR-041, SC-006)** — if Cilium's Gateway API cannot be made to replace `X-Forwarded-For`, that is a finding about Kubernetes-as-edge and belongs in the Edge Finding, not a lab defect to paper over.
- **T103 (SC-012, FR-080)** — if the gateway span cannot be attached, SC-012 is reported `FAIL` with the cause named. A trace starting at `order-service` is a miss.
- **T122 (FR-072, SC-016)** — if the workstation cannot scale, the scaling test reports the constraint. Never a false PASS.

FR-116 governs all three: this feature may not be reported complete on the strength of generated files.

---

## Notes

- `[P]` tasks touch different files and depend on nothing incomplete
- `[USn]` maps each task to its story for traceability
- Every new file is `git add`-ed as it is created
- Commit after each task or logical group; commit messages in English (FR-114)
- Stop at any checkpoint to validate a story independently
