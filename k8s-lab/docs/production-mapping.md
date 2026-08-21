# Production mapping

What each lab component corresponds to in a real deployment, and — more usefully
— **which differences do not transfer** (FR-112, FR-055).

The lab is a teaching and measurement environment. Some of what it demonstrates
carries over directly; some of it is an artifact of running on one machine. This
page separates the two, because the second kind is where confident people get
hurt.

> **The local cluster does not behave identically to a managed cloud cluster.**
> Nothing on this page should be read as claiming otherwise.

---

## Component mapping

| Lab | Production | Transfers? |
|---|---|---|
| kind, 3 nodes on one host | Managed Kubernetes (EKS/GKE/AKS), nodes across zones | **Partly.** The API and the workload model transfer. Failure behaviour does not |
| Local registry, plain HTTP, no auth | Managed registry with TLS, IAM-scoped pulls, signing, scanning | Concepts yes, security posture no |
| Cilium, self-installed | Cilium, or the provider's CNI | Yes — this is the same software |
| Gateway API + Cilium Envoy | Gateway API + a cloud load balancer in front | **Mostly.** The route model transfers; the L4 entry point does not |
| Postgres StatefulSet, hostPath | Managed Postgres (RDS/Cloud SQL) | Interface yes, operations no |
| Redis StatefulSet, hostPath | Managed cache (ElastiCache/Memorystore) | Same |
| Kubernetes Secrets | Managed secret store + CSI driver or operator | Interface yes, security no |
| Lab CA + one wildcard cert | ACM / cert-manager with a real issuer | Concepts yes |
| Argo CD from a local bare repo | Argo CD from a hosted repo with webhooks | Yes |
| Grafana anonymous-admin | Grafana with SSO and RBAC | Concepts yes |
| Headlamp with cluster-admin | Console with per-user SSO and scoped RBAC | Concepts yes, **security no** |

---

## Differences that do not transfer

These are the ones worth memorising.

### 1. Node failure is not simulated

`docker stop` on a node container is an orderly shutdown on the same kernel.

Real node failure means: an unhealthy instance, a **replacement provisioned by
the node group**, volumes detaching and re-attaching, and often a messy
in-between state where the kubelet is hung but the network still answers.

Nothing here replaces a node. Capacity is permanently reduced until you start
the container again — which changes the entire recovery story. The node-stop
drill prints this in full every time it runs, for exactly this reason.

### 2. Storage is a hostPath, and that is not a volume

kind's default StorageClass is a hostPath provisioner:

- **no replication** — one disk, one copy;
- **no snapshots**;
- **the data is gone with the node**;
- a PVC **pins its pod to that node** forever.

A cloud volume detaches and re-attaches elsewhere. Every conclusion about
stateful failover drawn here would be wrong in production.

### 3. There is no load balancer

Traffic reaches the gateway through a **fixed NodePort** bound by kind's
`extraPortMappings`. There is no L4 load balancer, no health-check-driven target
draining, no connection draining on deregistration, no cross-zone balancing.

Production has one, and it fails in its own ways: pre-warming, idle timeouts
shorter than your keep-alive, and health checks that disagree with readiness
probes.

### 4. One zone, one machine, no blast radius

No zone-level failure. No correlated failure. No network partition between
nodes that are genuinely apart. `topologySpreadConstraints` are configured and
exercised, but "spread across two containers on one laptop" demonstrates the
mechanism, not the protection.

### 5. Latency is unrealistically good

Every hop is on one machine. Postgres responds in microseconds. There is no
cross-AZ latency, no packet loss, no noisy neighbour.

**Any timeout tuned here will be wrong in production**, and wrong in the
dangerous direction: too tight.

### 6. Secrets are base64 in etcd

Created by a shell script, stored unencrypted-at-rest by default, readable by
anyone with namespace access, never rotated. That is acceptable for a loopback
lab and acceptable nowhere else.

### 7. Certificates are a lab CA

One CA, one wildcard certificate, trusted only by explicitly passing the CA to
curl and the JVM. No public trust chain, no OCSP, no rotation, no revocation.

And one lab-specific quirk worth knowing: **a `*.localhost` wildcard is rejected
by mainstream TLS clients** because `localhost` is a public suffix, so the lab's
certificate enumerates tenant hostnames. With a real base domain the wildcard
works. See [known-gaps.md](known-gaps.md) §4.

### 8. The consoles have no authentication

Grafana is anonymous-admin. Argo CD is anonymous-admin. Headlamp runs with a
**cluster-admin** service account. All three are reachable only through a
port-forward from the machine they run on, which is the only thing making that
acceptable.

There is deliberately no credential to leak — an admin password in a values file
would be a secret in the tracked tree.

### 9. Rate limits are shared, and that part **does** transfer

Worth calling out as the exception. The limiter is Redis-backed, so a limit of N
admits N **across all replicas**, not N per replica — and SC-011 measured
exactly that on three replicas. That property transfers directly, and it is the
one most commonly got wrong by in-memory limiters that look fine in every
single-instance test.

### 10. Schema migration is Hibernate through a Job

Production migration means versioned, reviewed, reversible changes with a
tested rollback. The lab runs Hibernate `ddl-auto` in a single-instance Job,
which makes the concurrency hazard structurally impossible but is **not** a
migration story. Liquibase is present, wired, and does not run — see
[known-gaps.md](known-gaps.md) §2.

---

## What the lab does establish

Not everything is an artifact. These carry over:

- **The Gateway API route model** — path matching, filters, timeouts, and
  attaching routes to a gateway someone else owns.
- **`Host` preservation through TLS termination.** Proven against a real gateway
  rather than a stand-in, which is the first time that has happened.
- **NetworkPolicy behaviour**, including the finding that gateway ingress needs
  a Cilium CRD to express at all.
- **Atomic credential rotation across replicas** (SC-010) — 120 concurrent
  rotations, one credential issued.
- **Shared rate limiting across replicas** (SC-011).
- **Fail-closed behaviour when the cache is gone** (FR-056) — losing Redis
  rejects requests rather than passing them through unthrottled.
- **Rolling updates with `maxUnavailable: 0`** producing zero failed requests.
- **The probe distinction**: readiness controls endpoint membership, liveness
  controls restarts, and a liveness probe that depends on the database turns a
  database blip into a rolling restart of every replica.

---

## A migration checklist

If this lab were the basis for a real deployment:

1. **Storage** — replace hostPath with real volumes, or move the datastores out
   to managed services. Re-test every stateful assumption.
2. **Secrets** — a managed store with rotation and audit. Delete the shell
   script that generates them.
3. **Certificates** — a real issuer. Add renewal, monitor expiry, alert on it.
4. **Migrations** — decide the Liquibase question deliberately. Do not let it be
   decided by someone adding a dependency.
5. **Ingress** — a real load balancer in front of the Gateway. Re-tune every
   timeout; the lab's are calibrated for microsecond latency.
6. **Consoles** — SSO and RBAC. Remove cluster-admin from Headlamp.
7. **Observability** — tail-based sampling, a log store, and alerts that reach a
   person.
8. **Capacity** — re-derive every request and limit from production traffic. The
   lab's are starting points and say so ([resource-tuning.md](resource-tuning.md)).
9. **The edge question** — read [edge-finding.md](edge-finding.md) before
   assuming this architecture is the answer.
