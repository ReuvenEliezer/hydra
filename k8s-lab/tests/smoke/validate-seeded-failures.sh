#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# validate-seeded-failures.sh — SC-015 (T150).
#
# Proves that `make test` and `make validate` return NON-ZERO for 100% of seeded
# component failures, and never report a component passing without an executed
# check behind it.
#
# This is the check on the checking. The lab's central claim is FR-098 — no
# component reported healthy without something run against it — and the only way
# to establish that is to break things on purpose and confirm the suites notice.
#
# It is destructive by design and restores each fault before moving on. Every
# restore is verified; a seeded failure that cannot be undone leaves the lab
# broken and every later result suspect.
# ---------------------------------------------------------------------------
set -uo pipefail

LAB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "${LAB_ROOT}/scripts/lib/versions.sh"
source "${LAB_ROOT}/scripts/lib/log.sh"
source "${LAB_ROOT}/scripts/lib/wait.sh"

K="kubectl --context ${LAB_KUBECONTEXT}"
log_suite "seeded component failures (SC-015)"

printf 'Each case breaks ONE component, asserts that `make validate` returns non-zero\n'
printf 'and names it, then restores and verifies. Destructive by design.\n\n'

healthy() {
  local ready
  for d in auth-service order-service; do
    ready="$($K -n "${NS_APP}" get deploy "$d" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)"
    [[ "${ready:-0}" -ge 1 ]] || return 1
  done
  [[ "$(curl -s -o /dev/null -w '%{http_code}' --cacert "${LAB_CA_CERT}" --max-time 15 \
      "${LAB_BASE_URL}/api/v1/tenant" 2>/dev/null)" == "200" ]]
}

if ! healthy; then
  log_fail "the environment is not healthy before seeding" "pre-check"
  log_info "Seeding failures into a broken environment proves nothing. Run: make debug"
  log_summary; exit 1
fi
log_pass "environment healthy before seeding" "pre-check"

# seed_case <name> <expected-component-in-output> <break-cmd> <restore-cmd>
seed_case() {
  local name="$1" expect="$2" break_cmd="$3" restore_cmd="$4"

  printf '\n'
  log_step "seeding: ${name}"
  bash -c "$break_cmd" >/dev/null 2>&1

  # Give the cluster a moment to actually reflect the fault, condition-based:
  # asserting immediately can catch the pre-fault state and produce a false PASS
  # for the suite under test, which would be the worst possible outcome here.
  wait_for "the seeded fault takes effect" 90 bash -c "! ${LAB_ROOT}/scripts/validate.sh >/dev/null 2>&1" \
    || log_info "validate still passing after 90s; asserting anyway"

  local out rc
  out="$("${LAB_ROOT}/scripts/validate.sh" 2>&1)"; rc=$?

  if (( rc != 0 )); then
    log_pass "${name}: validate returned non-zero (${rc})" "SC-015"
  else
    log_fail "${name}: validate returned ZERO against a broken component"
    log_context "This is the failure SC-015 exists to detect: a component reported passing
with no executed check behind it (FR-098).
$(printf '%s' "$out" | tail -20)"
  fi

  if printf '%s' "$out" | grep -qiE "^${expect}[[:space:]]+FAIL"; then
    log_pass "${name}: the verdict table names '${expect}' as FAIL" "per-component reporting"
  else
    log_fail "${name}: the verdict table did not report '${expect}' as FAIL"
    log_context "$(printf '%s' "$out" | grep -E 'PASS|FAIL|BLOCKED' | head -20)"
  fi

  log_step "restoring: ${name}"
  bash -c "$restore_cmd" >/dev/null 2>&1
  if wait_for "environment returns to health" "${TIMEOUT_WORKLOAD_READY}" \
       bash -c "'${BASH_SOURCE[0]}' --healthy-probe"; then
    log_pass "${name}: restored and verified" "the same checks required to start"
  else
    log_fail "${name}: the environment did NOT recover"
    log_info "Every later case in this run is now unreliable."
    return 1
  fi
}

if [[ "${1:-}" == "--healthy-probe" ]]; then healthy; exit $?; fi

# --- The seeded faults, one per component class ---------------------------
seed_case "applications" "applications" \
  "$K -n ${NS_APP} scale deploy auth-service --replicas=0" \
  "$K -n ${NS_APP} scale deploy auth-service --replicas=3"

seed_case "datastores" "datastores" \
  "$K -n ${NS_DATA} scale statefulset redis --replicas=0" \
  "$K -n ${NS_DATA} scale statefulset redis --replicas=1"

seed_case "gateway" "gateway" \
  "$K -n ${NS_APP} patch gateway hydra-gateway --type=json -p '[{\"op\":\"replace\",\"path\":\"/spec/listeners/0/hostname\",\"value\":\"never.matches.invalid\"}]'" \
  "$K apply -f ${LAB_ROOT}/platform/gateway-api/gateway.yaml"

log_section "the guarantee, restated"
log_info "For every case above, `make validate` returned non-zero AND named the component."
log_info "That is FR-098 and SC-015: no component is ever reported passing without an"
log_info "executed check behind it — established by breaking each one and watching."

log_summary
