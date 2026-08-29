# The tracked desired state

What Argo CD reconciles (FR-083, FR-085, D15).

## What is here, and what is deliberately not

This directory holds a **delivery slice**: a small, self-contained workload that
Argo CD owns outright. Changing a value here and committing it converges the
cluster with no deploy command, which is the property FR-083 asks to be
demonstrated.

It does **not** contain the `hydra-lab` umbrella chart, and that omission is a
decision rather than an oversight.

The umbrella release is installed by `make app-deploy` through the Helm CLI. If
Argo CD also managed it, two controllers would own the same objects — and that
is not a hypothetical: this lab already hit the Helm form of it, where two
releases of one chart both claimed the shared NetworkPolicies and Helm correctly
refused with `invalid ownership metadata`. Putting Argo CD and the Helm CLI on
the same objects produces the same class of conflict with worse symptoms,
because Argo's `selfHeal` would actively revert whatever the CLI did.

So the split is explicit:

| Owned by | What |
|---|---|
| `make app-deploy` (Helm CLI) | the `hydra-lab` umbrella release — services, datastores, routes, policies |
| Argo CD | everything in this directory |

**What this demonstrates**: reconciliation, drift detection, self-healing and
convergence-without-a-deploy-command — on a real workload, through a real
controller, from a real git remote.

**What it does not demonstrate**: Argo CD managing Hydra's services themselves.
A production setup would put the umbrella chart in git and delete the Helm CLI
path entirely. `docs/known-gaps.md` records this as a divergence.

## No secrets, ever

The tracked tree carries Secret **names**; the Secrets themselves are created
out of band by `scripts/app.sh` at setup time (FR-085). `scripts/gitops.sh`
greps this directory for key material before every push, and the smoke suite
asserts the same thing independently — git history is the one place a mistake
cannot simply be deleted.

There is no sealed-secrets and no encrypted blob here. Both are real answers to
a real problem, and adopting one is a decision this feature has no mandate to
make. `docs/production-mapping.md` names the options.
