# k8s-lab

A reproducible Kubernetes laboratory that runs Hydra's **real** `auth-service`
and `order-service` behind a Gateway API edge, on one workstation.

It exists to produce two things: operational knowledge that transfers, and
evidence toward the constitution's open question of whether Hydra's edge should
be Kubernetes-based or a plain proxy plus compose. See
[docs/edge-finding.md](docs/edge-finding.md) for the second.

Nothing here is mocked. Real services, real Postgres, real Redis, real TLS, real
network policy, real rate limiting across real replicas.

---

## Prerequisites

`make doctor` checks all of these and **installs nothing**. It reports and
instructs; the fixes are yours to make.

| Tool | Why |
|---|---|
| Docker (or another container runtime) | everything runs in containers |
| `kind` | the cluster |
| `kubectl` | the client |
| `helm` | charts |
| `curl`, `jq`, `openssl`, `git` | the Bash suites |
| `keytool` (any JDK) | builds the PKCS#12 truststore |
| A JDK + Maven | **only** for `make test-edge-conformance` |

Java is **not** needed to build the images: the build uses a pinned Maven
toolchain image, so the host's Java version is irrelevant to it.

**Capacity**: 4 CPU and 8 GB minimum, 16 GB recommended. On macOS the number
that binds is the container runtime's allocation, not the machine's — Docker
Desktop → Settings → Resources.

**Platforms**: macOS (arm64/x86_64) and Linux. Native Windows is not a target;
use WSL2.

```bash
cd k8s-lab
make doctor
```

Read the output. `ENVIRONMENT NOT READY` lists exactly what is missing and what
to run.

---

## Run it

```bash
make setup
```

One command, fifteen checkpoints, stopping at the first failure with diagnostic
context. Budget: under 45 minutes on a clean machine; a few minutes on a warm
one.

Constrained workstation:

```bash
make setup-reduced
```

It prints exactly which components it disabled and **which scenarios that makes
unavailable**. Those are reported `SKIPPED-BY-CONFIGURATION`, never as passes.

When it finishes:

```
https://acme.localhost      tenant 1
https://beta.localhost      tenant 2
```

No `/etc/hosts` edit. No `sudo`. `*.localhost` is loopback by RFC 6761.

---

## Check it

```bash
make test        # smoke + integration + edge conformance + the fast drills
make validate    # one verdict per component, one overall, one exit code
```

`make test` executes; `make validate` reports. Neither recreates the cluster.

```bash
make validate-full   # destroy -> rebuild -> deploy -> verify. Not fast.
make validate-repro  # validate-full three times, unattended. Slower still.
```

`validate-repro` is SC-003: three consecutive rebuilds with **nothing** between
the passes but a loop counter. Three rebuilds run by hand are three rebuilds —
a human between them quietly supplies the retries and the waiting that the
sequence is supposed to supply for itself, which is the dependency SC-003 exists
to find. Each pass is recorded to `results/reproducibility/`.

Individually:

```bash
make test-smoke
make test-integration
make test-edge-conformance    # Hydra's EXISTING suite against this gateway
make test-hostile-edge        # the same suite must FAIL, naming the clause
make test-failure             # all nine drills
make test-scaling
```

---

## Look inside

```bash
make console-cluster     # Headlamp  — nodes, pods, events, logs
make console-metrics     # Grafana   — metrics AND traces
make console-delivery    # Argo CD   — sync state
make argocd-status       # per-Application sync/health, no UI needed

make logs WORKLOAD=auth-service
make dump                # everything, for any seeded fault class
make debug               # guided diagnosis, stops at the first real problem
```

Grafana is the **only** UI for metrics and traces. Tempo was chosen over Jaeger
precisely so tracing adds a store and not a second console.

---

## When something is wrong

```bash
make debug
```

It asks the questions in the order that narrows a fault and stops at the first
one that answers, so the thing it names is the thing to fix. `make dump` prints
everything instead, which is the right tool once you know what you are looking
for.

---

## Measure it

```bash
make load-test    # traffic through the actual gateway
make bench        # both concurrency modes, GC held constant, full report
```

The benchmark writes `results/benchmark/<timestamp>/report.md` and **states its
own limitations**. Read that section before quoting any number from it: every
figure describes one workstation under one synthetic workload, and the report
deliberately draws no conclusions.

---

## Tear it down

```bash
make cleanup
```

Removes the cluster, the registry and lab-created local state, leaving the
first-run path working. Run output in `results/` is kept — it is the evidence
that anything was ever executed.

---

## How it is put together

```
k8s-lab/
├── Makefile              the only entry point
├── versions.env          THE version matrix — every pin, with its basis
├── scripts/              doctor, setup, cluster, registry, certs, platform, app…
│   └── lib/              log, assert, wait (condition-based only), checkpoint
├── cluster/              kind topology (template; rendered from versions.env)
├── platform/             Cilium, Gateway API, observability, Argo CD, Headlamp
├── charts/hydra-lab/     the umbrella chart — services, datastores, routes, policy
├── gitops/               what Argo CD reconciles
├── tests/                smoke, integration, failure drills, perf
├── hostile-edge/         a deliberately wrong gateway, to prove the suite catches it
└── docs/                 ← start with docs/north-south-path.md
```

### Rules the whole tree follows

- **No script hard-codes a version.** Everything reads `versions.env`;
  `make verify-versions` enforces it.
- **Every wait is condition-based with a bounded timeout.** `lib/wait.sh`
  exposes no sleep-based helper at all — a fixed duration passes on a fast
  machine and fails on a slow one, and points at the wrong component when it
  does.
- **No component is reported passing without an executed check behind it.**
  Checkpoints take the action and the validation as separate commands, and only
  the validation decides.
- **No secret value is ever written to the tracked tree.**

---

## Where to read next

| Question | Document |
|---|---|
| How does a request get from my browser to a pod? | [docs/north-south-path.md](docs/north-south-path.md) |
| Why these technologies, and why not the others? | [docs/technology-choices.md](docs/technology-choices.md) |
| What does each component do, and how do I break it? | [docs/components/](docs/components/) |
| How does the networking actually work? | [docs/networking.md](docs/networking.md) |
| How do I read a trace? | [docs/observability.md](docs/observability.md) |
| Why is the container using more memory than the heap? | [docs/memory.md](docs/memory.md) |
| Do virtual threads help here? | [docs/concurrency.md](docs/concurrency.md) |
| What would change in production? | [docs/production-mapping.md](docs/production-mapping.md) |
| How do I revise the resource limits? | [docs/resource-tuning.md](docs/resource-tuning.md) |
| **What is not covered, and what did this find?** | [docs/known-gaps.md](docs/known-gaps.md) |
| **What was actually executed?** | [docs/executed-results.md](docs/executed-results.md) |
| **Should Hydra's edge be Kubernetes?** | [docs/edge-finding.md](docs/edge-finding.md) |

The last three are the ones worth reading even if you never run the lab.
