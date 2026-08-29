#!/usr/bin/env bash
# cross-replica-limit drill (FR-068, SC-011).
#
# Expected observable: a per-address limit of N admits at most N requests per
# window ACROSS ALL REPLICAS COMBINED — not N per replica.
#
# The failure this catches is quiet and expensive: an in-memory rate limiter
# looks correct in every single-instance test and silently multiplies its limit
# by the replica count in production. Three replicas with a "5 per minute" limit
# admit 15. Hydra uses Redis-backed Bucket4j precisely so that does not happen,
# and this is where that claim gets measured.
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/lib" && pwd)/drill.sh"

drill_begin "cross-replica-limit" \
  "a per-address limit of N admits at most N across ALL replicas, not N per replica" || { log_summary; exit 1; }

# T116: same precondition, same reason.
replicas="$($K -n "${NS_APP}" get deploy auth-service -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)"
if [[ "${replicas:-0}" -lt 2 ]]; then
  log_fail "auth-service has ${replicas:-0} ready replica(s); this drill needs at least 2 (FR-069)"
  log_info "With one replica there is nothing to share a limit ACROSS, so the result would be"
  log_info "true by construction and would say nothing about the distributed limiter."
  log_summary; exit 1
fi
log_pass "multi-instance precondition met" "${replicas} auth-service replicas (FR-069)"

drill_await_clean_rate_limit || { log_summary; exit 1; }

# The login-ip limit: capacity 5 per minute by default. Read from the running
# deployment rather than assumed, so a values change does not silently make this
# drill wrong.
capacity="$($K -n "${NS_APP}" get deploy auth-service \
  -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="RATE_LIMIT_LOGIN_PER_IP_CAPACITY")].value}' 2>/dev/null)"
capacity="${capacity:-5}"
log_info "per-address login capacity: ${capacity} per window"

# Deliberately more than capacity, and enough that per-replica behaviour would
# be obvious: with N replicas, a broken limiter admits up to capacity x N.
total=$(( capacity * replicas + capacity ))
log_info "firing ${total} requests; a per-replica limiter would admit up to $(( capacity * replicas ))"

results="$(mktemp)"
# Sequential, not parallel: the assertion is about the COUNT admitted, and
# parallel requests can race the limiter's own accounting in ways that make the
# result ambiguous. Correctness under concurrency is concurrent-rotation's job.
for _ in $(seq 1 "$total"); do
  curl -s -o /dev/null -w '%{http_code}\n' --cacert "${LAB_CA_CERT}" --max-time 20 \
    -X POST "${LAB_BASE_URL}/api/v1/auth/login" \
    -H 'Content-Type: application/json' \
    -d '{"username":"labuser","password":"deliberately-wrong-so-only-the-limit-decides"}' \
    2>/dev/null >> "$results" || echo 000 >> "$results"
done

log_pass "trigger: ${total} requests from one address" "sequential, through the gateway"

admitted="$(grep -cE '^(200|401)$' "$results" || true)"
throttled="$(grep -c '^429$' "$results" || true)"
rm -f "$results"

log_info "admitted=${admitted}  throttled=${throttled}  of ${total}"
log_info "'admitted' counts 401s: a rejected password still consumed a slot, which is the point —"
log_info "the limiter must count attempts, not successes."

if [[ "${throttled:-0}" == "0" ]]; then
  log_fail "NOTHING was throttled after ${total} attempts" "the limiter is not enforcing at all"
  log_context "Check that Redis is reachable and rate-limit.enabled is true."
else
  assert_le "requests admitted across all ${replicas} replicas (SC-011)" "${admitted}" "${capacity}"
  if [[ "${admitted:-0}" -gt "${capacity}" ]]; then
    log_context "The limit was exceeded. If admitted is close to capacity x replicas"
    log_context "($(( capacity * replicas ))), the limiter is per-replica rather than shared —"
    log_context "which means the effective limit scales with the deployment and nobody notices."
  fi
fi

# The window must eventually reopen, or the drill has left the address blocked
# for the next one.
log_info "waiting for the rate-limit window to reopen before restoring"
wait_for "the limit window reopens" 180 \
  bash -c "[[ \"\$(curl -s -o /dev/null -w '%{http_code}' --cacert '${LAB_CA_CERT}' --max-time 15 -X POST '${LAB_BASE_URL}/api/v1/auth/login' -H 'Content-Type: application/json' -d '{\"username\":\"labuser\",\"password\":\"lab-password-not-a-secret\"}' 2>/dev/null)\" == \"200\" ]]" \
  || log_info "the window had not reopened within the wait; later drills may see throttling"

drill_restore "no state to restore — the limit window expires on its own" true
drill_end
