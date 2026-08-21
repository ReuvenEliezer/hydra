# The north–south path

Every hop from a browser on the workstation to the process that serves the
request. FR-030 requires **exactly one** deterministic exposure mechanism and
requires it documented — "it works" is not the deliverable; the path is.

```text
  browser / curl                         https://acme.localhost
       │
       │  ① resolver
       ▼
  127.0.0.1:443
       │
       │  ② kind extraPortMapping
       ▼
  hydra-lab-control-plane :30443        (container port)
       │
       │  ③ NodePort Service
       ▼
  Service cilium-gateway-hydra-gateway  (hydra-app, type NodePort, fixed 30443)
       │
       │  ④ Cilium Envoy listener — TLS terminated here
       ▼
  Gateway hydra-gateway, listener "https" :443, hostname *.localhost
       │
       │  ⑤ HTTPRoute match, by PATH
       ▼
  ┌────────────────────────────┬──────────────────────────────┐
  │ /api/v1/auth/**            │ /api/orders/**               │
  │ /api/v1/tenant             │                              │
  │ /api/v1/admin/**           │                              │
  │ /.well-known/**            │                              │
  ▼                            ▼                              │
  Service auth-service:8083    Service order-service:8082      │
       │                            │                         │
       │  ⑥ ClusterIP -> endpoint (Cilium's kube-proxy replacement)
       ▼                            ▼
  auth-service pod             order-service pod
```

## Hop by hop

### ① Resolution — `*.localhost` → `127.0.0.1`

RFC 6761 reserves `localhost` and its subdomains for loopback. macOS and
mainstream Linux resolvers answer `acme.localhost` with `127.0.0.1` **without
any network access and without any configuration**.

That is what satisfies FR-033: no `/etc/hosts` edit, no `sudo`, and — because
no DNS query leaves the machine — a steady state that works offline.

Rejected alternatives, and why:

- **`sslip.io` / `localtest.me`** — resolve through public DNS, so they need
  working internet at request time. Documented as the fallback for a resolver
  that refuses `*.localhost`, with that caveat attached.
- **`/etc/hosts` entries** — needs elevated privilege and a per-tenant line,
  which would also mean adding a tenant requires a host change. That is exactly
  what FR-040 says must not be true.

`make gw-test` asserts both halves: that the name resolves to loopback, and
that no `/etc/hosts` entry exists for it.

### ② The kind port mapping

`cluster/kind-cluster.yaml` declares:

```yaml
extraPortMappings:
  - containerPort: 30443      # GATEWAY_NODEPORT_HTTPS
    hostPort: 443
    listenAddress: "127.0.0.1"
```

The host's 443 is bound directly to a port on the control-plane node container.
Both numbers come from `versions.env`; neither file carries its own literal.

The mapping exists only on the **control-plane** node, which is why the Gateway
Service is a NodePort rather than anything cleverer — traffic must arrive at
that specific node.

### ③ The NodePort Service — and why the port is fixed

Cilium's Gateway API implementation creates a Service for the Gateway.
`platform/gateway-api/gateway-service.yaml` patches it to the **fixed** NodePort
`30443`.

Fixed, not allocated, because FR-030 asks for a mechanism that is deterministic:
an allocated NodePort is only knowable after the cluster exists, so no document
can name the address in advance and every document that names it goes stale on
the next recreation.

Rejected alternatives:

- **LoadBalancer + MetalLB** — MetalLB hands out addresses on the Docker
  network. On macOS the Docker bridge is not routable from the host, so the
  address is unreachable no matter how healthy `kubectl get svc` looks.
- **`cloud-provider-kind`** — a second moving part, and non-deterministic
  addressing, for no gain over a fixed port.
- **`kubectl port-forward`** — bypasses the Service entirely, so it is not a
  path from a workstation address to a serving pod at all. It would document a
  route that does not exist in any real deployment.

### ④ Cilium's Envoy listener — TLS terminates here

The `Gateway` declares one HTTPS listener on 443 with `hostname: "*.localhost"`
and `certificateRefs` pointing at the `hydra-lab-tls` Secret.

**One wildcard certificate covers every tenant.** A tenant is one DNS label in
front of the base domain, so `*.localhost` covers `acme`, `beta`, `gamma` and
every tenant that will ever exist. There is no per-tenant certificate, no
per-tenant listener and no per-tenant route (FR-040) — which is why SC-007 can
add a tenant *after* the gateway is programmed and expect it to work with zero
gateway changes.

Envoy here is **Cilium's data plane**, not a separately installed gateway
controller (FR-029). There is exactly one `GatewayClass` in the cluster and
`make gw-status` asserts that, because a second one would mean a standalone
controller had been installed.

### ⑤ HTTPRoute matching — by path, never by rewriting Host

Routing is by **path**. The `Host` header travels from the browser to the
service completely untouched, including through TLS termination and host-based
listener matching.

This is the property the entire feature turns on. Hydra derives tenant identity
from `Host` and from nothing else — no header, no query parameter, no path
segment. A gateway that rewrites `Host` to the backend service name (which is
one of the most common gateway defaults in the wild) does not degrade Hydra; it
takes every tenant offline at once, because every request resolves to `unknown`.

`hostile-edge/host-rewrite.yaml` exists to make exactly that mistake on purpose,
so the conformance suite can be shown to catch it.

Note that both services sit behind a **single** tenant hostname, addressed the
way a browser addresses them (FR-031). `acme.localhost` serves auth and orders
alike; there is no `auth.acme.localhost`.

### ⑥ ClusterIP → endpoint

The `backendRefs` resolve to ordinary ClusterIP Services, and the translation
from ClusterIP to a pod address is done by **Cilium's kube-proxy replacement**.
There is no kube-proxy in this cluster to fall back on — the cluster is created
with `kubeProxyMode: none` — so this hop is Cilium's eBPF datapath or nothing.

`make net-test` proves it with real traffic rather than by inspecting
configuration.

## Service-to-service, for contrast

`order-service` reaching `auth-service` does **not** traverse any of the above.
It resolves cluster DNS directly:

```
AUTH_SERVICE_URL = http://auth-service.hydra-app.svc.cluster.local:8083
```

Two things about that string matter:

- It is a **Service name**, never a pod address. Pod addresses change on every
  restart, and using one produces an outage on the next rollout.
- `AUTH_SERVICE_ISSUER=hydra-auth-service` stays an **opaque string** and is
  never turned into a resolvable address (FR-046). In `order-service`'s
  configuration, `jwk-set-uri` and `issuer-uri` sit adjacent, and conflating
  them is an easy and silent mistake: the issuer is an identity claim, not a
  location.

## What is deliberately absent

| Absent | Why |
|---|---|
| A legacy `Ingress` object | Gateway API is the primary configuration model (FR-026). A smoke check asserts zero `Ingress` objects exist cluster-wide. |
| A standalone gateway controller | Envoy is consumed as Cilium's data plane (FR-029). |
| Per-tenant gateway configuration | A tenant is a database insert (FR-040, SC-007). |
| A second exposure mechanism | FR-030 asks for exactly one. Two would mean two things to keep in sync and two places for a request to go missing. |
| Gateway-emitted CORS headers | The service emits them; a gateway that also does produces two `Access-Control-Allow-Origin` values and the browser rejects the response (FR-037). |
