# Headlamp

## What it is
A lightweight cluster console, installed **in** the cluster.

## Why it exists here
FR-087 says install a console covering nodes, namespaces, pods, deployments,
services, events, logs and resource usage. Headlamp covers all eight.

**k9s was rejected on the wording**: it is a terminal client installed on the
host, not a console installed in the cluster, and FR-088's "each behind its own
access operation" implies a reachable endpoint.

## What problem it solves
Looking at the cluster without composing a `kubectl` incantation — which matters
most when you do not yet know what you are looking for.

## How it works
An in-cluster deployment with its own service account, reached through a
port-forward.

## How to inspect it
```bash
make console-cluster     # → http://localhost:8081
```

## How to break it
```bash
kubectl -n hydra-delivery scale deploy headlamp --replicas=0
```
Nothing else is affected. That is the point of a console: it observes and it is
not on any request path.

## How to recover it
```bash
kubectl -n hydra-delivery scale deploy headlamp --replicas=1
```

## The security posture, stated plainly
Headlamp runs with a **cluster-admin** service account. In in-cluster mode it
acts with its own identity for every action a user takes in the UI, so a
read-only binding would make the console look broken rather than make it safe.

The honest form is: grant what it needs, confine it to a loopback port-forward,
and say so. This is the single most privileged thing in the lab.

## Production equivalent
A console behind SSO, with per-user RBAC and audit logging — where the console
impersonates the *user* rather than acting as itself. That is the difference
that matters, and it is not a small one.
