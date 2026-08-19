# Quickstart: Kubernetes Production Lab

**Feature**: `005-k8s-production-lab` | **Plan**: [plan.md](./plan.md)

This is the validation guide — the runnable path that proves the feature works end to end. It is not an implementation guide; manifests, chart templates and script bodies belong to `tasks.md` and the implementation phase.

Everything here runs from `k8s-lab/`. Details deliberately not repeated: component and workload layout is in [contracts/platform-topology.md](./contracts/platform-topology.md), the full target list in [contracts/developer-interface.md](./contracts/developer-interface.md), telemetry shape in [contracts/observability-contract.md](./contracts/observability-contract.md), and the artifacts each step produces in [data-model.md](./data-model.md).

---

## Prerequisites

Docker, kind, kubectl, helm, Java 25, Maven, `jq`, `curl`, and a workstation with enough CPU and memory for three nodes plus six application pods plus two stateful sets plus observability. Ports 80, 443 and the registry port free.

Do not check these by hand — that is what step 0 is for.

---

## 0 — Host readiness

```bash
make doctor
```

**Expected**: one line per check with an explicit `PASS`/`FAIL`, ending in `ENVIRONMENT READY`. Exit code 0.

**Expected on a machine missing a tool**: that tool named as `FAIL` with what is required, exit non-zero, and **nothing installed or modified** (FR-003). This negative case is SC-002 and must be exercised deliberately — remove a tool from `PATH` and confirm the diagnostic catches it — not assumed from the passing case.

---

## 1 — Build the images from a clean state

```bash
make image-build-clean
```

**Why this runs before anything else**: the audit found that a clean container build cannot currently succeed at all — the Maven wrapper the `Dockerfile`s copy does not exist in this repository, and `browser-edge-starter` is missing from both builds (research.md A1, A2). This step is the FR-018 verification and the first honest test of the feature.

**Expected**: both images build with `--no-cache`; the build prints which toolchain performed it (FR-004); tags are revision-derived, never `latest`.

---

## 2 — Stand up the platform

```bash
make setup
```

**Expected**: each checkpoint prints a concise summary and validates before the next begins. A failed checkpoint stops the run with diagnostic context and reports nothing for later stages (FR-014) — a partially-installed platform never reports partial success.

**Expected duration**: under 45 minutes from a clean machine, including image builds (SC-001).

On a constrained workstation use `make setup-reduced`, which must print which components it disabled and which scenarios are consequently unavailable — including, when Tempo is off, that the end-to-end trace scenario cannot be run in this mode (FR-091).

---

## 3 — Prove the platform is real

```bash
make cluster-health && make net-test && make gw-test
```

**Expected**: three nodes Ready with no workload in `default`; a connectivity check exercising real pod-to-pod **and** pod-to-service traffic (FR-024); a request from the workstation to `https://acme.localhost` answered by a pod **inside** the cluster, over TLS, with certificate verification enabled.

---

## 4 — The end-to-end flow through the gateway

```bash
make test-integration
```

**What it exercises** (FR-095, SC-004): sign in at `https://acme.localhost/api/v1/auth/...` with fixture credentials → receive an access token and the renewal credential → create an order → list orders. `order-service` validates the token against the JWKS it fetched from `auth-service` **over cluster DNS by service name** (FR-045).

**Expected**: 100% success against a healthy environment, and neither service reachable from outside the cluster except through the gateway.

**Also verify by hand once**, because it is the property everything else depends on: the tenant resolved from the `Host` header is `acme` and not `unknown`.

---

## 5 — The gateway proves it is transparent

This is the step the feature exists for.

```bash
make test-edge-conformance     # expect: PASS
make test-hostile-edge         # expect: FAIL, naming the violated clause
```

Both are required. A suite that passes against a correct edge but has never been shown to fail against a broken one cannot distinguish "the edge is transparent" from "the assertions no longer work" (FR-042). Mechanism and prohibitions: [contracts/edge-conformance-reuse.md](./contracts/edge-conformance-reuse.md).

**Expected** (SC-005): every clause passes over TLS with verification **enabled** and with zero modifications to the suite's assertions; the hostile run fails and names the clause.

Then the two checks that go beyond the contract:

```bash
make test-xff-forgery      # SC-006 — a forged X-Forwarded-For is not honoured
make test-new-tenant       # SC-007 — a tenant added now works with zero gateway changes
```

`test-xff-forgery` is the lab's highest-risk requirement (research.md D12). If it cannot pass, that is a genuine finding about Cilium's Gateway API implementation and belongs in the Edge Finding as evidence — **not** a lab defect to work around.

---

## 6 — The platform explains itself

```bash
make console-metrics
```

**Expected** (US4): RED metrics per service, JVM heap and GC, container CPU/memory, restarts and replica counts — all from the attached agent, with no telemetry dependency in either service's build. 429s plotted separately from 5xx (FR-079).

Then issue one request, capture its trace id, and look it up in Grafana.

**Expected** (SC-012): one connected trace covering the gateway, `order-service` and its call to `auth-service`, retrievable within 30 seconds. If the gateway span is absent, this is a **FAIL** with its cause named — never a partial pass (research.md D13).

---

## 7 — Multi-instance correctness

```bash
make test-failure
```

Nine drills, each asserting a real observable and each restoring the environment to a **verified** healthy state (SC-014). The two that matter most to Hydra specifically:

- **`concurrent-rotation`** (SC-010): one renewal credential presented concurrently to different `auth-service` replicas — exactly one rotation succeeds, zero double-honoured, across ≥100 attempts. This is the first time the constitution's non-negotiable atomicity principle is *observed* rather than argued.
- **`cross-replica-limit`** (SC-011): a limit of N per window admits at most N **across all replicas combined**, not N per pod.

Both must run against multiple real replicas. A single-replica deployment does not satisfy them (FR-069).

---

## 8 — Load, scale, measure

```bash
make load-test
make bench
```

**Expected** (SC-016): replica count rises under sustained load and returns toward baseline after. Where workstation resources prevent scaling, the test reports that constraint **explicitly** rather than a false PASS.

**Expected** (SC-017): the report contains every declared field, separates throttled responses from errors, reports repeated runs with observed variance, holds the GC selection constant across concurrency comparisons, and states its limitations without generalising to production.

---

## 9 — Declarative delivery

Change a tracked non-secret value (replica count) in `k8s-lab/gitops/` and commit.

**Expected** (FR-083): Argo CD reports the deviation and the cluster converges — **with no deploy command run**. Confirm with `git grep` that no secret value exists anywhere in the tracked tree (FR-085).

---

## 10 — Reproducibility

```bash
make validate-full
```

Destroys the cluster, removes local state, recreates, installs, deploys, waits, and re-runs smoke, integration and conformance. **Expected** (SC-003): succeeds on three consecutive runs with no manual intervention between passes.

```bash
make cleanup
```

**Expected** (FR-109): cluster, registry and lab-created local state removed, and the first-run path works again from `make doctor`.

---

## Definition of done

```bash
make validate
```

One per-component verdict table, one overall verdict, one exit code (FR-101, SC-015).

Two conditions on top of a green run, and they are not formalities:

1. **Hydra's existing suites still pass, unchanged** — zero assertions modified to accommodate the lab (FR-102, SC-020).
2. **Nothing is reported complete on the strength of generated files** (FR-116). Completion means the environment was executed and validated, with recorded results from actual runs. A directory full of correct-looking YAML is not a lab.

---

## When something fails

```bash
make dump
```

**Expected** (SC-018): for any seeded fault class — scheduling, image, readiness, routing, DNS, network policy, autoscaling, datastore, cache — the dump contains enough to name the failing component **without issuing another command**.

Then diagnose, fix the implementation, and re-run the failed validation. Reporting the error and moving on is explicitly not the procedure (FR-115).
