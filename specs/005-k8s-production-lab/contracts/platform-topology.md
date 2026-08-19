# Contract: Platform Topology

**Feature**: `005-k8s-production-lab` | Satisfies: FR-010..034, FR-045, FR-051..054, FR-061..066, FR-070..076

## Namespaces (FR-074)

| Namespace | Contents | Notes |
|---|---|---|
| `kube-system` | Cilium agent, operator, Envoy DaemonSet, Hubble | Envoy is Cilium's data plane, not an independently managed component (FR-029) |
| `hydra-app` | `auth-service`, `order-service`, Gateway, HTTPRoutes, HPAs, PDBs, migration + fixture Jobs | — |
| `hydra-data` | Postgres, Redis StatefulSets | — |
| `hydra-obs` | Prometheus, Grafana, OTel Collector, Tempo | — |
| `hydra-delivery` | Argo CD, Headlamp | — |

**Invariant**: no application workload runs in `default` (FR-074), verified by a smoke check.

## North-south path (FR-030 — the one documented mechanism)

```text
browser / curl                    https://acme.localhost:443
  └─ macOS resolver: *.localhost → 127.0.0.1            (RFC 6761, no hosts file, no sudo)
     └─ kind extraPortMapping: host 443 → control-plane node port
        └─ NodePort Service (fixed port) for the Gateway
           └─ Cilium Envoy listener — TLS terminated with the lab wildcard cert
              └─ HTTPRoute match on path
                 ├─ /api/v1/auth/**   → auth-service:8083
                 └─ /api/v1/orders/** → order-service:8082
                    └─ ClusterIP Service → endpoint pod
```

Every hop above MUST appear in `k8s-lab/docs/` (FR-030). "It works" is not the deliverable; the path is.

**`Host` is never rewritten anywhere on this path** (FR-036). Routing is by path; the host header travels untouched, including through TLS termination. This is the property the whole feature turns on: tenant identity comes solely from `Host`, so a rewrite is a total outage, not a degradation.

## Gateway objects (FR-026..034)

| Object | Requirement |
|---|---|
| Gateway API CRDs | Installed explicitly at a pinned version, standard channel, stable API versions where available (FR-027) |
| `GatewayClass` | Cilium's controller. No standalone gateway controller is installed (FR-029) |
| `Gateway` | One HTTPS listener on 443, `certificateRefs` → the lab wildcard Secret, hostname `*.localhost` |
| `HTTPRoute` | Path-based routing to both services, so both are reachable through a **single** tenant hostname as a browser addresses them (FR-031). Demonstrates header manipulation and route-level timeouts (FR-028) |
| Legacy `Ingress` | MUST NOT be the primary configuration model (FR-026) |
| CORS handling on the gateway | MUST be explicitly disabled if the implementation enables any by default (FR-037) |

**No per-tenant object exists.** One wildcard listener, one certificate, path-based routes. Adding a tenant touches nothing here (FR-040).

## Workload requirements (FR-061..066)

Applies to `auth-service` and `order-service` alike:

| Requirement | Setting |
|---|---|
| Replicas | 3 (2 in reduced mode — never 1; FR-069 needs real multi-instance) |
| Resources | Requests **and** limits declared (FR-061). Initial values are starting points, revised only from measurement (FR-062) |
| Startup probe | `/actuator/health` — tolerates slow JVM start without a liveness kill |
| Readiness probe | `/actuator/health/readiness` — genuine ability to receive traffic, distinct from liveness (FR-063) |
| Liveness probe | `/actuator/health/liveness` |
| Readiness toggle | A controlled way to force a replica unready, gated behind a non-production profile, off by default (FR-064) |
| Disruption | PodDisruptionBudget + topology spread across the two workers (FR-065) |
| Rolling update | `maxUnavailable: 0`, `maxSurge: 1` — new pods ready before old terminate (SC-009) |
| Termination | `terminationGracePeriodSeconds` sized for in-flight requests; exec-form entrypoint so the JVM receives SIGTERM (FR-058) |
| Security context | Non-root with explicit uid/gid matching the image, all capabilities dropped, read-only root filesystem with a writable `/tmp` emptyDir, seccomp `RuntimeDefault`, never privileged (FR-058) |
| Service account | Dedicated per workload, least privilege, never cluster-admin (FR-075) |

Probes require `management.endpoints.web.exposure.include` and health groups to be enabled — supplied through the mounted ConfigMap, never by editing service resources (research.md D5).

## Service-to-service (FR-045, FR-046)

`order-service` resolves `auth-service`'s JWKS through **cluster DNS by service name**:

```text
AUTH_SERVICE_URL = http://auth-service.hydra-app.svc.cluster.local:8083
```

Pod addresses MUST NOT be used. The issuer identifier (`AUTH_SERVICE_ISSUER=hydra-auth-service`) stays an **opaque string** and is never turned into a resolvable address (FR-046) — a distinction that matters because `jwk-set-uri` and `issuer-uri` sit adjacent in `order-service`'s configuration and conflating them is an easy, silent mistake.

## Network policy (FR-054, FR-073)

Default deny in `hydra-app` and `hydra-data`, then:

| From | To | Allowed |
|---|---|---|
| Cilium Envoy (gateway) | `auth-service`, `order-service` | ✅ |
| `order-service` | `auth-service` | ✅ |
| `auth-service`, `order-service` | Postgres, Redis | ✅ |
| Migration/fixture Jobs | Postgres | ✅ |
| All workloads | kube-dns | ✅ |
| Anything else | Postgres, Redis, `auth-service` | ❌ |

**Proven, not configured**: a real unauthorised pod attempts each forbidden path and each attempt fails, while the authorised equivalents succeed — 100% / 0%, repeatably (FR-073, SC-013). A policy that has never been tested against a real caller is a YAML file, not a control.

## Autoscaling (FR-070..072)

HPA on both services, driven by real observed metrics — never simulated or hard-coded. When workstation resources prevent scaling, the scaling test reports the constraint **explicitly** and does not report success (FR-072, SC-016). This is the requirement most likely to be quietly faked, which is why the spec calls it out and why the test's failure mode is a reported constraint rather than a green tick.
