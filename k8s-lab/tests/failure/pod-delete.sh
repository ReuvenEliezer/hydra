#!/usr/bin/env bash
# pod-delete drill (FR-066, SC-008).
#
# Expected observable: a replacement pod reaches Ready AND the client's observed
# success rate stays >= 99% over 60 seconds. The second half is the real
# assertion — "a replacement appeared" is what Kubernetes always does, and says
# nothing about whether anyone lost service while it happened.
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/lib" && pwd)/drill.sh"

TARGET_DEPLOY="${1:-auth-service}"

drill_begin "pod-delete (${TARGET_DEPLOY})" \
  "a replacement reaches Ready and the client sees >=99% success over 60s" || { log_summary; exit 1; }

victim="$($K -n "${NS_APP}" get pods -l "app.kubernetes.io/name=${TARGET_DEPLOY}" \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
[[ -n "$victim" ]] || { log_fail "no pod to delete"; log_summary; exit 1; }

before="$($K -n "${NS_APP}" get deploy "${TARGET_DEPLOY}" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)"
log_info "deleting ${victim} (currently ${before} replicas Ready)"

# Start the client BEFORE the fault: the window that matters includes the
# moment of deletion, and a client started afterwards misses exactly the
# failures it exists to detect.
load_out="$(mktemp)"
"${LAB_ROOT}/tests/failure/lib/client-load.sh" 60 4 > "$load_out" &
load_pid=$!

$K -n "${NS_APP}" delete pod "$victim" --wait=false >/dev/null 2>&1
log_pass "trigger: pod deleted" "kubectl delete pod ${victim}"

if wait_for_output "a replacement reaches Ready" "${TIMEOUT_WORKLOAD_READY}" "$before" \
     bash -c "$K -n ${NS_APP} get deploy ${TARGET_DEPLOY} -o jsonpath='{.status.readyReplicas}' 2>/dev/null"; then
  log_pass "replacement Ready" "readyReplicas back to ${before}"
else
  log_fail "the replica count did not return to ${before}"
fi

wait "$load_pid" 2>/dev/null || true
result="$(cat "$load_out")"; rm -f "$load_out"
log_info "client: ${result}"

rate="$(printf '%s' "$result" | sed -n 's/.*rate=\([0-9.]*\).*/\1/p')"
assert_ge "client success rate over the deletion window (SC-008)" "${rate:-0}" "99"

# Nothing to restore: the Deployment already replaced the pod. Verified anyway,
# because "the controller handled it" is an assumption until it is checked.
drill_restore "no action needed — the Deployment replaces the pod" true
drill_end
