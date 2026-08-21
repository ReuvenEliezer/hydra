# The lab registry

The lab runs its own container registry so the cluster obtains images the way a
real cluster does — by pulling a published, immutably tagged image — rather than
by having them handed to it.

## Why a registry at all, when `kind load` exists

`kind load docker-image` copies an image straight into each node's image store.
It works, it is faster, and it is the wrong default here, for two reasons:

1. **It bypasses the pull.** The pull is a real step that fails in real ways —
   wrong tag, missing mirror, unreachable registry, wrong architecture. A lab
   that never pulls never exercises any of them, and the first time anyone meets
   `ImagePullBackOff` it will be somewhere that matters.
2. **It has no production equivalent.** Nothing in a managed cluster side-loads
   an image into a node. Modelling a step that does not exist teaches a workflow
   that does not transfer.

`kind load` remains available as the documented fallback (FR-020), through
`k8s-lab/scripts/registry.sh load <image:tag>`. It prints a notice saying it is a
fallback every time it runs.

## The four addresses

One registry, four different strings. This is FR-019, and it is the single most
confusing thing about a local registry: every address below refers to the same
container, and using the wrong one produces an error that names the wrong
component.

| # | From | Address | Notes |
|---|---|---|---|
| 1 | The workstation | `localhost:5001` | The host port binding. What `docker push` uses. |
| 2 | A node container | `hydra-lab-registry:5000` | Both are on the `kind` docker network, so the container name resolves. `localhost` here is the *node*, which runs no registry. |
| 3 | containerd, inside a node | via `/etc/containerd/certs.d/localhost:5001/hosts.toml` | containerd needs an explicit mirror entry. It does not infer one. |
| 4 | A pod spec | `localhost:5001/hydra/auth-service:<sha>` | The image reference Kubernetes stores. Resolvable only because (3) maps it onto (2). |

The chain that makes an image pull work is **4 → 3 → 2**. Address 1 never
participates in a pull; it is only how images get *in*.

### The failure this prevents

Without the mirror in (3), a pod referencing `localhost:5001/...` causes the
kubelet to ask the node's own loopback address. Nothing is listening there. The
pod reports `ErrImagePull` / `ImagePullBackOff` with a connection-refused
message — while `curl http://localhost:5001/v2/_catalog` from the workstation
returns the image quite happily. Every observable signal says the registry is
healthy, because from where you are looking, it is.

`make registry-status` is built around exactly this: it pushes a probe image and
then makes **the cluster pull it**, because only a pull proves the chain.

## Tags

Tags are derived from the git revision and are immutable (FR-017):

```
localhost:5001/hydra/auth-service:8f3c1d2
localhost:5001/hydra/auth-service:8f3c1d2-dirty     # uncommitted changes present
```

Never `latest`. A tag is never re-pushed — a change produces a new tag, so
"which code is running in that pod" always has an answer.

The `-dirty` suffix is not a warning to be dismissed: it means the image was
built from a working tree that does not match any commit, so the image cannot be
rebuilt from source later. `make image-build` prints it prominently and the
benchmark refuses to record a result against a dirty tag.

## Operations

```bash
make registry-create    # create and wire it into the cluster (idempotent)
make registry-status    # prove by an executed pull that the cluster can reach it
make image-publish      # push both service images under revision-derived tags
```

Inspect the catalogue directly:

```bash
curl -s http://localhost:5001/v2/_catalog | jq
curl -s http://localhost:5001/v2/hydra/auth-service/tags/list | jq
```

## Production mapping

| Lab | Production |
|---|---|
| A `registry:3` container on the workstation | A managed registry (ECR, GAR, ACR, Harbor) |
| Plain HTTP, `skip_verify = true` in the mirror | TLS with a real certificate chain |
| No authentication | IAM-scoped or token-based pull credentials, per workload |
| Immutable tags by convention | Immutability enforced by the registry, plus signing and scanning |

The lab's registry has no authentication and no TLS. That is acceptable for a
loopback-bound container on a developer workstation and is acceptable nowhere
else; see [production-mapping.md](production-mapping.md).
