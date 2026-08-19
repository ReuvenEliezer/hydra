# Contract: Observability

**Feature**: `005-k8s-production-lab` | Satisfies: FR-048, FR-077..082, FR-080a, FR-080b, SC-012

## The binding constraint

Neither service has any telemetry capability today — no Micrometer registry, no tracing dependency, no metrics endpoint (research.md A6). **Everything** below is produced by an OpenTelemetry Java agent attached at container level. No metrics or tracing dependency is added to either service's build, and neither service's source is modified to emit telemetry (FR-044, FR-048, FR-077, FR-080).

The agent JAR is baked into the runtime image at `/opt/otel/opentelemetry-javaagent.jar` and is **inert** unless the chart supplies:

```yaml
JAVA_TOOL_OPTIONS: "-javaagent:/opt/otel/opentelemetry-javaagent.jar"
OTEL_SERVICE_NAME: auth-service            # or order-service
OTEL_EXPORTER_OTLP_ENDPOINT: http://otel-collector.hydra-obs:4317
OTEL_TRACES_SAMPLER: always_on             # FR-080b — see below
```

## Pipeline

```text
OTel Java agent (in each app pod)
  └─ OTLP/gRPC → OpenTelemetry Collector (hydra-obs)
       ├─ metrics → Prometheus exporter → scraped by Prometheus
       └─ traces  → Tempo
Prometheus + Tempo → Grafana        ← the only UI (FR-080a, FR-088)
```

Grafana queries both. There is no second console, and none may be added: Jaeger would be a parallel tracing UI, which FR-080a forbids outright.

## Required signals (FR-077)

| Signal | Source |
|---|---|
| Request rate, error rate, latency distribution, per service | Agent HTTP server instrumentation |
| JVM heap, non-heap, GC count and duration, threads | Agent runtime metrics |
| Container CPU and memory | cAdvisor via kubelet |
| Pod restarts, replica counts, HPA state | kube-state-metrics |
| Rate-limited rejections, **distinguishable from application errors** | `http.response.status_code = 429`, kept separate in every panel and every report (FR-079, D11) |

## Dashboards (FR-078)

Organised around rate / errors / duration, and **usable for the resource-tuning and benchmarking work** the spec requires elsewhere — meaning heap, GC and container memory must sit alongside RED on the same boards, or the tuning workflow requires guesswork between screens.

Mandatory panels: RED per service · JVM heap and GC · container CPU/memory versus limits · replica count and HPA state · restart counts · **429s plotted separately from 5xx**.

## Traces (FR-080, FR-080a, FR-080b, SC-012)

Required shape for one external request:

```text
gateway (Envoy)                          ← research.md D13, the at-risk span
  └─ order-service  POST /api/v1/orders
       ├─ auth-service  GET /.well-known/jwks.json
       ├─ postgres query
       └─ redis command
```

| Requirement | Contract |
|---|---|
| Propagation | W3C `traceparent`, entirely by the agent's automatic instrumentation. Services are **not** modified to create or forward spans (FR-080) |
| Retrieval | By trace identifier, within 30 seconds of the request (SC-012) |
| Storage | Tempo, surfaced through Grafana — the only tracing component added (FR-080a) |
| Sampling | `always_on` in the lab. A policy that discards the request under investigation makes the end-to-end scenario untestable (FR-080b). Documented as a lab setting, never as a production recommendation |

**If the gateway span cannot be attached** (research.md D13): SC-012 is reported **FAIL** with the cause named. A trace that starts at `order-service` is not a partial pass — it is a miss, and FR-116 forbids dressing it up as anything else.

## Logs (FR-082)

Machine-parseable structured records carrying at minimum: `timestamp`, `level`, `service`, `trace_id`, `span_id`, `message`. Trace and span ids arrive via the agent's log correlation; JSON encoding is configured through the mounted ConfigMap, not by editing service resources.

**No heavyweight log storage stack** — no Loki, no Elasticsearch. Production log-storage options are documented instead (FR-082). Logs are read with `kubectl logs` and through the cluster console.

## Documentation obligations

- **FR-081**: traces, spans, context propagation, sampling, trace identifiers, and log/trace correlation.
- **FR-060**: memory accounting across heap, class metadata, code cache, direct buffers, native memory, thread-related memory and runtime overhead — and explicitly **not** equating the container memory limit with maximum heap size without a stated reason.
- **FR-050**: platform threads, virtual threads, blocking I/O, scheduler behaviour, pinning, daemon-thread behaviour and limitations — including, in plain terms, when virtual threads do and do not help. **Never** a claim that they inherently reduce memory consumption.
- **FR-106**: the agent's own overhead is a declared limitation of every benchmark, because the lab measures a JVM that is being instrumented.
