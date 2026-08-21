#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# reduced-mode-notice.sh — what reduced-footprint mode disables, and what that
# makes UNAVAILABLE (FR-091, D18).
#
# The second half is the important half. A reduced mode that quietly stops
# checking things is worse than one that fails, because the suite still reports
# green. So every scenario lost here is reported SKIPPED-BY-CONFIGURATION and
# never PASS.
# ---------------------------------------------------------------------------
set -uo pipefail
LAB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

cat <<'NOTICE'

  ─── REDUCED-FOOTPRINT MODE ──────────────────────────────────────────────

  DISABLED:
    - Tempo (the trace store)
    - Hubble UI (the relay stays, so `hubble observe` still works)
    - Replica counts lowered from 3 to 2

  RETAINED, deliberately:
    - Both services as real multi-instance Deployments  (2, never 1)
    - Postgres and Redis as real StatefulSets
    - Cilium, Gateway API, NetworkPolicy, autoscaling
    - Every failure drill except the trace-dependent one

  Two replicas rather than one is not a compromise, it is the floor. FR-069's
  properties — exactly one credential rotation succeeds across concurrent
  attempts (SC-010), and a per-address limit of N admits N across ALL replicas
  rather than N per replica (SC-011) — are unobservable on a single replica.
  A single-replica lab would report those tests green while testing nothing.

  CONSEQUENTLY UNAVAILABLE:
    - SC-012, the end-to-end trace scenario.
      `make test` reports it SKIPPED-BY-CONFIGURATION. It is NEVER reported as
      a pass in this mode. If you need SC-012, run `make setup` instead.

  ─────────────────────────────────────────────────────────────────────────

NOTICE
