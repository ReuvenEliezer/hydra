#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# failure/run.sh — the drill runner (FR-093, FR-097).
#
#   run.sh all            every drill, in order
#   run.sh <name>         one drill, individually runnable (FR-093)
#
# Order matters. The destructive drills run LAST, because a drill that leaves
# the environment even briefly degraded makes every result after it harder to
# interpret — and node-stop in particular takes minutes to fully settle.
# ---------------------------------------------------------------------------
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="$(cd "${HERE}/../.." && pwd)"
source "${LAB_ROOT}/scripts/lib/versions.sh"
source "${LAB_ROOT}/scripts/lib/log.sh"

# The nine drills of data-model §10, in execution order.
ALL_DRILLS=(
  pod-delete
  bad-image
  readiness-fail
  network-policy
  rolling-update
  cache-down
  concurrent-rotation
  cross-replica-limit
  node-stop
)

usage() {
  printf 'usage: run.sh {all|<drill>}\n\nDrills:\n'
  local d
  for d in "${ALL_DRILLS[@]}"; do printf '  %s\n' "$d"; done
  printf '\nEach drill triggers a controlled fault, asserts on what must be OBSERVABLE,\n'
  printf 'restores the environment, and then verifies the restore. A drill that cannot\n'
  printf 'restore the environment FAILS (SC-014).\n'
}

run_one() {
  local name="$1"
  local script="${HERE}/${name}.sh"
  if [[ ! -x "$script" ]]; then
    log_error "no such drill: ${name}"
    usage
    return 2
  fi
  printf '\n'
  printf '════════════════════════════════════════════════════════════\n'
  printf '  %s\n' "$name"
  printf '════════════════════════════════════════════════════════════\n'
  "$script"
}

case "${1:-}" in
  ""|-h|--help) usage; exit 0 ;;
  all)
    PASSED=(); FAILED=()
    for d in "${ALL_DRILLS[@]}"; do
      if run_one "$d"; then PASSED+=("$d"); else FAILED+=("$d"); fi
    done
    printf '\n'
    printf '════════════════════════════════════════════════\n'
    printf '  failure drills — summary\n'
    printf '════════════════════════════════════════════════\n'
    for d in ${PASSED[@]+"${PASSED[@]}"}; do printf '  PASS  %s\n' "$d"; done
    for d in ${FAILED[@]+"${FAILED[@]}"}; do printf '  FAIL  %s\n' "$d"; done
    printf '\n'
    if (( ${#FAILED[@]} > 0 )); then
      printf 'FAIL — %d drill(s) failed.\n' "${#FAILED[@]}"
      printf 'If a RESTORE failed, the environment is degraded and later results are suspect.\n'
      printf 'Check with: make debug\n'
      exit 1
    fi
    printf 'PASS — all %d drills passed and every restore was verified.\n' "${#PASSED[@]}"
    exit 0
    ;;
  *) run_one "$1" ;;
esac
