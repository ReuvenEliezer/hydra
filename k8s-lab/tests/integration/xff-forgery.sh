#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# xff-forgery.sh — the highest-risk requirement in the feature
# (FR-041, SC-006, research.md D12).
#
# THE THREAT, stated plainly: `ClientIpResolver` trusts the LEFT-MOST
# X-Forwarded-For value with no validation. If the gateway APPENDS its own
# observed address rather than REPLACING the header, a client-supplied value
# stays in front — and every per-address rate limit becomes forgeable by anyone
# who can set a header. Rotating a fake XFF gives unlimited login attempts.
#
# THE CHECK: send `X-Forwarded-For: 1.2.3.4` from a known client address, exceed
# the per-address limit, and assert the limiter counted against the address the
# GATEWAY OBSERVED rather than the one the client claimed.
#
# IF THIS FAILS, IT IS NOT A LAB DEFECT TO PAPER OVER. It is a finding about
# Cilium's Gateway API implementation and it belongs in docs/edge-finding.md as
# a genuine argument about Kubernetes-as-edge (FR-113, FR-116). D12 says so
# explicitly, and this script reports it that way.
# ---------------------------------------------------------------------------
set -uo pipefail

LAB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "${LAB_ROOT}/scripts/lib/versions.sh"
source "${LAB_ROOT}/scripts/lib/log.sh"
source "${LAB_ROOT}/scripts/lib/wait.sh"
source "${LAB_ROOT}/scripts/lib/assert.sh"

K="kubectl --context ${LAB_KUBECONTEXT}"
log_suite "X-Forwarded-For forgery (FR-041, SC-006)"

capacity="$($K -n "${NS_APP}" get deploy auth-service \
  -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="RATE_LIMIT_LOGIN_PER_IP_CAPACITY")].value}' 2>/dev/null)"
capacity="${capacity:-5}"
log_info "per-address login capacity: ${capacity} per window"

# Wait for a clean window, so a previous drill's traffic does not decide this.
if ! wait_for "the rate-limit window is clear" 180 \
     bash -c "[[ \"\$(curl -s -o /dev/null -w '%{http_code}' --cacert '${LAB_CA_CERT}' --max-time 15 -X POST '${LAB_BASE_URL}/api/v1/auth/login' -H 'Content-Type: application/json' -d '{\"username\":\"labuser\",\"password\":\"lab-password-not-a-secret\"}' 2>/dev/null)\" == \"200\" ]]"; then
  log_fail "could not reach a clean rate-limit window" "a previous test may still be throttling this address"
  log_summary; exit 1
fi

# --- Step 1: exhaust the limit while rotating a FORGED address --------------
# If the limiter were counting the forged value, each new fake address would get
# its own fresh bucket and nothing would ever be throttled.
attempts=$(( capacity * 3 ))
throttled=0
for i in $(seq 1 "$attempts"); do
  code="$(curl -s -o /dev/null -w '%{http_code}' --cacert "${LAB_CA_CERT}" --max-time 20 \
    -X POST "${LAB_BASE_URL}/api/v1/auth/login" \
    -H "X-Forwarded-For: 10.99.99.${i}" \
    -H 'Content-Type: application/json' \
    -d '{"username":"labuser","password":"deliberately-wrong-so-only-the-limit-decides"}' 2>/dev/null || echo 000)"
  [[ "$code" == "429" ]] && throttled=$(( throttled + 1 ))
done

log_info "${attempts} attempts, each with a DIFFERENT forged X-Forwarded-For: ${throttled} throttled"

if (( throttled > 0 )); then
  log_pass "rotating a forged X-Forwarded-For did NOT reset the limit" \
           "${throttled}/${attempts} throttled — the limiter counted the observed address (SC-006)"
  log_info "A forged header cannot buy a fresh bucket, which is the property FR-041 protects."
else
  # ------------------------------------------------------------------------
  # THE HONEST FAILURE PATH (D12, FR-116).
  # ------------------------------------------------------------------------
  log_fail "NOTHING was throttled across ${attempts} attempts with rotating forged addresses"
  log_context "The limiter appears to be counting the CLIENT-SUPPLIED X-Forwarded-For value.

That makes every per-address limit forgeable: an attacker rotates the header and
gets an unlimited number of fresh buckets. ClientIpResolver trusts the left-most
value with no validation, so this is not a theoretical concern.

Cause: the gateway is APPENDING its observed address rather than REPLACING the
header, leaving the forged value in front.

Remedies, in D12's order of preference:
  1. HTTPRoute RequestHeaderModifier with `set` (not `add`) — already configured
     in charts/hydra-lab/templates/httproute.yaml.
  2. If the gateway appends AFTER filters run, a CiliumClusterwideEnvoyConfig
     overriding use_remote_address / xff_num_trusted_hops / skip_xff_append.

IF NEITHER WORKS, THIS IS A FINDING, NOT A DEFECT TO HIDE. Record it verbatim in
docs/edge-finding.md as evidence about Kubernetes-as-edge (FR-113). Do not
weaken this test to make it pass."
fi

# --- Step 2: the header the backend actually saw ---------------------------
# The direct evidence. Step 1 infers from behaviour; this reads the value.
log_section "what the backend received"
probe="$(curl_headers "${LAB_BASE_URL}/api/v1/tenant" -H "X-Forwarded-For: 1.2.3.4")"
log_info "response headers recorded; the authoritative check is the service's own view below"

recent="$($K -n "${NS_APP}" logs deploy/auth-service --tail=200 2>/dev/null \
  | grep -iE 'x-forwarded-for|client.?ip' | tail -3 || true)"
if [[ -n "$recent" ]]; then
  log_info "service log evidence:"
  log_context "$recent"
  if printf '%s' "$recent" | grep -q '1\.2\.3\.4'; then
    log_fail "the forged address 1.2.3.4 reached the service" "replace semantics are NOT in force"
  else
    log_pass "the forged address did not reach the service" "the gateway replaced it (FR-041)"
  fi
else
  log_info "the services do not log the client address, so step 1's behavioural result stands alone."
  log_info "That is the stronger check anyway: it measures what the LIMITER did, not what was logged."
fi

log_summary
