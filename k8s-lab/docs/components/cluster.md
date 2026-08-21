# The kind cluster

## What it is
One control-plane node and two workers, each a container, with the default CNI
and kube-proxy **both disabled**.

## Why it exists here
Two workers rather than one because `topologySpreadConstraints` need somewhere to
spread and because FR-069's multi-instance properties need genuinely separate
nodes. `cluster.sh` refuses to render a config with fewer than two.

## What problem it solves
A Kubernetes API and a scheduler on a laptop, with the same objects and the same
semantics as a real cluster.

## How it works
`cluster/kind-cluster.yaml` is a **template**, rendered by `scripts/cluster.sh`
from `versions.env` — the worker count and node image are matrix values, so a
committed config carrying its own literals would be exactly the drift SC-022
forbids.

Three settings are load-bearing:

| Setting | Why |
|---|---|
| `disableDefaultCNI: true` | Cilium must be the sole provider. Nodes stay `NotReady` until it runs |
| `kubeProxyMode: none` | The kube-proxy replacement is only exercised if there is no kube-proxy to layer on |
| `extraPortMappings` | Host 443 → a **fixed** node port. The one deterministic exposure mechanism (FR-030) |
| `extraMounts` | The lab's bare git repo, on **every** node, so Argo CD's repo-server can read it wherever it lands |

## How to inspect it
```bash
make cluster-status    # what exists
make cluster-health    # whether it works — including whether the scheduler places a pod
kubectl get nodes -o wide
docker ps --filter name=hydra-lab
```
`status` and `health` are deliberately different questions: three `NotReady`
nodes is perfect status and no health at all.

## How to break it
```bash
docker stop hydra-lab-worker2
```
Watch scheduling and availability. Then read the node-stop drill's own caveats —
this is **not** a cloud node failure, and the differences are not cosmetic.

```bash
docker stop hydra-lab-control-plane
```
The API stops answering. Everything already running keeps running, which is
worth seeing once.

## How to recover it
```bash
docker start hydra-lab-worker2
kubectl get nodes -w
make cluster-health
```

## What actually went wrong here
**`mktemp` with a suffix after the `X`s.** BSD `mktemp` does not substitute them,
so the rendered config went to a literal filename and was empty — and
`kind create --config <empty file>` silently used its **defaults**: one node,
default CNI, kube-proxy on. A cluster that looked healthy and was the exact
opposite of what was declared. `cluster.sh` now refuses an empty render and
verifies the worker count.

## Production equivalent
Managed Kubernetes. What does **not** transfer: node replacement, real failure
modes, multi-zone topology, control-plane upgrades, and storage that survives a
node.
