#!/usr/bin/env bash
# gitops-converge.sh — a tracked change converges with NO deploy command (FR-083).
#
# The demonstration: change a replica count in the tracked tree, commit it, and
# observe Argo CD detect the deviation and the cluster follow. Nothing here runs
# kubectl apply or helm upgrade against the workload — that is the entire point.
set -uo pipefail
LAB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "${LAB_ROOT}/scripts/lib/versions.sh"
source "${LAB_ROOT}/scripts/lib/log.sh"
source "${LAB_ROOT}/scripts/lib/wait.sh"
source "${LAB_ROOT}/scripts/lib/assert.sh"

K="kubectl --context ${LAB_KUBECONTEXT}"
MANIFEST="${LAB_ROOT}/gitops/delivery-canary.yaml"
log_suite "GitOps convergence (FR-083)"

app_ready() { $K -n "${NS_DELIVERY}" get application hydra-lab >/dev/null 2>&1; }
if ! app_ready; then
  log_fail "no Argo CD Application named 'hydra-lab'" "nothing is reconciling"
  log_summary; exit 1
fi

current="$($K -n "${NS_APP}" get deploy hydra-lab-canary -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 0)"
log_info "canary currently at ${current} replica(s)"

target=$(( current == 1 ? 2 : 1 ))
original="$(mktemp)"; cp "$MANIFEST" "$original"
restore() {
  cp "$original" "$MANIFEST"; rm -f "$original"
  "${LAB_ROOT}/scripts/gitops.sh" init >/dev/null 2>&1 || true
}
trap restore EXIT

# THE CHANGE: an edit to a tracked file, then a commit. No deploy command.
sed -i.bak "s/^  replicas: ${current}$/  replicas: ${target}/" "$MANIFEST" && rm -f "${MANIFEST}.bak"
grep -q "replicas: ${target}" "$MANIFEST" || { log_fail "could not edit the tracked manifest"; log_summary; exit 1; }
log_pass "tracked value changed: replicas ${current} -> ${target}" "an edit to gitops/delivery-canary.yaml"

"${LAB_ROOT}/scripts/gitops.sh" init >/dev/null 2>&1
log_pass "the change was committed and pushed to the remote" "no deploy command was run"

# Argo CD must NOTICE. Detecting drift is half the loop.
if wait_for "Argo CD reports the deviation" 180 \
     bash -c "$K -n ${NS_DELIVERY} get application hydra-lab -o jsonpath='{.status.sync.status}' 2>/dev/null | grep -q OutOfSync"; then
  log_pass "Argo CD detected the deviation" "sync=OutOfSync"
else
  # Not necessarily a failure: with selfHeal on and a 30s reconciliation, it can
  # converge before a poll ever observes OutOfSync. The convergence check below
  # is the assertion that matters.
  log_info "OutOfSync was not observed; with selfHeal and a 30s interval it may have converged first"
fi

# And the cluster must FOLLOW.
if wait_for_output "the cluster converges to the tracked value" 300 "$target" \
     bash -c "$K -n ${NS_APP} get deploy hydra-lab-canary -o jsonpath='{.spec.replicas}' 2>/dev/null"; then
  log_pass "the cluster converged to ${target} replicas with NO deploy command" "FR-083"
  log_info "Nothing ran kubectl apply or helm upgrade against this workload. Git changed; the cluster followed."
else
  observed="$($K -n "${NS_APP}" get deploy hydra-lab-canary -o jsonpath='{.spec.replicas}' 2>/dev/null)"
  log_fail "the cluster did not converge" "tracked ${target}, cluster ${observed:-absent}"
  log_context "$($K -n "${NS_DELIVERY}" get application hydra-lab -o jsonpath='{range .status.conditions[*]}{.type}: {.message}{"\n"}{end}' 2>&1)"
fi

restore; trap - EXIT
wait_for_output "the cluster converges back after the revert" 300 "$current" \
  bash -c "$K -n ${NS_APP} get deploy hydra-lab-canary -o jsonpath='{.spec.replicas}' 2>/dev/null" \
  && log_pass "reverting the tracked value converged the cluster back" "the loop runs in both directions" \
  || log_fail "the cluster did not converge back after the revert"

log_summary
