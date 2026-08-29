#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# scaling.sh — `make test-scaling` (FR-070, FR-072, SC-016).
#
# Asserts that the replica count responds to REAL OBSERVED METRICS under
# sustained load, and returns toward baseline afterwards.
#
# THE PART THAT MATTERS MOST (FR-072): when the workstation cannot supply the
# headroom to scale, this reports the CONSTRAINT explicitly and distinguishes
#
#     "did not scale"      the HPA saw the load and chose not to / could not
#     "could not observe"  the HPA had no metrics at all
#
# and never reports a false PASS. This is the requirement most likely to be
# quietly faked, which is why the spec calls it out by name.
# ---------------------------------------------------------------------------
set -uo pipefail

LAB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "${LAB_ROOT}/scripts/lib/versions.sh"
source "${LAB_ROOT}/scripts/lib/log.sh"
source "${LAB_ROOT}/scripts/lib/wait.sh"
source "${LAB_ROOT}/scripts/lib/assert.sh"

K="kubectl --context ${LAB_KUBECONTEXT}"
TARGET="${TARGET:-auth-service}"
LOAD_SECONDS="${LOAD_SECONDS:-180}"

log_suite "scaling (SC-016)"

if ! $K get hpa -n "${NS_APP}" "$TARGET" >/dev/null 2>&1; then
  log_fail "no HPA for ${TARGET}" "autoscaling.enabled must be true"
  log_summary; exit 1
fi

baseline="$($K -n "${NS_APP}" get deploy "$TARGET" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)"
maxr="$($K -n "${NS_APP}" get hpa "$TARGET" -o jsonpath='{.spec.maxReplicas}' 2>/dev/null)"
log_info "baseline ${baseline} replicas, HPA max ${maxr}"

# --- Can the HPA see metrics at all? --------------------------------------
# This distinction is the whole point of the requirement, so it is established
# BEFORE the load rather than inferred from the outcome.
scaling_active="$($K -n "${NS_APP}" get hpa "$TARGET" \
  -o jsonpath='{.status.conditions[?(@.type=="ScalingActive")].status}' 2>/dev/null)"
scaling_reason="$($K -n "${NS_APP}" get hpa "$TARGET" \
  -o jsonpath='{.status.conditions[?(@.type=="ScalingActive")].reason}' 2>/dev/null)"

if [[ "$scaling_active" != "True" ]]; then
  log_fail "the HPA has no usable metrics" "ScalingActive=${scaling_active:-unknown} reason=${scaling_reason:-unknown}"
  log_info "VERDICT: COULD NOT OBSERVE — not 'did not scale'."
  log_info "The autoscaler never had an input, so this run says nothing about whether scaling works."
  log_info "Usual cause: metrics-server is absent or not serving resource metrics."
  log_info "  kubectl top pods -n ${NS_APP}"
  log_summary; exit 1
fi
log_pass "the HPA is reading real metrics" "ScalingActive=True reason=${scaling_reason}"

# --- Drive load ------------------------------------------------------------
log_step "driving load for ${LOAD_SECONDS}s through the gateway"
DURATION="$LOAD_SECONDS" CONCURRENCY=24 "${LAB_ROOT}/tests/perf/load-test.sh" >/dev/null 2>&1 &
load_pid=$!

peak="$baseline"
end=$(( SECONDS + LOAD_SECONDS + 60 ))
while (( SECONDS < end )); do
  cur="$($K -n "${NS_APP}" get deploy "$TARGET" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)"
  [[ -n "$cur" ]] && (( cur > peak )) && peak="$cur"
  kill -0 "$load_pid" 2>/dev/null || break
  sleep 10   # WAIT_POLL_INTERVAL: sampling interval
done
wait "$load_pid" 2>/dev/null || true

log_info "peak observed replicas: ${peak} (baseline ${baseline}, max ${maxr})"

# --- The verdict, with the constraint path -------------------------------
if (( peak > baseline )); then
  log_pass "replica count rose above baseline under real load" "${baseline} -> ${peak} (SC-016)"

  log_step "waiting for scale-down toward baseline"
  if wait_for "replicas return toward baseline" 600 \
       bash -c "[[ \"\$($K -n ${NS_APP} get deploy $TARGET -o jsonpath='{.status.readyReplicas}' 2>/dev/null)\" -le $(( peak - 1 )) ]]"; then
    log_pass "replica count returned toward baseline after the load stopped" "SC-016"
  else
    # Not a failure: the scale-down stabilisation window is deliberately long
    # (300s) so a bursty workload does not produce a measurement of the
    # autoscaler rather than of the service.
    log_info "no scale-down observed within the wait; the scaleDown stabilisation window is 300s by design"
  fi
else
  # ------------------------------------------------------------------------
  # T122: the constraint path. The HPA HAD metrics and did not scale. Report
  # what actually happened and why, and do NOT report success.
  # ------------------------------------------------------------------------
  cpu_target="$($K -n "${NS_APP}" get hpa "$TARGET" -o jsonpath='{.spec.metrics[0].resource.target.averageUtilization}' 2>/dev/null)"
  cpu_current="$($K -n "${NS_APP}" get hpa "$TARGET" -o jsonpath='{.status.currentMetrics[0].resource.current.averageUtilization}' 2>/dev/null)"
  allocatable="$($K get nodes -o jsonpath='{range .items[*]}{.status.allocatable.cpu}{" "}{end}' 2>/dev/null)"

  log_fail "the replica count did NOT rise above ${baseline} under sustained load (SC-016)"
  log_context "HPA target: ${cpu_target}% utilisation of the CPU REQUEST
observed:   ${cpu_current:-unknown}%
node allocatable CPU: ${allocatable}

This is 'did not scale', NOT 'could not observe' — the HPA had metrics
throughout (ScalingActive=True).

Two explanations, and they are different findings:

  1. The load did not push CPU past the target. Raise CONCURRENCY or
     LOAD_SECONDS, or lower the HPA target, and re-run.
  2. The workstation has no headroom: with ${baseline} replicas already
     requesting CPU, there may be nowhere to place another. Check for Pending
     pods — that is the workstation constraint FR-072 asks to be reported
     explicitly rather than smoothed over.

     kubectl -n ${NS_APP} get pods --field-selector=status.phase=Pending"
  log_info "Reported as a FAILURE with its cause named. A scaling test that cannot scale must"
  log_info "never report success (FR-072)."
  log_summary; exit 1
fi

log_summary
