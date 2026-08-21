# The Edge Finding

**Evidence toward the constitution's open question — not a resolution of it.**

The constitution records an open decision: *"Kubernetes + Envoy Gateway is the
current target; docker-compose is a candidate alternative under active
evaluation."* This lab exists partly to gather evidence on that, and this page
is what it found.

It is readable on its own. You should not need another document to know what was
proved and what was not.

---

## In one paragraph

A Kubernetes edge built on Cilium's Gateway API **satisfies Hydra's transparent
edge contract** where the lab could test it: `Host` survives TLS termination and
host-based routing intact, both tenants resolve to themselves, adding a tenant
touches no gateway object, and the credential's `Secure` attribute is exercised
over genuinely encrypted transport for the first time. It also cost more than
expected in three specific places, each of which is a real argument and none of
which is fatal. Two requirements remain at risk and are reported honestly below.

---

## What the lab demonstrated

Every line here was executed against a running cluster. See
[executed-results.md](executed-results.md) for the raw results.

### The contract holds through a real gateway

Until now the transparent edge contract had only ever met a stand-in nginx proxy.
It has now met a real one, and three clauses are verified in ways a
pass-through structurally could not:

| Clause | What only a real gateway proves |
|---|---|
| **1 — `Host` preserved** | Preserved through **TLS termination and host-based listener matching**, not merely through a transparent forward |
| **4 — credential untouched** | The `Secure` attribute is exercised as issued, because the transport is genuinely encrypted |
| **5 — no per-tenant configuration** | A tenant added *after* the gateway was programmed works with **zero** gateway objects changed — proven against a live control plane |

Measured, through the gateway over TLS with verification enabled:

```
GET https://acme.localhost/api/v1/tenant  →  {"status":"recognized","displayName":"Acme Corp"}
GET https://beta.localhost/api/v1/tenant  →  {"status":"recognized","displayName":"Beta Inc"}
```

Two addresses, two tenants, one wildcard listener, one certificate, zero
per-tenant objects.

### Multi-instance correctness that had never been observed

Two properties Hydra's design depends on, and which no test had ever measured:

**Atomic credential rotation (SC-010).** 120 concurrent rotations of one renewal
credential across 3 replicas produced **exactly one distinct credential**. The
constitution's Principle IV is now an observation rather than an argument.

**Shared rate limiting (SC-011).** A limit of 5 admitted **2** across 3
replicas. A per-replica limiter would have admitted up to 15 — the failure mode
that is invisible in every single-instance test.

Neither of these is really about Kubernetes. Both are about running more than
one replica *at all*, which is the thing a compose file does not encourage.

### Operational properties

- 100% availability through a pod deletion (SC-008)
- Rolling updates with `maxUnavailable: 0`
- Network policy proven against a real unauthorised caller: 100% denied on every
  forbidden path, 100% allowed on every permitted one (SC-013)
- Fail-closed when the cache is gone: losing Redis **rejects** requests rather
  than passing them through unthrottled (FR-056)

---

## What it cost — three real arguments

These are the substance of the finding. None is fatal; all are true.

### 1. Gateway ingress is not expressible in standard NetworkPolicy

Every request through the gateway returned:

```
upstream connect error or disconnect/reset before headers. reset reason: connection timeout
```

while routes reported `Accepted` and every pod was healthy.

When Cilium's Envoy proxies to a backend, the connection carries Cilium's
`reserved:ingress` identity — **not** the identity of a pod in any namespace. A
standard `NetworkPolicy` cannot name that, so the traffic fell through to
default-deny. The only correct expression is `fromEntities: [ingress]`, which
exists only in `CiliumNetworkPolicy`.

**Why this matters for the decision**: the most basic policy statement anyone
writes — "let the gateway reach the backends" — required a vendor CRD. That is a
portability cost, and it was invisible until traffic actually flowed. A
different CNI would have a different answer, and none of them is the portable
one.

### 2. The gateway is configurable only through the vendor's CRD

Cilium's Gateway API surface is narrower than standalone Envoy Gateway's.
Anything the Gateway API does not model — XFF handling details, tracing
providers, listener-level Envoy settings — is reachable only through
`CiliumClusterwideEnvoyConfig`.

That is a coherent design (FR-029 wanted Envoy consumed as the network
provider's data plane, and it is), but it means the escape hatch is
vendor-shaped. Choosing this gateway is choosing this CNI.

### 3. The failure modes are numerous and they name the wrong thing

Eighteen distinct defects were found by executing this lab, and the pattern
across them is more instructive than any individual one: **the error message
usually named a component that was working perfectly.**

- Cilium's operator probes for the Gateway API CRDs once at startup and disables
  Gateway support if absent, with no retry. The Gateway then sits at
  `Waiting for controller` forever, and nothing in its status says why.
- A stale ConfigMap mount in a Helm hook stalled an entire release; the visible
  symptom was probes returning 401.
- Helm 4 persisted a `--set replicas=0` from an earlier phase, so both services
  ran at **zero** replicas while every checkpoint reported success — 0 desired
  and 0 ready are equal.
- A `hostPath` on one node out of three produced a pod stuck in `Init` and a
  message about a directory.

A compose file has fewer moving parts and correspondingly fewer of these. That
is a genuine operational cost of Kubernetes, and it is paid by whoever is on
call, not by whoever chose the architecture.

---

## What could not be demonstrated locally

The honest list. Each of these is a reason this evidence is incomplete.

| Not demonstrated | Why |
|---|---|
| **Real load-balancer behaviour** | There is no L4 load balancer. Traffic arrives at a fixed NodePort. No target draining, no idle timeouts, no cross-zone balancing |
| **Real node failure** | `docker stop` is an orderly shutdown on the same kernel, with no node replacement and no volume re-attachment |
| **Managed control plane** | No upgrades, no API server failover, no provider-specific admission behaviour |
| **Multi-zone anything** | One machine. Topology constraints demonstrate the mechanism, not the protection |
| **Real certificate issuance** | A lab CA. No ACME, no rotation, no revocation |
| **Production traffic** | Two endpoints, synthetic load, unloaded local datastores, microsecond latency. Every timeout tuned here would be wrong |
| **Cost** | Not measurable on a laptop, and it is a real input to this decision |

---

## Two requirements that remain at risk

Reported as required by FR-116 rather than quietly absorbed.

### `X-Forwarded-For` replace-not-append (FR-041, SC-006)

The threat is concrete: `ClientIpResolver` trusts the **left-most** XFF value
with no validation. A gateway that *appends* leaves a client-supplied value in
front, and every per-address rate limit becomes forgeable by anyone who can set
a header.

The route filter is configured with `set` semantics and
`tests/integration/xff-forgery.sh` tests it empirically — rotating a forged
address must not buy a fresh rate-limit bucket. **If neither D12 route produces
replace semantics, that is a finding about Cilium's Gateway API and an argument
against this edge, not a lab defect.**

### Gateway spans (SC-012, FR-080)

The trace must **begin at the gateway**. A service-side agent structurally
cannot instrument a proxy it does not run inside, so the only lever is attaching
a tracing provider through `CiliumClusterwideEnvoyConfig`.

If it cannot be attached, `tests/integration/trace-e2e.sh` reports **FAIL** with
the cause named. A trace beginning at `order-service` is a miss, not a partial
pass. Without the gateway span, time spent in TLS termination, routing and
upstream connection is invisible — a latency problem in the edge looks like a
fast backend and a slow client.

---

## What would still require cloud verification

Before the constitution's open question could be closed, someone should
establish, in a real environment:

1. **Load-balancer integration** — Gateway API behind a real cloud LB: health
   checks, draining, idle timeouts against Hydra's keep-alive.
2. **XFF through the full chain** — LB *and* gateway both touch it. The lab
   tested one hop.
3. **Certificate lifecycle** — real issuance, rotation and expiry, with the
   wildcard actually working (which it does on a non-public-suffix domain).
4. **Node failure and replacement** — including volume re-attachment for the
   datastores, if they stay in-cluster.
5. **Upgrade behaviour** — control plane, CNI and Gateway API CRDs. The CRD
   ordering trap found here suggests upgrades deserve their own rehearsal.
6. **Cost and operational load** — engineer-hours, not just dollars.
7. **The compose alternative, tested the same way.** This lab only measured one
   side. A fair comparison needs the other one built and drilled identically —
   and several of the properties measured here (SC-010, SC-011) would need a
   multi-replica compose setup to test at all, which is itself informative.

---

## Framing

**This is evidence, not a decision** (FR-113).

What it supports: Kubernetes with Cilium's Gateway API **can** host Hydra's edge
while satisfying the transparent edge contract, and it makes multi-instance
correctness properties testable that a single-instance deployment simply cannot
express.

What it also supports: that choice carries a specific, non-obvious cost in
vendor coupling, in configuration surface reachable only through vendor CRDs,
and in operational failure modes whose error messages point at the wrong
component.

What it cannot support: any conclusion about behaviour under real load, real
failure, or real cost — and any comparison with compose, which was not built.

The question stays open. It is now open with data.
