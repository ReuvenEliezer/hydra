#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# test.sh — `make test` (FR-099).
#
# The FAST validation path: smoke, integration, edge conformance and the
# relevant failure drills, in that order, against the environment as it stands.
#
# TWO PROHIBITIONS, both from FR-099:
#   - it MUST NOT destroy or recreate the cluster
#   - it MUST NOT run validate-full
#
# The reason is workflow, not purity: a `make test` that rebuilds the world is a
# `make test` nobody runs, and an inner loop that takes forty minutes is not an
# inner loop. `make validate-full` exists for the other job.
#
# Order matters. Smoke first because everything downstream assumes the platform
# is up, and a failing smoke check makes an integration failure meaningless.
# ---------------------------------------------------------------------------
set -uo pipefail

LAB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${LAB_ROOT}/scripts/lib/versions.sh"
source "${LAB_ROOT}/scripts/lib/log.sh"

FAILED=()
PASSED=()
SKIPPED=()

run_stage() {
  local name="$1"; shift
  printf '\n'
  printf '═══ %s ═══\n' "$name"
  if "$@"; then
    PASSED+=("$name")
    return 0
  fi
  FAILED+=("$name")
  return 1
}

log_suite "test (fast path)"
printf 'This does not recreate the cluster and does not run validate-full (FR-099).\n'

# A cluster must exist. Saying so plainly beats seven suites failing to connect.
if ! kubectl --context "${LAB_KUBECONTEXT}" cluster-info >/dev/null 2>&1; then
  log_error "no cluster — run 'make setup' first"
  exit 1
fi

run_stage "smoke"       "${LAB_ROOT}/tests/smoke/run.sh"       || true
run_stage "integration" "${LAB_ROOT}/tests/integration/run.sh" || true

# Edge conformance is Hydra's EXISTING suite, run through Maven against the lab
# gateway. It needs a JVM; when there is none, that is reported as a skip with
# its cause rather than quietly omitted.
if "${LAB_ROOT}/scripts/edge-conformance.sh" --available >/dev/null 2>&1; then
  run_stage "edge-conformance" "${LAB_ROOT}/scripts/edge-conformance.sh" lab || true
else
  SKIPPED+=("edge-conformance (no usable Maven/JVM — 'make doctor' names it)")
fi

# The failure drills `make test` runs: fast, non-destructive, and each restores
# what it broke. The node-stop and rolling-update drills are deliberately NOT
# here — they take minutes and belong to `make test-failure`.
run_stage "failure: pod-delete"     "${LAB_ROOT}/tests/failure/run.sh" pod-delete     || true
run_stage "failure: network-policy" "${LAB_ROOT}/tests/failure/run.sh" network-policy || true

printf '\n'
printf '════════════════════════════════════════════════\n'
printf '  make test — summary\n'
printf '════════════════════════════════════════════════\n'
for s in ${PASSED[@]+"${PASSED[@]}"};  do printf '  PASS     %s\n' "$s"; done
for s in ${SKIPPED[@]+"${SKIPPED[@]}"}; do printf '  SKIPPED  %s\n' "$s"; done
for s in ${FAILED[@]+"${FAILED[@]}"};  do printf '  FAIL     %s\n' "$s"; done
printf '\n'

if (( ${#FAILED[@]} > 0 )); then
  printf 'FAIL — %d stage(s) failed.\n' "${#FAILED[@]}"
  printf 'Run `make dump` for the cluster-wide picture, or re-run one stage directly.\n'
  exit 1
fi
printf 'PASS — every stage that ran, passed.\n'
(( ${#SKIPPED[@]} > 0 )) && printf 'Note: %d stage(s) were skipped and therefore establish nothing.\n' "${#SKIPPED[@]}"
exit 0
