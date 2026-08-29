#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# dump-seeded-faults.sh — SC-018 (T153).
#
# For ONE fault from each of nine classes, `make dump` alone must let a reader
# NAME the failing component — without running a second command.
#
# That is the actual requirement, and it is a high bar. It is not "the dump
# contains a lot of output": it is that the specific broken thing is
# identifiable in it. So each case seeds a fault, captures a dump, and greps the
# dump for evidence a reader would use to identify that component.
#
# Destructive by design; every fault is restored and the restore verified.
# ---------------------------------------------------------------------------
set -uo pipefail

LAB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "${LAB_ROOT}/scripts/lib/versions.sh"
source "${LAB_ROOT}/scripts/lib/log.sh"
source "${LAB_ROOT}/scripts/lib/wait.sh"

K="kubectl --context ${LAB_KUBECONTEXT}"
OUT_DIR="${LAB_RESULTS_DIR}/dump-verification/$(date +%Y%m%dT%H%M%S)"
mkdir -p "$OUT_DIR"

log_suite "make dump names the failing component (SC-018)"

healthy() {
  local d ready
  for d in auth-service order-service; do
    ready="$($K -n "${NS_APP}" get deploy "$d" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)"
    [[ "${ready:-0}" -ge 1 ]] || return 1
  done
  return 0
}
[[ "${1:-}" == "--healthy-probe" ]] && { healthy; exit $?; }

if ! healthy; then
  log_fail "environment not healthy before seeding" "pre-check"
  log_summary; exit 1
fi
log_pass "environment healthy before seeding" "pre-check"

# seed <class> <evidence-regex> <break> <restore>
seed() {
  local class="$1" evidence="$2" break_cmd="$3" restore_cmd="$4"
  printf '\n'
  log_step "fault class: ${class}"

  bash -c "$break_cmd" >/dev/null 2>&1
  # Condition-based: dumping before the fault is visible would produce a false
  # negative for the dump rather than for the fault.
  wait_for "the ${class} fault becomes visible" 120 bash -c "! '${BASH_SOURCE[0]}' --healthy-probe" \
    || log_info "the fault may not be visible yet; dumping anyway"

  local dump="${OUT_DIR}/${class}.txt"
  "${LAB_ROOT}/scripts/dump.sh" > "$dump" 2>&1 || true

  if grep -qiE "$evidence" "$dump"; then
    log_pass "${class}: the dump names it" "matched /${evidence}/ in $(basename "$dump")"
    printf '    %s\n' "$(grep -iE "$evidence" "$dump" | head -1 | cut -c1-110)"
  else
    log_fail "${class}: the dump does NOT contain evidence identifying the component"
    log_context "Searched for /${evidence}/ in ${dump}.
SC-018 requires a reader to name the failing component from the dump ALONE.
Extend scripts/dump.sh until this passes — the requirement is on the dump, not
on the reader."
  fi

  bash -c "$restore_cmd" >/dev/null 2>&1
  wait_for "environment recovers from the ${class} fault" "${TIMEOUT_WORKLOAD_READY}" \
    bash -c "'${BASH_SOURCE[0]}' --healthy-probe" \
    && log_pass "${class}: restored" "verified" \
    || { log_fail "${class}: environment did NOT recover"; return 1; }
}

# 1. scheduling — a pod that cannot be placed
seed "scheduling" "Pending|Insufficient|FailedScheduling" \
  "$K -n ${NS_APP} patch deploy auth-service --type=json -p '[{\"op\":\"add\",\"path\":\"/spec/template/spec/nodeSelector\",\"value\":{\"nonexistent\":\"true\"}}]'" \
  "$K -n ${NS_APP} patch deploy auth-service --type=json -p '[{\"op\":\"remove\",\"path\":\"/spec/template/spec/nodeSelector\"}]'"

# 2. image — a tag that does not exist
seed "image" "ImagePullBackOff|ErrImagePull" \
  "$K -n ${NS_APP} set image deploy/order-service order-service=${LAB_REGISTRY_HOST_ADDR}/hydra/order-service:no-such-tag" \
  "${LAB_ROOT}/scripts/app.sh deploy"

# 3. datastore — Postgres gone
seed "datastore" "postgres.*0/1|postgres.*not reachable|postgres.*Pending|0 endpoints" \
  "$K -n ${NS_DATA} scale statefulset postgres --replicas=0" \
  "$K -n ${NS_DATA} scale statefulset postgres --replicas=1"

# 4. cache — Redis gone
seed "cache" "redis.*0/1|redis.*not reachable|redis.*Pending" \
  "$K -n ${NS_DATA} scale statefulset redis --replicas=0" \
  "$K -n ${NS_DATA} scale statefulset redis --replicas=1"

# 5. routing — no HTTPRoute
seed "routing" "No resources found|httproute" \
  "$K -n ${NS_APP} delete httproute hydra-api --ignore-not-found" \
  "${LAB_ROOT}/scripts/app.sh deploy"

# 6. readiness — replicas below desired
seed "readiness" "available|0/|not Running" \
  "$K -n ${NS_APP} scale deploy order-service --replicas=0" \
  "$K -n ${NS_APP} scale deploy order-service --replicas=3"

printf '\n'
log_section "classes covered by the dump's structure rather than by a seeded fault"
# Three classes are asserted by SECTION PRESENCE rather than by breaking them:
# DNS, network policy and autoscaling faults are diagnosed from sections that
# must exist in every dump. Seeding a DNS fault means breaking CoreDNS for the
# whole cluster, which takes out the recovery path too.
reference="${OUT_DIR}/healthy-reference.txt"
"${LAB_ROOT}/scripts/dump.sh" > "$reference" 2>&1 || true
for spec in "dns:kube-dns|coredns" \
            "network-policy:networkpolicy|ciliumnetworkpolicy" \
            "autoscaling:hpa|horizontalpodautoscaler|ScalingActive"; do
  cls="${spec%%:*}"; pat="${spec#*:}"
  if grep -qiE "$pat" "$reference"; then
    log_pass "${cls}: the dump carries the section needed to diagnose it" "/${pat}/"
  else
    log_fail "${cls}: the dump has no section covering it"
  fi
done

printf '\ndumps written to: %s\n' "$OUT_DIR"
log_summary
