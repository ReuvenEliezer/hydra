# Observability

Traces, spans, propagation, sampling and log correlation (FR-081, FR-080b).

**Everything observable in this lab comes from an OpenTelemetry Java agent
attached at container level.** Neither service has a Micrometer registry, a
tracing dependency or a metrics endpoint of its own. No source was changed and
no dependency was added to either build.

---

## The pipeline

```
OTel Java agent (inside each app pod)
  └─ OTLP/gRPC :4317 → OpenTelemetry Collector (hydra-obs)
       ├─ metrics → Prometheus endpoint :8889 → scraped by Prometheus
       └─ traces  → Tempo

Prometheus + Tempo → Grafana        ← the ONLY UI
```

Grafana queries both. **There is no second console and none may be added**
(FR-080a) — which is exactly why Tempo was chosen over Jaeger: a trace store
without a tracing UI.

The agent is baked into the image at `/opt/otel/opentelemetry-javaagent.jar` and
is **inert** unless the chart supplies `JAVA_TOOL_OPTIONS`. The image is not
permanently coupled to this lab.

---

## Traces

### What a trace is

A trace is one request's journey. Each hop is a **span**: a named, timed
operation with a parent. Spans form a tree, and the tree is the request.

```
gateway (Envoy)                          ← the at-risk span, see below
└─ order-service  GET /api/orders
   ├─ auth-service  GET /.well-known/jwks.json
   ├─ postgres  SELECT ...
   └─ redis  GET rate-limit:...
```

### Context propagation

W3C `traceparent`, entirely by the agent's automatic instrumentation:

```
traceparent: 00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01
             ││ └─ trace id (32 hex) ─────────┘ └─ span id ────┘ └ flags
             └─ version
```

The agent injects it on outgoing calls and extracts it on incoming ones. When
`order-service` calls `auth-service`, the header travels and the child span
attaches to the right parent. **Neither service was modified to create or
forward a span.**

### Sampling — `always_on`, and why that is a lab setting

```
OTEL_TRACES_SAMPLER=always_on
```

Every trace is recorded.

**This is a lab setting and NOT a production recommendation** (FR-080b). It is
here because SC-012 requires retrieving *the trace for one specific request*, and
a sampler that discards the request under investigation makes that untestable.

In production, `always_on` at real volume is expensive in collector CPU, network
and storage — and the usual answer is tail-based sampling: buffer the spans,
decide after the fact, keep the errors and the slow ones. That needs a collector
deployment this lab does not build.

It also means **the agent's overhead is in every benchmark number**, which the
benchmark report states in its Limitations section rather than leaving to be
discovered.

### Retrieving one trace

```bash
make console-metrics       # Grafana → Explore → Tempo → paste a trace id
```

Or from the command line:

```bash
kubectl -n hydra-obs port-forward svc/tempo 3200:3100
curl -s localhost:3200/api/traces/<trace-id> | jq
```

`tests/integration/trace-e2e.sh` issues one request with a `traceparent` it
chooses itself, then retrieves *that* trace by identifier within 30 seconds
(SC-012). Choosing the id matters: searching for "a recent trace" would pass on
any trace at all, which is not the requirement.

### The gateway span, and the honest failure

SC-012 requires the trace to **begin at the gateway**. That is the hop a
service-side agent structurally cannot see: the agent runs inside the JVM and
Envoy is not a JVM.

The attempt is a `CiliumClusterwideEnvoyConfig` attaching a tracing provider to
the listener (D13). **If it cannot be attached, SC-012 is reported FAIL with the
cause named.** A trace that begins at `order-service` is a miss, not a partial
pass, and FR-116 forbids dressing it up as one.

Why it matters beyond the tick: without the gateway span, time spent in TLS
termination, routing and upstream connection is invisible. A latency problem in
the edge looks like a fast backend and a slow client.

---

## Metrics

| Signal | Source |
|---|---|
| Request rate, error rate, latency distribution | agent HTTP server instrumentation |
| JVM heap, non-heap, GC count and duration, threads | agent runtime metrics |
| Container CPU and memory | cAdvisor via the kubelet |
| Pod restarts, replica counts, HPA state | kube-state-metrics |
| **Rate-limited rejections, distinguishable from errors** | `http.response.status_code = 429` |

### 429 is not an error, and never will be here

FR-079 and D11. A 429 means the rate limiter did its job. Folding it into an
error rate makes a working control look like an outage — and hides a real outage
inside a busy afternoon. Both directions of that confusion are expensive.

No new metric was added for this (no service change is possible or needed): the
agent's `http.server.request.duration` already carries the status code. The
requirement is that **dashboards and reports do not aggregate them**, and
`tests/integration/rate-limit-metrics.sh` asserts the dashboards keep them apart.

### Dashboards

Two, both provisioned from `platform/observability/dashboards/` as a ConfigMap,
so they are versioned with the lab rather than clicked into a database that
disappears with the cluster.

| Dashboard | For |
|---|---|
| **Hydra — RED** | rate, errors, duration per service; 429 plotted separately from 5xx |
| **Hydra — runtime, resources and scaling** | JVM heap, GC, container memory vs limits, replicas, HPA state — **with RED repeated at the bottom** |

The repetition is deliberate. Tuning a memory limit means reading heap, GC,
container memory *and* latency at the same instant; splitting them across two
boards turns that into guesswork between screens.

---

## Logs

Structured JSON via Spring Boot's built-in structured logging — **not** a new
dependency, because none is needed and FR-044 forbids adding one. Configured
through the mounted ConfigMap, never by editing service resources.

Every record carries at least: `timestamp`, `level`, `service`, `trace_id`,
`span_id`, `message`. The trace and span ids arrive via the agent's log
correlation, which populates MDC.

```bash
make logs WORKLOAD=auth-service
```

### Log/trace correlation, the workflow

1. Find an error in the logs; take its `trace_id`.
2. Grafana → Explore → Tempo → paste it.
3. See the whole request, including the hops that did not log anything.

That second point is the payoff: the log tells you *a* service failed, the trace
tells you what it was waiting for.

### No log storage stack, deliberately

FR-082 rules out Loki and Elasticsearch. Logs are read with `kubectl logs` and
through the cluster console.

The honest consequence: **logs do not survive a pod restart here**, so a
post-mortem after a crash-loop has only what you captured while it was running.
That is a real limitation of the lab and the reason production runs a log store.
Options are documented rather than installed:

| Option | Trade-off |
|---|---|
| Loki | Cheap, label-indexed, grep-shaped queries; pairs with Grafana |
| Elasticsearch/OpenSearch | Rich full-text search, much heavier |
| Cloud-native (CloudWatch, Stackdriver) | No infrastructure, vendor-coupled, per-GB cost |
| OTel collector → any of the above | Keeps the pipeline uniform with metrics and traces |

---

## What agent-only instrumentation cannot do

Its ceiling is worth stating plainly. The agent sees HTTP, JDBC, Redis and the
JVM. It does **not** see domain intent — "this was a checkout", "this tenant is
on the enterprise plan" — because nothing in the code tells it.

Business-level telemetry needs source changes this feature does not make. What
you get for free is everything about *mechanism* and nothing about *meaning*.

## Production equivalents

| Lab | Production |
|---|---|
| `always_on` sampling | Tail-based sampling: keep errors and slow traces, sample the rest |
| Tempo with local storage, 24h | Object storage, retention policy, per-tenant limits |
| Prometheus, no persistence | HA Prometheus or a remote-write backend |
| Grafana anonymous-admin | SSO, per-team folders, RBAC |
| No alerting | Alertmanager or equivalent, with routing that reaches a human |
| Agent auto-instrumentation only | Same, plus deliberate spans and attributes for domain events |
