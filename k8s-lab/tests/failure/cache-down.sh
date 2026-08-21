#!/usr/bin/env bash
# cache-down drill (FR-056).
#
# Expected observable: requests are REJECTED, not passed through.
#
# This is the drill most likely to be misread as a bug. Rate limiting fails
# CLOSED by default (`rate-limit.fail-open: false`), so losing Redis rejects
# requests rather than letting them through unthrottled. That is a deliberate
# security posture: an attacker who can take out the cache must not thereby
# remove the rate limit.
#
# The lab demonstrates it ON PURPOSE so the behaviour is a known property rather
# than a discovery made during an incident.
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/lib" && pwd)/drill.sh"

drill_begin "cache-down" \
  "requests are REJECTED rather than passed through — fail-closed observed" || { log_summary; exit 1; }

replicas="$($K -n "${NS_DATA}" get statefulset redis -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 1)"

$K -n "${NS_DATA}" scale statefulset redis --replicas=0 >/dev/null 2>&1
log_pass "trigger: redis scaled to zero" "kubectl scale statefulset redis --replicas=0"

# `ready_replicas` rather than a raw jsonpath: a StatefulSet at zero omits
# .status.readyReplicas entirely, so the raw query returns "" and never equals
# "0". See scripts/lib/assert.sh — this drill is where that was measured.
wait_for "redis is gone" 120 \
  bash -c "[[ \"\$(ready_replicas ${NS_DATA} statefulset/redis)\" == \"0\" ]]" \
  || log_fail "redis did not scale down"

# The rate-limited endpoint. Login carries @RateLimited, so it is the path that
# exercises the limiter — an unlimited endpoint would keep working and prove
# nothing.
code="$(curl_status "${LAB_BASE_URL}/api/v1/auth/login" \
  -X POST -H 'Content-Type: application/json' \
  -d '{"username":"labuser","password":"lab-password-not-a-secret"}')"

if [[ "$code" == "200" ]]; then
  log_fail "a rate-limited request SUCCEEDED with the cache down" "HTTP 200"
  log_info "That is fail-OPEN. It means an attacker who can take out Redis also removes every"
  log_info "per-address and per-username limit. Check rate-limit.fail-open (FR-056)."
elif [[ "$code" == "000" ]]; then
  log_fail "no response at all" "expected a rejection, not a hang"
else
  log_pass "the request was rejected, not passed through" "HTTP ${code} — fail-closed observed (FR-056)"
  log_info "Rejecting is the correct posture: losing the cache must not remove the limit."
fi

drill_restore "scale redis back up" \
  $K -n "${NS_DATA}" scale statefulset redis --replicas="${replicas}"
drill_end
