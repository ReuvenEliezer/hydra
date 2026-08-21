# Argo CD

## What it is
The delivery controller, reconciling a bare git repository that lives inside the
lab and is bind-mounted into every node.

## Why it exists here
FR-083 wants a tracked change to converge with no deploy command. **Chosen over
Flux for one reason**: FR-088 requires a delivery *console* reachable by its own
access operation, and Argo CD ships one.

## What problem it solves
Drift. The cluster's state and someone's `kubectl` history stop being the same
thing.

## How it works
A local **bare** repository — no network, no hosting account, no credentials,
which keeps the offline steady state intact. The repo-server pod reads it via a
hostPath backed by a kind `extraMount`.

It owns `gitops/delivery-canary.yaml`, **not** the umbrella chart. Two
controllers owning the same objects produces ownership conflicts, and Argo's
`selfHeal` would actively revert whatever the Helm CLI did
([known-gaps.md](../known-gaps.md) §8).

## How to inspect it
```bash
make argocd-status      # per-Application sync and health, read from the resource
make console-delivery   # the UI
kubectl -n hydra-delivery get applications -o wide
```
`argocd-status` reads the Application resources, not the UI — a delivery plane
that is *running* and reconciling nothing is not working, and pod readiness
cannot tell the difference.

## How to break it
**Introduce drift and watch it healed:**
```bash
kubectl -n hydra-app scale deploy hydra-lab-canary --replicas=5
make argocd-status      # OutOfSync
# wait ~30s — selfHeal reverts it
```

**Break the repository:**
```bash
kubectl -n hydra-delivery scale deploy argocd-repo-server --replicas=0
make argocd-status      # the Application can no longer be compared
```

## How to recover it
```bash
kubectl -n hydra-delivery scale deploy argocd-repo-server --replicas=1
./scripts/gitops.sh init
make argocd-status
```

## What actually went wrong here
**The repo-server is a pod and cannot read a `file://` path on the workstation.**
The failure was `repository not found`, which reads as a bad URL rather than a
filesystem boundary. Fixed with a kind `extraMount` — and then broke again
because the mount was only on the **control-plane** node, so a repo-server
scheduled on a worker got
`hostPath type check failed: /gitops-remote is not a directory`. A hostPath is a
promise about every node the pod might land on.

## Production equivalent
Argo CD against a hosted repository with webhooks, SSO, RBAC, projects, and
sealed or externally-managed secrets. And the umbrella chart in git, with the
Helm CLI path deleted.
