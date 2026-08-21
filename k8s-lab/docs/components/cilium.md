# Cilium

## What it is
The cluster's **entire** networking layer: CNI, kube-proxy replacement,
NetworkPolicy engine, kernel-level observability (Hubble), and the Gateway API
implementation whose data plane is Envoy.

## Why it exists here
FR-022 asks for one provider covering all of those. Cilium is the only product
that does. FR-029 additionally requires Envoy to be consumed as the network
provider's data plane rather than as a standalone controller — which is exactly
Cilium's model.

## What problem it solves
Pods need addresses and routes; Services need translation; policy needs
enforcement; the gateway needs a data plane. Without a CNI the nodes never leave
`NotReady`.

## How it works
eBPF programs attached in the kernel. Native routing (no tunnel), socket-level
load balancing (translation happens at `connect()`, so a `tcpdump` inside the pod
never shows the ClusterIP), and identity-based policy rather than IP-based.

See [../networking.md](../networking.md).

## How to inspect it
```bash
make net-status
kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg status
kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg service list
kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg endpoint list
kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg monitor --type drop
```
`--type drop` is the one that turns "connection timeout" into an answer: it names
the identity and the policy verdict.

## How to break it
```bash
kubectl -n kube-system delete pod -l k8s-app=cilium --wait=false
```
Watch: existing connections survive (the eBPF programs stay loaded), but new
endpoints do not get programmed.

Harder:
```bash
kubectl -n kube-system scale deploy cilium-operator --replicas=0
```
Now new pods get no identity. Policy decisions for them become unpredictable.

## How to recover it
```bash
kubectl -n kube-system rollout restart ds/cilium
kubectl -n kube-system scale deploy cilium-operator --replicas=1
make net-status
```

## What actually went wrong here
Two real failures worth knowing:

**A JSON log format broke the chart's own Envoy bootstrap template.** The
rendered ConfigMap came out as `{"Error":"error converting YAML to JSON..."}` and
`cilium-envoy` crash-looped on `no such field: 'Error'` — three layers from the
cause.

**The operator probes for the Gateway API CRDs once, at startup.** If they are
absent it disables Gateway support permanently and does not retry. Every Gateway
then sits at `Waiting for controller` with nothing in its status explaining why.
Install the CRDs *before* Cilium.

## Production equivalent
Cilium, or the cloud provider's CNI. This is the same software; what changes is
that someone else runs the control plane and the failure modes involve real
networks.
