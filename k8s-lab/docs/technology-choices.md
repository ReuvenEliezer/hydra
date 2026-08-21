# Technology choices

Why each component is here, and — more usefully — why the obvious alternatives
are not (FR-110).

Exclusions get as much space as inclusions. A reader who knows why Envoy Gateway
is absent understands the design; a reader who only knows Cilium is present has
learned a fact.

---

## Cilium — CNI, kube-proxy replacement, NetworkPolicy, Hubble **and** the Gateway API implementation

**One component covering five jobs.** That is the whole argument. FR-022 asks
for a network provider supplying CNI, a policy engine, kernel-level
observability *and* a Gateway API implementation; Cilium is the only product
that does all four without a second moving part.

The Gateway API implementation matters most. FR-029 forbids a standalone gateway
controller and requires Envoy to be consumed as the **data plane of the network
provider's** gateway implementation. That is exactly Cilium's model: the Envoy
DaemonSet belongs to Cilium and is not independently managed.

The cluster is created with `disableDefaultCNI: true` and `kubeProxyMode: none`,
so Cilium is genuinely the only datapath. Enabling the kube-proxy replacement
*alongside* a running kube-proxy would produce a cluster where neither path is
the one under test.

### Rejected

| Alternative | Why not |
|---|---|
| **Calico + Envoy Gateway** | Two components, and Envoy Gateway is precisely the standalone controller FR-029 excludes |
| **Istio** | A service mesh. Explicitly out of scope, and it would answer the edge question by changing it |
| **NGINX Gateway Fabric** | Gateway only — CNI, policy and kernel observability all still unsolved |
| **Flannel** | No NetworkPolicy enforcement, which is half of what the lab wants to demonstrate |

### The cost, stated

Cilium's Gateway API is **less configurable** than standalone Envoy Gateway, and
that cost is real rather than theoretical. Two requirements depend on
configuration surface Cilium may not expose: `X-Forwarded-For` replace-not-append
(FR-041) and gateway spans (FR-080). Both are tracked as at-risk, and if either
cannot be satisfied that is a finding for [edge-finding.md](edge-finding.md), not
a defect to work around.

A third cost surfaced during implementation: **the gateway's own traffic carries
Cilium's `reserved:ingress` identity**, which a standard NetworkPolicy cannot
name. "Let the gateway reach the backends" is only expressible as a
`CiliumNetworkPolicy`. See [known-gaps.md](known-gaps.md) §5.

---

## kind — the cluster

Mandated, and the only provisioner that satisfies the exclusions. It supports
disabling the default CNI, disabling kube-proxy, and binding host ports to fixed
node ports — the three things the design needs.

### Rejected

| Alternative | Why not |
|---|---|
| **minikube** | Excluded by the requester |
| **k3d** | Excluded, and it ships its own service load balancer and Traefik ingress, which would compete with the mandated Gateway API path |
| **Docker Desktop's built-in cluster** | Excluded; also not reproducible across machines |

---

## Gateway API — the primary north-south model, and no `Ingress`

`Ingress` cannot express what this lab needs to demonstrate: typed route
filters, route-level timeouts, header manipulation as first-class configuration,
and a clean separation between who owns the gateway and who owns the routes.

Only the **standard channel** is installed (FR-027). The experimental channel
carries CRDs Cilium may not implement, and installing them would create objects
the cluster silently ignores.

A smoke check asserts **zero `Ingress` objects exist cluster-wide** — "primary
model" should mean the other one is absent, not merely discouraged.

---

## Postgres and Redis — plain StatefulSets, official images, no Bitnami

The **same pinned images as the repository's own `docker-compose.yml`**. Version
parity with local development is worth more than chart convenience: a lab
running a different Postgres than `docker compose up` is measuring a different
system, and any difference it finds is then ambiguous.

### Rejected

| Alternative | Why not |
|---|---|
| **Bitnami charts** | Would break version parity, and their free image catalogue has been restricted. A lab whose reproducibility depends on a vendor's registry policy is not reproducible |
| **CloudNativePG** | A production-grade operator whose value is failover and backup — neither of which this lab exercises, and both explicitly out of scope |
| **Managed cloud databases** | Not available on a workstation, and the point is to see the failure modes |

---

## OpenTelemetry Java agent — instrumentation without touching the build

**Neither service has any telemetry capability today**: no Micrometer registry,
no tracing dependency, no metrics endpoint. Everything observable in this lab is
produced by an agent attached at container level.

The agent JAR is baked into the runtime image and is **inert** unless the chart
supplies `JAVA_TOOL_OPTIONS`. That keeps the image usable outside the lab.

This is the strongest available form of "dedicated modules for cross-cutting
concerns": the concern is not folded into any module because it is not in any
module.

### Rejected

| Alternative | Why not |
|---|---|
| **Micrometer + actuator Prometheus registry** | Requires a build dependency in both services. FR-044 and FR-048 forbid it outright |
| **Hand-instrumenting the services** | A source change, and the wrong lesson: production instrumentation should not require editing every handler |

### The cost, stated

Agent-only instrumentation has a ceiling. It sees HTTP, JDBC, Redis and the JVM.
It does **not** see domain intent — "this was a checkout" — because nothing in
the code tells it. Business-level telemetry would need source changes this
feature does not make.

And the agent's own overhead is in every benchmark number, which the report says
in its Limitations section.

---

## Prometheus + Grafana + OTel Collector + Tempo

The collector fans out: metrics to a Prometheus endpoint that Prometheus
scrapes, traces to Tempo. Grafana queries both.

**Tempo over Jaeger, for one reason that is not about features**: Jaeger ships a
UI. FR-080a forbids a parallel tracing console, and Grafana already queries Tempo
natively — so Tempo adds a trace *store* without adding a second place to look.

Metrics are **pulled**, not pushed: a missing scrape target is visible in
Prometheus's own UI, whereas a failed push is visible only in the collector's
logs.

### Rejected

| Alternative | Why not |
|---|---|
| **Jaeger** | A second console. FR-080a forbids it |
| **Loki / Elasticsearch** | FR-082 explicitly rules out a heavyweight log stack. Logs are read with `kubectl logs` and carry `trace_id`; production options are documented instead |
| **kube-prometheus-stack** | Bundles Grafana, which would make "one values file per component" impossible and hide the wiring the lab exists to show |

---

## Argo CD — declarative delivery

**Chosen over Flux for one concrete reason**: FR-088 requires a delivery console
reachable by its own access operation, and Argo CD ships one. Flux would mean
adding a separate UI — a component no requirement asks for.

It reconciles from a **bare git repository inside the lab**, bind-mounted into
every node. No network, no hosting account, no credentials — which keeps the
offline steady state intact.

It owns a delivery slice rather than the umbrella chart. Two controllers owning
the same objects produces ownership conflicts; see
[known-gaps.md](known-gaps.md) §8.

---

## Headlamp — the cluster console

FR-087 says *install a console in the cluster*. Headlamp runs in-cluster and
covers all eight required areas.

### Rejected

| Alternative | Why not |
|---|---|
| **k9s** | A terminal client installed on the **host**, not a console installed in the cluster. FR-088's "each behind its own access operation" implies a reachable endpoint |
| **Kubernetes Dashboard** | Heavier, and awkward to expose |

Its cost is stated where it lives: Headlamp acts with a **cluster-admin** service
account, so anything a user can click, it can do. Confined to a loopback
port-forward, and mapped to per-user SSO in
[production-mapping.md](production-mapping.md).

---

## Bash for the test suites

FR-092 requires execution against the actual cluster, and FR-102 requires
Hydra's existing suites to keep passing unchanged. Bash driving `kubectl`,
`curl` and `jq` runs against the real thing with no build step and nothing to
mock.

Adding a Maven module for lab tests would put lab concerns in Hydra's reactor,
which the scope boundary rules out. The two genuinely concurrent tests —
≥100 simultaneous rotations, and a cross-replica limit — are expressible with
`xargs -P` over `curl`, and no JVM is needed to count outcomes.

The one Java-side execution is Hydra's **existing** `edge-conformance` suite,
invoked through Maven with `-Dedge.base-url` and JVM truststore properties. Zero
new test code; see [edge-conformance-reuse](../../specs/005-k8s-production-lab/contracts/edge-conformance-reuse.md).

---

## What is deliberately absent

| Absent | Why |
|---|---|
| A service mesh | Out of scope for the initial implementation. It would also answer the edge question by replacing it |
| MetalLB / `cloud-provider-kind` | MetalLB hands out Docker-network addresses, unreachable from a macOS host. Both add non-determinism where FR-030 wants exactly one deterministic mechanism |
| cert-manager | A lab CA and one wildcard certificate is the whole TLS story here. cert-manager solves issuance and renewal at scale — real problems this lab does not have |
| Alertmanager | Nothing asks for alert routing, and an Alertmanager with no receivers looks like alerting and does none |
| A pushgateway | Exists for batch jobs that die before a scrape. Nothing here is that shape |
| Sealed-secrets / external-secrets | Real answers to a real problem, and adopting one is a decision this feature has no mandate to make |
