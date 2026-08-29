#!/usr/bin/env bash
# rolling-update drill (SC-009).
#
# Expected observable: new pods reach Ready BEFORE old ones terminate, the
# migration remains safe under concurrent replica startup, and the client
# observes ZERO failed requests throughout.
#
# "Zero", not "almost none". maxUnavailable: 0 plus a preStop delay plus a
# readiness probe that means something are what make that achievable; if any one
# of them is wrong, this drill is where it shows.
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/lib" && pwd)/drill.sh"

TARGET_DEPLOY="${1:-auth-service}"

drill_begin "rolling-update (${TARGET_DEPLOY})" \
  "new pods Ready before old terminate; zero failed client requests" || { log_summary; exit 1; }

# Confirm the bounds are what SC-009 needs before rolling anything: a drill that
# rolls with maxUnavailable > 0 and then reports failures has measured the
# configuration, not the rollout.
max_unavail="$($K -n "${NS_APP}" get deploy "${TARGET_DEPLOY}" \
  -o jsonpath='{.spec.strategy.rollingUpdate.maxUnavailable}' 2>/dev/null)"
assert_eq "maxUnavailable is 0" "0" "${max_unavail}"

before_gen="$($K -n "${NS_APP}" get deploy "${TARGET_DEPLOY}" -o jsonpath='{.status.observedGeneration}' 2>/dev/null)"
replicas="$($K -n "${NS_APP}" get deploy "${TARGET_DEPLOY}" -o jsonpath='{.spec.replicas}' 2>/dev/null)"

# Client first, so the window includes the whole rollout.
load_out="$(mktemp)"
"${LAB_ROOT}/tests/failure/lib/client-load.sh" 120 4 > "$load_out" &
load_pid=$!

# A restart is a genuine N -> N+1 rollout of the same image: every pod is
# replaced under the same strategy. Using a new image would additionally test
# the image, which is a different drill.
$K -n "${NS_APP}" rollout restart "deploy/${TARGET_DEPLOY}" >/dev/null 2>&1
log_pass "trigger: rolling update started" "kubectl rollout restart deploy/${TARGET_DEPLOY}"

# Sample the ready count throughout. If it ever drops below the desired count,
# old pods went away before new ones were serving.
min_ready="$replicas"
end=$(( SECONDS + 120 ))
while (( SECONDS < end )); do
  r="$($K -n "${NS_APP}" get deploy "${TARGET_DEPLOY}" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)"
  [[ -n "$r" ]] && (( r < min_ready )) && min_ready="$r"
  $K -n "${NS_APP}" rollout status "deploy/${TARGET_DEPLOY}" --timeout=2s >/dev/null 2>&1 && break
  sleep 2   # WAIT_POLL_INTERVAL: sampling interval, not a readiness signal
done

if $K -n "${NS_APP}" rollout status "deploy/${TARGET_DEPLOY}" --timeout="${TIMEOUT_WORKLOAD_READY}s" >/dev/null 2>&1; then
  log_pass "the rollout completed" "kubectl rollout status"
else
  log_fail "the rollout did not complete"
fi

after_gen="$($K -n "${NS_APP}" get deploy "${TARGET_DEPLOY}" -o jsonpath='{.status.observedGeneration}' 2>/dev/null)"
if [[ "$after_gen" != "$before_gen" ]]; then
  log_pass "a new generation was rolled out" "generation ${before_gen} -> ${after_gen}"
else
  log_fail "the generation did not change; nothing was actually rolled"
fi

assert_ge "ready replicas never dropped below the desired count" "$min_ready" "$replicas"
log_info "That is maxUnavailable: 0 doing its job — new pods became Ready before old ones went."

wait "$load_pid" 2>/dev/null || true
result="$(cat "$load_out")"; rm -f "$load_out"
log_info "client: ${result}"
failed="$(printf '%s' "$result" | sed -n 's/.*failed=\([0-9]*\).*/\1/p')"
assert_eq "zero failed client requests during the rollout (SC-009)" "0" "${failed:-unknown}"

# Migration safety under concurrent replica startup: with replicas running
# ddl-auto=validate, a schema/mapping divergence fails them loudly at startup.
# All replicas Ready after a full roll is that assertion passing.
crashloops="$($K -n "${NS_APP}" get pods -l "app.kubernetes.io/name=${TARGET_DEPLOY}" \
  -o jsonpath='{range .items[*]}{.status.containerStatuses[0].state.waiting.reason}{"\n"}{end}' 2>/dev/null \
  | grep -c 'CrashLoopBackOff' || true)"
assert_eq "no replica crash-looped on schema validation" "0" "${crashloops:-0}"
log_info "Replicas run ddl-auto=validate (D6): a divergence between the Job's schema and the"
log_info "pods' mappings would fail them here rather than silently re-deriving DDL."

drill_restore "no action needed — the rollout completed" true
drill_end
