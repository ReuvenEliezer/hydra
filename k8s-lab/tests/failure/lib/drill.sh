#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# drill.sh — the shared failure-drill harness (data-model §10, FR-097, SC-014).
#
# Every drill has the same five parts, in this order:
#
#   trigger              the controlled fault
#   expected_observable  what must be SEEN — not merely that nothing crashed
#   assertion            an executed check on that observable
#   restore              return the environment to its pre-drill state
#   restore_verification the standard health checks pass afterwards
#
# THE INVARIANT: a drill that cannot restore the environment FAILS. Leaving the
# lab broken is a drill failure, not a side effect — and a drill that reports
# success while leaving the next drill to run against wreckage is worse than one
# that never ran, because every result after it is suspect.
#
# `expected_observable` is the part that distinguishes a drill from a poke. It
# is not enough to delete a pod and observe that the cluster survived: the drill
# must state what should be observable and then observe it.
# ---------------------------------------------------------------------------
set -uo pipefail

_DRILL_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="$(cd "${_DRILL_LIB}/../../.." && pwd)"
source "${LAB_ROOT}/scripts/lib/versions.sh"
source "${LAB_ROOT}/scripts/lib/log.sh"
source "${LAB_ROOT}/scripts/lib/wait.sh"
source "${LAB_ROOT}/scripts/lib/assert.sh"

K="kubectl --context ${LAB_KUBECONTEXT}"

DRILL_NAME=""
DRILL_RESTORED=0

drill_begin() {
  DRILL_NAME="$1"
  log_suite "drill: ${DRILL_NAME}"
  printf 'expected observable: %s\n\n' "${2:-<not stated>}"

  # A drill against an already-broken environment measures nothing. Refusing is
  # more useful than producing a result nobody can interpret.
  if ! drill_environment_healthy --quiet; then
    log_fail "the environment is not healthy BEFORE the drill" "pre-drill check"
    log_info "A drill run against a broken environment produces an uninterpretable result."
    log_info "Fix it first: make debug"
    return 1
  fi
  log_pass "environment healthy before the drill" "pre-drill check"
  return 0
}

# The standard health checks, used both as a precondition and as the restore
# verification. Same checks both times, deliberately: "restored" means "back to
# the state we required to start".
drill_environment_healthy() {
  local quiet=0
  [[ "${1:-}" == "--quiet" ]] && quiet=1
  local ok=0

  local d
  for d in auth-service order-service; do
    local desired ready
    desired="$($K -n "${NS_APP}" get deploy "$d" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 0)"
    ready="$($K -n "${NS_APP}" get deploy "$d" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)"
    [[ "${ready:-0}" == "${desired:-0}" && "${desired:-0}" != "0" ]] || ok=1
  done

  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' --cacert "${LAB_CA_CERT}" \
    --max-time 15 "${LAB_BASE_URL}/api/v1/tenant" 2>/dev/null || echo 000)"
  [[ "$code" == "200" ]] || ok=1

  (( quiet )) || {
    if (( ok == 0 )); then
      log_pass "environment healthy" "all replicas Ready; gateway serves 200"
    else
      log_fail "environment not healthy" "replicas or gateway check failed (last HTTP ${code})"
    fi
  }
  return $ok
}

# drill_await_clean_rate_limit
#
# Waits until this address can sign in again. Drills run back to back, and
# several of them deliberately exhaust the per-address login limit — so the next
# drill's very first sign-in meets a 429 and the whole drill fails for a reason
# that has nothing to do with what it tests.
#
# This is a PRECONDITION, not a retry around a flaky assertion: it establishes a
# known starting state, and fails loudly if it cannot reach one.
drill_await_clean_rate_limit() {
  if wait_for "the rate-limit window is clear for this address" "${1:-240}" \
       bash -c "[[ \"\$(curl -s -o /dev/null -w '%{http_code}' --cacert '${LAB_CA_CERT}' --max-time 15 -X POST '${LAB_BASE_URL}/api/v1/auth/login' -H 'Content-Type: application/json' -d '{\"username\":\"labuser\",\"password\":\"lab-password-not-a-secret\"}' 2>/dev/null)\" == \"200\" ]]"; then
    log_pass "the rate-limit window is clear" "a known starting state"
    return 0
  fi
  log_fail "still rate-limited after the wait" "a previous drill exhausted the window"
  log_info "That is the limiter working correctly. Wait for the window to expire and re-run."
  return 1
}

# drill_restore <description> <command...>
# Runs the restore, then VERIFIES it. The verification is the point: a restore
# command that exits zero and leaves the environment broken is the failure mode
# this exists to catch.
drill_restore() {
  local desc="$1"; shift
  printf '\n'
  log_step "restoring: ${desc}"

  if "$@" >/dev/null 2>&1; then
    log_pass "restore command completed" "$*"
  else
    log_fail "restore command failed" "$*"
  fi

  if ! wait_for "environment returns to a healthy state" "${TIMEOUT_WORKLOAD_READY}" \
       bash -c "'${LAB_ROOT}/tests/failure/lib/drill.sh' --health-probe"; then
    log_fail "the environment did NOT return to a healthy state after the drill"
    log_info "A drill that cannot restore the environment is a FAILED drill (SC-014)."
    log_info "Every subsequent result in this run is suspect. Fix with: make debug"
    DRILL_RESTORED=0
    return 1
  fi

  log_pass "environment restored and verified" "the same checks the drill required to start"
  DRILL_RESTORED=1
  return 0
}

# Callable as a subcommand so wait_for can poll it in a subshell.
if [[ "${1:-}" == "--health-probe" ]]; then
  drill_environment_healthy --quiet
  exit $?
fi

drill_end() {
  if (( ! DRILL_RESTORED )); then
    log_fail "drill '${DRILL_NAME}' left the environment unrestored"
  fi
  log_summary
}
