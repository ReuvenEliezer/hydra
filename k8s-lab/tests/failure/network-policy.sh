#!/usr/bin/env bash
# network-policy drill (FR-073, SC-013).
#
# Expected observable: a REAL unauthorised workload is denied Postgres, Redis
# and auth-service — 100% of attempts — while the authorised equivalents succeed
# 100% of the time, repeatably.
#
# This is the drill that turns the policy from a YAML file into a control. A
# NetworkPolicy that has never been tested against a real caller is a document
# about intent, and the difference only shows up when someone needs it to hold.
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/lib" && pwd)/drill.sh"

ATTEMPTS="${ATTEMPTS:-5}"
INTRUDER_NS="hydra-intruder"

cleanup_intruder() { $K delete ns "$INTRUDER_NS" --ignore-not-found --wait=false >/dev/null 2>&1 || true; }
trap cleanup_intruder EXIT

drill_begin "network-policy" \
  "an unauthorised pod is denied 100% of the time; authorised callers succeed 100%" || { log_summary; exit 1; }

# A genuinely unauthorised workload: its own namespace, no lab labels, nothing
# that any allow rule selects. Putting it in hydra-app with a different name
# would be a weaker test — the namespace-level rules would still apply.
$K delete ns "$INTRUDER_NS" --ignore-not-found --wait=true --timeout=90s >/dev/null 2>&1 || true
$K create ns "$INTRUDER_NS" >/dev/null 2>&1
$K -n "$INTRUDER_NS" apply -f - >/dev/null 2>&1 <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: intruder
spec:
  securityContext: {runAsNonRoot: true, runAsUser: 70, seccompProfile: {type: RuntimeDefault}}
  containers:
    - name: intruder
      image: ${POSTGRES_IMAGE}
      command: ["sleep", "600"]
      securityContext: {allowPrivilegeEscalation: false, capabilities: {drop: ["ALL"]}}
YAML

if ! wait_for "the unauthorised pod is Running" 180 \
     bash -c "[[ \"\$($K -n $INTRUDER_NS get pod intruder -o jsonpath='{.status.phase}' 2>/dev/null)\" == Running ]]"; then
  log_fail "could not start the unauthorised workload"
  log_summary; exit 1
fi
log_pass "trigger: an unauthorised workload exists" "pod/intruder in ${INTRUDER_NS}"

# --- forbidden paths: every attempt must fail --------------------------------
probe_denied() {
  local label="$1" host="$2" port="$3"
  local denied=0 i
  for i in $(seq 1 "$ATTEMPTS"); do
    if ! $K -n "$INTRUDER_NS" exec intruder -- nc -z -w 4 "$host" "$port" >/dev/null 2>&1; then
      denied=$(( denied + 1 ))
    fi
  done
  if [[ "$denied" == "$ATTEMPTS" ]]; then
    log_pass "unauthorised -> ${label}: denied ${denied}/${ATTEMPTS}" "100% denied (SC-013)"
  else
    log_fail "unauthorised -> ${label}: denied only ${denied}/${ATTEMPTS}"
    log_context "Any success here means the datastore is reachable by a workload no policy permits."
  fi
}

probe_denied "postgres"     "postgres.${NS_DATA}.svc.cluster.local" 5432
probe_denied "redis"        "redis.${NS_DATA}.svc.cluster.local"    6379
probe_denied "auth-service" "auth-service.${NS_APP}.svc.cluster.local" 8083

# --- authorised paths: every attempt must succeed ----------------------------
# The mirror half. Denying everything is trivially achievable and useless; the
# policy is only correct if the permitted paths still work.
#
# The probe pod is the SAME IMAGE and the SAME METHOD as the intruder, differing
# only in its LABELS — which is what isolates the variable. Using a different
# tool for the authorised half would leave "denied because of the policy" and
# "denied because the tool does not work" indistinguishable, and the first
# version of this did exactly that: it ran `exec 3<>/dev/tcp/...` inside the
# service container, which busybox sh does not implement, and reported 0/5
# successes against a policy that was permitting the traffic perfectly.
log_section "authorised paths"

AUTHORISED_POD="authorised-probe"
$K -n "${NS_APP}" delete pod "$AUTHORISED_POD" --ignore-not-found --force --grace-period=0 >/dev/null 2>&1 || true
$K -n "${NS_APP}" apply -f - >/dev/null 2>&1 <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: ${AUTHORISED_POD}
  labels:
    # A label the policy PERMITS to reach Postgres. Not auth-service: a pod
    # wearing that label would join the real Service and start receiving live
    # traffic, which is a side effect a drill must not have.
    app.kubernetes.io/name: hydra-fixture
spec:
  securityContext: {runAsNonRoot: true, runAsUser: 70, seccompProfile: {type: RuntimeDefault}}
  automountServiceAccountToken: false
  containers:
    - name: probe
      image: ${POSTGRES_IMAGE}
      command: ["sleep", "600"]
      securityContext: {allowPrivilegeEscalation: false, capabilities: {drop: ["ALL"]}}
YAML

cleanup_authorised() { $K -n "${NS_APP}" delete pod "$AUTHORISED_POD" --ignore-not-found --force --grace-period=0 >/dev/null 2>&1 || true; }

if wait_for "the authorised probe pod is Running" 180 \
     bash -c "[[ \"\$($K -n ${NS_APP} get pod $AUTHORISED_POD -o jsonpath='{.status.phase}' 2>/dev/null)\" == Running ]]"; then
  allowed=0
  for i in $(seq 1 "$ATTEMPTS"); do
    if $K -n "${NS_APP}" exec "$AUTHORISED_POD" -- nc -z -w 4 "postgres.${NS_DATA}.svc.cluster.local" 5432 >/dev/null 2>&1; then
      allowed=$(( allowed + 1 ))
    fi
  done
  if [[ "$allowed" == "$ATTEMPTS" ]]; then
    log_pass "authorised (hydra-fixture) -> postgres: succeeded ${allowed}/${ATTEMPTS}" "100% allowed (SC-013)"
  else
    log_fail "authorised (hydra-fixture) -> postgres: succeeded only ${allowed}/${ATTEMPTS}"
    log_context "Identical image, identical command, identical namespace to the intruder — only the
labels differ. So this is the policy denying traffic it is meant to permit."
  fi
else
  log_fail "the authorised probe pod did not start"
fi
cleanup_authorised

# auth-service -> Redis, proven by BEHAVIOUR rather than by a socket probe.
#
# The rate limiter fails CLOSED (FR-056): without Redis it rejects every
# request. So a 429 is positive evidence that auth-service reached Redis — a
# stronger check than opening a socket from a stand-in pod, because it exercises
# the real client, the real credentials and the real code path.
log_step "auth-service -> redis, via the limiter's own behaviour"
capacity="$($K -n "${NS_APP}" get deploy auth-service \
  -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="RATE_LIMIT_LOGIN_PER_IP_CAPACITY")].value}' 2>/dev/null)"
capacity="${capacity:-5}"
# The password must be at least 8 characters. `LoginRequest` declares
# @Size(min = 8), and bean validation runs during argument binding — BEFORE the
# @RateLimited aspect wraps the handler. A short password therefore returns 400
# and never touches the limiter at all, which is how the first version of this
# check managed to send fifteen login attempts and observe zero throttling
# against a perfectly working rate limiter.
saw429=0
for _ in $(seq 1 $(( capacity * 3 ))); do
  c="$(curl_status "${LAB_BASE_URL}/api/v1/auth/login" -X POST \
    -H 'Content-Type: application/json' -d '{"username":"labuser","password":"wrong-but-long-enough"}')"
  [[ "$c" == "429" ]] && { saw429=1; break; }
done
if (( saw429 )); then
  log_pass "authorised auth-service -> redis" "the limiter returned 429, which requires a Redis round trip (FR-056)"
else
  log_fail "the limiter never returned 429" "either Redis is unreachable from auth-service, or the limiter is disabled"
fi

# The gateway path is the third authorised caller, tested from outside the
# cluster because that is where it comes from.
assert_http_status "authorised gateway -> auth-service" "200" "${LAB_BASE_URL}/api/v1/tenant"

cleanup_intruder
drill_restore "remove the unauthorised namespace" true
drill_end
