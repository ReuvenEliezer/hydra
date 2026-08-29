# Networking

How packets actually move in this cluster (FR-025).

The short version: **there is no kube-proxy, no iptables service chain and no
overlay tunnel.** Cilium programs eBPF into the kernel and that is the datapath.

---

## The network provider

Cilium, and only Cilium. The cluster is created with `disableDefaultCNI: true`,
so nodes stay `NotReady` until Cilium runs — that is the expected state between
`cluster-create` and the `cilium` checkpoint, and `make debug` says so rather
than reporting it as a fault.

```bash
kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg status
```

## kube-proxy replacement

The cluster is created with `kubeProxyMode: none`. **There is no kube-proxy
DaemonSet at all**, and `make net-status` asserts its absence — enabling the
replacement alongside a running kube-proxy would produce a cluster where neither
path is the one under test.

What that changes:

| | kube-proxy | Cilium's replacement |
|---|---|---|
| Mechanism | iptables (or IPVS) rules per Service | eBPF programs attached at the socket and tc layers |
| Cost of a Service | grows the rule chain every packet traverses | a hash lookup in a BPF map |
| Where translation happens | on the wire, after the packet is built | at `connect()` time for socket-based load balancing — the packet is built with the backend address already in it |

The last row is the one that surprises people: with socket load balancing, a
`tcpdump` inside the pod never shows the ClusterIP. The translation happened
before the packet existed.

```bash
kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg service list
```

## The kernel datapath

`routingMode: native` — no VXLAN, no Geneve, no encapsulation. Pod traffic is
routed between nodes directly on the shared Docker network, with
`autoDirectNodeRoutes: true` installing the routes.

Chosen because it is one fewer layer between a packet and an explanation. A
tunnel would work equally well and would mean every `tcpdump` shows an outer
header before the packet you wanted.

`ipv4NativeRoutingCIDR: 10.244.0.0/16` tells Cilium which addresses are pod
addresses, so it does not masquerade traffic that should stay internal.

## Pod and Service networking

| | |
|---|---|
| Pod CIDR | `10.244.0.0/16`, carved into per-node ranges |
| IPAM | `kubernetes` — the node's `podCIDR` allocation |
| Service CIDR | `10.96.0.0/16` (kind default) |
| DNS | CoreDNS at `10.96.0.10` |

Pod addresses are **ephemeral**. Nothing in this lab addresses a pod directly,
and `AUTH_SERVICE_URL` is a Service FQDN for exactly that reason: a pod address
works until the next restart and then produces an outage that looks like a JWKS
problem.

## Network policy

Default-deny in `hydra-app` and `hydra-data`, then exactly the permitted edges.

**Enforcement mode is `default`**, not `always`: a workload with no policy
selecting it is unrestricted, one with any policy selecting it is restricted to
what that policy allows. `always` would deny kube-system traffic before any
policy existed and deadlock the cluster's own bootstrap.

### The DNS rule everyone forgets

```yaml
egress:
  - to:
      - namespaceSelector: {matchLabels: {kubernetes.io/metadata.name: kube-system}}
        podSelector: {matchLabels: {k8s-app: kube-dns}}
    ports: [{protocol: UDP, port: 53}, {protocol: TCP, port: 53}]
```

Without it the symptom is not "denied" — it is a **name-resolution timeout**,
which reads as a CoreDNS fault and sends the investigation somewhere else
entirely.

### The one rule that cannot be a standard NetworkPolicy

Gateway traffic does **not** carry the identity of a kube-system pod. When
Cilium's Envoy proxies to a backend, the connection carries `reserved:ingress`.
A standard NetworkPolicy has no way to name that, so the traffic falls through
to default-deny — observed as:

```
upstream connect error or disconnect/reset before headers. reset reason: connection timeout
```

with routes `Accepted` and pods healthy.

`fromEntities: [ingress]` exists only in `CiliumNetworkPolicy`, so that single
rule is a Cilium CRD. Everything else in the file remains standard, because
everything else is expressible as one.

**This is a real portability cost of Kubernetes-as-edge**, and it is invisible
until traffic actually flows. It is recorded in
[edge-finding.md](edge-finding.md).

### Policy is proven, not configured

`tests/failure/network-policy.sh` stands up a genuinely unauthorised pod — its
own namespace, no lab labels — and has it attempt Postgres, Redis and
auth-service. Each must fail **100%** of attempts while the authorised
equivalents succeed **100%** (SC-013).

The authorised probe uses the **same image and the same method** as the
intruder, differing only in labels. That is what isolates the variable: an
earlier version used a different tool for the authorised half and could not
distinguish "denied by policy" from "the tool does not work".

```bash
make test-netpol
```

## The L7 proxy and the Gateway

`l7Proxy: true` enables Cilium's Envoy, which is both the L7 policy enforcement
point and **the Gateway API data plane**. One Envoy, two jobs — which is what
keeps FR-029 satisfied: Envoy is here as Cilium's data plane, not as an
independently managed gateway product.

The full request path is in [north-south-path.md](north-south-path.md).

## Observing traffic

```bash
kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg monitor --type drop
kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg endpoint list
```

`--type drop` is the one to reach for when something is denied: it names the
identity and the policy verdict, which turns "connection timeout" into an answer.

Hubble's relay is enabled (its UI is disabled in reduced mode), so
`hubble observe` works from the CLI either way.

## Testing it

```bash
make net-status   # agent health per node, kube-proxy replacement, Envoy readiness
make net-test     # REAL pod-to-pod and pod-to-Service traffic
```

`net-test` sends packets rather than inspecting configuration, and it reports
explicitly whether a **cross-node** path was exercised — a same-node-only test
passes on a broken cross-node datapath, which is the failure most worth catching
on a multi-node cluster.

## Production equivalents

| Lab | Production |
|---|---|
| kind nodes as containers on one host | Real nodes across zones |
| Native routing on a Docker bridge | VPC routing, or a tunnel where the substrate demands it |
| One `/16` pod CIDR | Planned per-zone allocations against a real address budget |
| No encryption between nodes | WireGuard/IPsec transparent encryption, or a mesh |
| CoreDNS defaults | Tuned cache, NodeLocal DNSCache at scale |
| Policy tested by one drill | Policy tested by drills **and** enforced in CI against every change |
