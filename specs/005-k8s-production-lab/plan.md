# Implementation Plan: Kubernetes Production Lab

**Branch**: `005-k8s-production-lab` | **Date**: 2026-08-18 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/005-k8s-production-lab/spec.md`

## Summary

Build a reproducible, single-workstation Kubernetes laboratory that runs Hydra's **real** `auth-service` and `order-service` behind a Gateway API edge, and use it to produce two outputs: production-grade operational knowledge, and evidence toward the constitution's open question of whether Hydra's edge is Kubernetes-based or a plain proxy plus compose.

Technical approach: a `kind` multi-node cluster with the default CNI disabled, **Cilium** as the single networking layer (CNI + kube-proxy replacement + NetworkPolicy + Hubble + Gateway API implementation whose data plane is Envoy — no standalone gateway controller), a local registry, Postgres and Redis as in-cluster StatefulSets, Helm charts reconciled by Argo CD from a local git remote, and Prometheus + Grafana + OpenTelemetry Collector + Tempo for observability. All service and runtime telemetry comes from an OpenTelemetry Java agent baked into the image and enabled by `JAVA_TOOL_OPTIONS` — no source change and no new dependency in either service. The gateway terminates TLS with a lab-local CA over `*.localhost` tenant hostnames, and the **existing** edge-conformance suite is pointed at it with `-Dedge.base-url` plus a truststore system property — configuration only, zero assertion changes.

Everything is driven from one `make` entry point in `k8s-lab/`, every stage is a checkpoint that validates and stops on failure, and no component is ever reported healthy without an executed check behind it.

## Technical Context

**Language/Version**: Java 25 (mandated, unchanged) for the services; Bash 3.2+ (macOS default) for lab tooling and infrastructure tests; YAML for manifests and Helm charts

**Primary Dependencies**: Spring Boot 4.1 (services, unchanged); kind, Cilium, Kubernetes Gateway API CRDs, Helm, Argo CD, Prometheus, Grafana, OpenTelemetry Collector + OpenTelemetry Java agent, Tempo, Headlamp, PostgreSQL, Redis. Exact pinned releases live in the version matrix (`k8s-lab/versions.env`), which is the single source both docs and scripts read.

**Storage**: PostgreSQL (in-cluster StatefulSet, one database per service) and Redis (in-cluster StatefulSet) — the services' real dependencies, not stubs. Local `hostPath`-backed PVs provided by kind's default storage class.

**Testing**: Bash suites (`smoke`, `integration`, `failure`, `perf`) executing `kubectl`/`curl`/`jq` against the actual running cluster — Kubernetes is never mocked. The one Java-side suite is Hydra's **existing** `edge-conformance` tagged suite, reused by configuration. No new Maven module joins the reactor.

**Target Platform**: macOS (arm64, confirmed on this workstation: Docker 29.4.0, Corretto 25.0.4) and Linux x86_64/arm64. Native Windows is not targeted and the documentation says so.

**Project Type**: Infrastructure/platform lab — a new top-level `k8s-lab/` tree plus surgical changes to the two service `Dockerfile`s. No application source is modified.

**Performance Goals**: Not a throughput target — a measurement obligation. The benchmark reports RPS, throughput, p50/p95/p99, error rate (throttled counted separately), CPU, memory, heap, GC behaviour, container memory and replica count, with the GC selection held constant across concurrency-mode comparisons, and states its own limitations rather than generalising.

**Constraints**: Full setup to validated environment under 45 min (SC-001); TLS at the gateway is blocking with no plain-HTTP fallback (FR-032); tenant hostnames must resolve with no hosts-file edit and no elevated privileges (FR-033); no runtime behaviour change to either service (FR-044); existing suites pass unchanged (FR-102); reduced-footprint mode for constrained workstations (FR-091).

**Scale/Scope**: 1 control-plane + 2 worker nodes; 5 namespaces; 2 Hydra services at 3 replicas each; 2 backing services; ~116 functional requirements; 23 success criteria; 9 failure drills.

## Constitution Check

*GATE: evaluated before Phase 0 and re-evaluated after Phase 1 design.*

| Principle | Verdict | Basis |
|---|---|---|
| **I. Framework-Free Shared Core** | PASS | `infra-shared` is not touched. The lab adds no Java code anywhere, so no dependency can reach it. |
| **II. Dedicated Modules for Cross-Cutting Concerns** | PASS (N/A) | No new cross-cutting Java concern is introduced. Observability — the one concern being added — is deliberately supplied *outside* the build by an attached agent, which is the strongest possible form of this principle: the concern is not folded into any module because it is not in any module. |
| **III. Load-Path-Authoritative Paths** | PASS, with an enforced guard | The rotation Lua scripts are loaded by classpath path (`lua/<name>.lua`). The image rebuild copies whole module trees and must not flatten or relocate resources; the integration suite's sign-in → refresh path executes that load site against the real image, so a broken classpath layout fails a test rather than lurking. |
| **IV. Atomic Distributed State Mutations (NON-NEGOTIABLE)** | PASS, strengthened | The lab changes no rotation logic. FR-067/SC-010 make this principle *observed* for the first time — one credential presented concurrently to multiple real replicas must yield exactly one successful rotation across ≥100 attempts. Until now this has been an argument; the lab turns it into a measurement. |
| **V. Audit Before Building** | PASS | The audit ran before this plan and its findings are recorded in [research.md](./research.md) §A (missing Maven wrapper, missing `browser-edge-starter` in both image builds, Liquibase present but never executed, `@Profile`-coupled `KeyProvider` beans, obsolete JVM flag). The open edge question is explicitly surfaced as this feature's deliverable (FR-113) rather than silently assumed. |
| **Technology Constraints** | PASS | Java 25 and Spring Boot 4.1 are preserved exactly; Bucket4j/Lettuce/Redis paths are exercised, not replaced. The constraint entry "Kubernetes + Envoy Gateway is the current target; docker-compose is a candidate alternative under active evaluation" is precisely what this feature gathers evidence on — and the Edge Finding is framed as evidence, not as a unilateral resolution. |

**Gate result: PASS — no violations to justify.** Complexity Tracking below is therefore empty.

### Post-Phase 1 re-evaluation

Re-checked after the design artifacts were written. **Still PASS, and two verdicts got stronger rather than weaker:**

- **Principle I/II** — the design ended up adding *zero* Java code and zero `pom.xml` changes. The only files touched outside `k8s-lab/` are two `Dockerfile`s. There is no path by which a framework dependency could reach `infra-shared`, because nothing enters the build at all.
- **Principle V** — the design surfaced two blockers the spec did not know about (research.md A1: the Maven wrapper is not in the repository; A4: `KeyProvider` beans are bound to specific profile names). Both were found by reading source rather than trusting documentation, and both changed the design — A1 replaced the builder stage, A4 constrained the deployment to an existing profile. This is the principle working as intended.
- **Principle III** — the guard is now concrete: the integration flow executes the `lua/*.lua` load site through the real image, so a flattened classpath fails a test.

One constraint deserves explicit statement rather than silent handling: the constitution lists Testcontainers as the testing approach. The lab's infrastructure suites run against a real cluster instead. This is not a deviation from the principle behind that constraint — "real dependencies, not mocks" — it is a stricter form of it. The existing Testcontainers suites continue to run unchanged (FR-102).

## Project Structure

### Documentation (this feature)

```text
specs/005-k8s-production-lab/
├── plan.md              # This file
├── research.md          # Phase 0 output — audit findings + 18 pinned decisions
├── data-model.md        # Phase 1 output — the 13 spec entities as concrete artifacts
├── quickstart.md        # Phase 1 output — runnable validation guide
├── contracts/
│   ├── developer-interface.md    # The `make` surface (FR-089), every target's contract
│   ├── platform-topology.md      # Namespaces, workloads, network policy, exposure path
│   ├── observability-contract.md # Metric names, log fields, trace shape, dashboards
│   └── edge-conformance-reuse.md # How the existing suite is pointed at the lab, unmodified
├── checklists/
└── tasks.md             # Phase 2 output (/speckit-tasks — NOT created here)
```

### Source Code (repository root)

```text
k8s-lab/                              # NEW — everything the lab owns lives here
├── Makefile                          # The single developer entry point (FR-089)
├── versions.env                      # The version matrix, machine-readable (FR-005..007)
├── scripts/
│   ├── doctor.sh                     # FR-001..004 host diagnostic, installs nothing
│   ├── lib/{log,checkpoint,wait,assert}.sh   # condition-based waits only (FR-015)
│   ├── cluster.sh                    # create/delete/recreate/status/health
│   ├── registry.sh                   # local registry + kind wiring (FR-016, FR-019)
│   ├── certs.sh                      # idempotent CA + wildcard cert + truststore (FR-032a/b)
│   ├── images.sh                     # build/publish, revision-derived tags (FR-017, FR-018)
│   ├── platform.sh                   # Cilium → Gateway API → observability → Argo CD → console
│   ├── app.sh                        # migrate job → fixture job → deploy → status
│   ├── consoles.sh                   # Grafana / Argo CD / Headlamp access (FR-088)
│   ├── dump.sh                       # diagnostic dump (FR-090, SC-018)
│   └── cleanup.sh                    # FR-109
├── cluster/kind-cluster.yaml         # 1 control-plane + 2 workers, default CNI disabled
├── platform/
│   ├── cilium/values.yaml            # kube-proxy replacement, L7, Gateway API, policy, Hubble
│   ├── gateway-api/                  # pinned standard-channel CRDs
│   ├── observability/                # Prometheus, Grafana, OTel Collector, Tempo values
│   ├── argocd/                       # Argo CD values + root Application
│   └── headlamp/                     # cluster console values
├── charts/
│   └── hydra-lab/                    # umbrella chart: auth, order, postgres, redis, gateway,
│       ├── values.yaml               #   routes, policies, secrets refs, HPA, PDB, probes
│       ├── values-reduced.yaml       # FR-091 reduced-footprint overlay
│       └── templates/
├── gitops/                           # the tracked desired state Argo CD reconciles (FR-083)
├── tests/
│   ├── smoke/        # FR-094
│   ├── integration/  # FR-095 — sign-in → create order → list orders, through the gateway
│   ├── failure/      # FR-097 — nine drills, each with a verified restore
│   └── perf/         # FR-103..107 — load, scaling, benchmark
├── hostile-edge/                     # FR-042 deliberately contract-violating gateway config
└── docs/                             # FR-110..113 incl. production-mapping.md, edge-finding.md

auth-service/Dockerfile               # MODIFIED — see research.md D2/D3
order-service/Dockerfile              # MODIFIED — see research.md D2/D3
```

**Structure Decision**: A single new top-level `k8s-lab/` tree holds every artifact the lab owns, and the only files touched outside it are the two service `Dockerfile`s. This keeps the blast radius on Hydra's application code at exactly zero — no Maven module is added, no `pom.xml` changes, no service source or resource is edited — which is what makes FR-044 and SC-020 verifiable by inspection rather than by argument. The service configuration the lab needs is supplied entirely at deploy time (env vars plus a ConfigMap mounted via `SPRING_CONFIG_ADDITIONAL_LOCATION`), so no `application-*.yml` is added to either service's resources either.

## Complexity Tracking

No Constitution Check violations. Nothing to justify.
