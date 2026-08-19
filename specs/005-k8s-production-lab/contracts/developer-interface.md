# Contract: Developer Interface

**Feature**: `005-k8s-production-lab` | Satisfies: FR-089, FR-090, FR-091, FR-098, FR-101, SC-019

The lab exposes exactly one entry point: `make` from `k8s-lab/`. Every operation below MUST exist, MUST be documented, and MUST exit zero against a healthy environment (SC-019). Every operation that checks anything MUST exit non-zero when any required check fails (FR-098) — no target may report a component as passing without an executed check behind it.

## Conventions binding on every target

| Rule | Requirement |
|---|---|
| Exit code | Zero on success only. Any failed required check → non-zero |
| Waiting | Condition-based with a bounded timeout. A fixed-duration sleep is never a readiness signal (FR-015) |
| Versions | Read from `versions.env`. No target hard-codes a version (SC-022) |
| Idempotency | Re-running a `create`/`install` target against existing state converges; it does not fail and does not duplicate |
| Output | One line per check with an explicit verdict, then a summary. Silence is not success |
| Secrets | No target prints secret values, and no target writes one to the tracked tree |

## Targets

### Diagnostics and setup

| Target | Contract |
|---|---|
| `make doctor` | Runs every FR-001 check. Installs nothing (FR-003). One line per check, then `ENVIRONMENT READY` / `NOT READY`. Non-zero if any required check fails |
| `make setup` | Runs all checkpoints in order: cluster → cilium → gateway-api → registry → certs → backing-services → observability → argocd → console → migrate → fixture → apps. Stops at the first failure with diagnostic context (FR-014) |
| `make setup-reduced` | As `setup` with `values-reduced.yaml`. MUST print which components were disabled and which scenarios are consequently unavailable (FR-091, D18) |
| `make cleanup` | Removes the cluster, the registry and lab-created local state, leaving the first-run path working (FR-109) |

### Cluster, registry, networking, gateway

| Target | Contract |
|---|---|
| `make cluster-create` | 1 control-plane + 2 workers (count configurable). Verifies every node reaches Ready before reporting success (FR-013). No workload in the default namespace |
| `make cluster-delete` / `cluster-recreate` | — |
| `make cluster-status` / `cluster-health` | Distinct: status reports what exists, health reports whether it works |
| `make registry-create` / `registry-status` | Local registry wired to the cluster. Addressing differences between workstation, registry, node containers and the in-node runtime are reconciled explicitly (FR-019) |
| `make net-status` | Cilium health on every node |
| `make net-test` | Real pod-to-pod **and** pod-to-service traffic (FR-024). Not a config inspection |
| `make gw-status` | GatewayClass exists, Gateway `Programmed`, routes `Accepted` |
| `make gw-test` | A request from the workstation to the documented local address receives a response produced **inside** the cluster (FR-034) — not a placeholder |

### Images and applications

| Target | Contract |
|---|---|
| `make image-build` | Builds both services. Prints the toolchain that performed the build (FR-004). Tags are revision-derived and immutable (FR-017) |
| `make image-build-clean` | `--no-cache` from a clean state — the FR-018 verification |
| `make image-publish` | Publishes to the lab registry. The cluster pulls without contacting a public image host |
| `make app-deploy` | Migration Job → fixture Job → Deployments. No pod accepts traffic before both Jobs complete (FR-052, FR-052a) |
| `make app-status` | Per-workload readiness, replica counts, restart counts |

### Testing

| Target | Contract |
|---|---|
| `make test` | Smoke + integration + edge conformance + relevant failure tests. MUST NOT destroy or recreate the cluster (FR-099) |
| `make test-smoke` | Every FR-094 check |
| `make test-integration` | Sign in → create order → list orders, entirely through the gateway (FR-095) |
| `make test-failure` | All nine drills, each restoring to a verified healthy state (FR-097) |
| `make test-pod-failure` / `test-netpol` / `test-scaling` / `test-rolling-update` | Individually runnable drills (FR-093) |
| `make test-edge-conformance` | Runs Hydra's **existing** suite with `-Dedge.base-url` + truststore properties. Zero assertion changes (FR-096, SC-020) |
| `make test-hostile-edge` | Applies the hostile configuration; the same suite MUST **fail**, naming the violated clause (FR-042) |
| `make validate` | Aggregates into a per-component verdict plus one overall verdict and exit code (FR-101, SC-015) |
| `make validate-full` | Destroy → recreate → install → deploy → smoke + integration + conformance. Never part of `make test` (FR-100) |

### Performance

| Target | Contract |
|---|---|
| `make load-test` | Drives traffic through the actual gateway (FR-071) |
| `make bench` | Both concurrency modes, GC held constant (FR-104a), endpoints blocking on Postgres and Redis (FR-104). Produces the full report (FR-105, FR-106) |

### Inspection

| Target | Contract |
|---|---|
| `make dump` | Nodes, pods, services, endpoints, gateways, routes, network policies, events, deployments, autoscalers, plus Cilium diagnostics — enough to name the failing component for any seeded fault class without further commands (FR-090, SC-018) |
| `make logs` | Structured logs for a named workload |
| `make debug` | Guided diagnosis entry point |
| `make console-cluster` | Headlamp, by a deterministic documented mechanism |
| `make console-metrics` | Grafana — metrics **and traces** (no fourth console, FR-088) |
| `make console-delivery` | Argo CD |

## Verdict vocabulary

`PASS` · `FAIL` · `SKIPPED-BY-CONFIGURATION` (reduced mode only; never presentable as a pass) · `BLOCKED` (a prerequisite checkpoint failed).

There is deliberately no `WARN` at the suite level. A check either validated something or it did not.
