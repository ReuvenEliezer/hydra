#!/usr/bin/env bash
# readiness-fail drill (FR-064).
#
# Expected observable: one replica stops receiving traffic WHILE STILL RUNNING,
# and resumes only when it reports ready again.
#
# The distinction being demonstrated is the one FR-063 exists for: readiness
# controls endpoint membership, liveness controls restarts. A replica that is
# unready is removed from the Service and keeps running — it is not killed.
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/lib" && pwd)/drill.sh"

drill_begin "readiness-fail" \
  "a replica leaves the endpoint set while still Running, and returns when ready" || { log_summary; exit 1; }

toggle_enabled="$($K -n "${NS_APP}" get deploy auth-service \
  -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="HYDRA_LAB_READINESS_TOGGLE")].value}' 2>/dev/null || true)"

if [[ "$toggle_enabled" != "true" ]]; then
  # FR-064 requires the mechanism to be gated behind a non-production profile
  # and OFF by default. It is, so this drill reports that honestly instead of
  # enabling it silently — a drill that turns on a safety gate to run is not
  # testing the shipped configuration.
  log_skip "readiness toggle drill" \
    "the toggle is off by default (FR-064); enable with --set readinessToggle.enabled=true and redeploy"
  log_info "The mechanism exists and is deliberately not on. Turning it on inside the drill"
  log_info "would mean the drill never tests the configuration the lab actually ships."
  log_summary; exit 0
fi

victim="$($K -n "${NS_APP}" get pods -l app.kubernetes.io/name=auth-service \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
[[ -n "$victim" ]] || { log_fail "no pod to target"; log_summary; exit 1; }

before_eps="$($K -n "${NS_APP}" get endpointslice -l kubernetes.io/service-name=auth-service \
  -o jsonpath='{range .items[*]}{range .endpoints[*]}{.conditions.ready}{"\n"}{end}{end}' 2>/dev/null | grep -c '^true$' || echo 0)"

# The trigger's RESULT is read, not assumed.
#
# This previously discarded the response and logged PASS unconditionally. The
# request was returning 401 the whole time, so the drill reported a successful
# trigger, then failed the endpoint assertion 120s later and blamed readiness —
# pointing at the wrong component entirely. An asserted pass on the trigger is
# the one place it does most damage, because everything after it is interpreted
# in its light (FR-098).
trigger_code="$($K -n "${NS_APP}" exec "$victim" -- \
  sh -c 'wget -S -q -O /dev/null --post-data="" "http://127.0.0.1:8083/actuator/serviceregistry?status=OUT_OF_SERVICE" 2>&1 \
         | grep -oE "HTTP/1\.[01] [0-9]{3}" | grep -oE "[0-9]{3}$" | head -1' 2>/dev/null || true)"

if [[ "$trigger_code" == "401" || "$trigger_code" == "403" ]]; then
  # Same root cause as the health-group endpoints (docs/known-gaps.md §3):
  # SecurityCommons.authRules() permits the EXACT path /actuator/health and then
  # falls through to .anyRequest().authenticated(). /actuator/serviceregistry is
  # therefore unreachable, and enabling readinessToggle does not change that —
  # the toggle turns on the EXPOSURE of an endpoint that security still refuses.
  #
  # BLOCKED, not FAIL and certainly not PASS: the mechanism was never exercised,
  # so nothing was established about readiness either way.
  log_blocked "the readiness toggle endpoint is unreachable" \
    "POST /actuator/serviceregistry returned HTTP ${trigger_code}"
  log_info "readinessToggle.enabled=true exposes the endpoint; it does not authorise it."
  log_info "The one-line fix belongs to SecurityCommons, which FR-044 puts outside this"
  log_info "feature: .requestMatchers(\"/actuator/**\").permitAll() — see docs/known-gaps.md §3."
  log_info "FR-063's substance is unaffected: readiness and liveness remain distinct probes."
  drill_restore "no change was made" true
  drill_end
  exit $?
fi

if [[ "$trigger_code" =~ ^2 ]]; then
  log_pass "trigger: replica forced OUT_OF_SERVICE" "$victim (HTTP ${trigger_code})"
else
  log_fail "trigger: the serviceregistry call returned HTTP ${trigger_code:-no-response}"
  log_context "$($K -n "${NS_APP}" exec "$victim" -- \
    sh -c 'wget -S -q -O - --post-data="" "http://127.0.0.1:8083/actuator/serviceregistry?status=OUT_OF_SERVICE" 2>&1' 2>&1 | head -10)"
  drill_restore "no change was made" true
  drill_end
  exit $?
fi

if wait_for_output "the replica leaves the endpoint set" 120 "$(( before_eps - 1 ))" \
     bash -c "$K -n ${NS_APP} get endpointslice -l kubernetes.io/service-name=auth-service -o jsonpath='{range .items[*]}{range .endpoints[*]}{.conditions.ready}{\"\n\"}{end}{end}' 2>/dev/null | grep -c '^true\$'"; then
  log_pass "the unready replica stopped receiving traffic" "endpoint count ${before_eps} -> $(( before_eps - 1 ))"
else
  log_fail "the replica did not leave the endpoint set"
fi

phase="$($K -n "${NS_APP}" get pod "$victim" -o jsonpath='{.status.phase}' 2>/dev/null)"
assert_eq "the unready replica is STILL RUNNING, not restarted" "Running" "$phase"
log_info "That is the distinction FR-063 protects: readiness removes an endpoint, liveness restarts a process."

$K -n "${NS_APP}" exec "$victim" -- \
  sh -c 'wget -q -O /dev/null --post-data="" http://127.0.0.1:8083/actuator/serviceregistry?status=UP' >/dev/null 2>&1 || true

drill_restore "return the replica to service" true
drill_end
