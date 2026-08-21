#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# trace-e2e.sh — one request, one connected trace (SC-012, FR-080, D13).
#
# Required shape for a single external request:
#
#   gateway (Envoy)                 <- research.md D13, the AT-RISK span
#     └─ order-service  GET /api/orders
#          ├─ auth-service  JWKS fetch
#          ├─ postgres query
#          └─ redis command
#
# THE HONEST-FAILURE OBLIGATION (T103, D13, FR-116), and it governs this whole
# file: IF THE GATEWAY SPAN CANNOT BE ATTACHED, SC-012 IS REPORTED **FAIL** WITH
# THE CAUSE NAMED. A trace that begins at order-service is a MISS, not a partial
# pass. There is no "mostly connected" verdict available here, because the thing
# SC-012 asks for is precisely the hop that a service-side agent cannot see.
#
# In reduced-footprint mode Tempo is not installed, and this reports
# SKIPPED-BY-CONFIGURATION — never PASS (D18).
# ---------------------------------------------------------------------------
set -uo pipefail

LAB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "${LAB_ROOT}/scripts/lib/versions.sh"
source "${LAB_ROOT}/scripts/lib/log.sh"
source "${LAB_ROOT}/scripts/lib/wait.sh"
source "${LAB_ROOT}/scripts/lib/assert.sh"

K="kubectl --context ${LAB_KUBECONTEXT}"
log_suite "end-to-end trace (SC-012)"

# --- Reduced mode: unavailable, and said so -------------------------------
if ! $K -n "${NS_OBS}" get statefulset tempo >/dev/null 2>&1 \
   && ! $K -n "${NS_OBS}" get deploy tempo >/dev/null 2>&1; then
  log_skip "end-to-end trace (SC-012)" \
    "Tempo is not installed — reduced-footprint mode disables the trace store (D18, FR-091)"
  log_info "This scenario is UNAVAILABLE in this mode. It is not passing, and it is not failing:"
  log_info "there is nowhere for a trace to be stored, so nothing was tested."
  log_info "Run 'make setup' rather than 'make setup-reduced' to cover SC-012."
  log_summary; exit 0
fi

# --- Issue ONE identifiable request ---------------------------------------
TOKEN="$(curl_body "${LAB_BASE_URL}/api/v1/auth/login" -X POST \
  -H 'Content-Type: application/json' \
  -d '{"username":"labuser","password":"lab-password-not-a-secret"}' | jq -r '.token // empty')"
[[ -n "$TOKEN" ]] || { log_fail "could not sign in"; log_summary; exit 1; }

# A W3C traceparent we choose ourselves. That is what makes "retrieve THIS
# request's trace" possible — searching for "a recent trace" would pass on any
# trace at all, which is not what SC-012 asks.
TRACE_ID="$(openssl rand -hex 16)"
SPAN_ID="$(openssl rand -hex 8)"
TRACEPARENT="00-${TRACE_ID}-${SPAN_ID}-01"
log_info "issuing one request with traceparent ${TRACEPARENT}"

issued_at="$(date +%s)"
code="$(curl_status "${LAB_BASE_URL}/api/orders" \
  -H "Authorization: Bearer ${TOKEN}" -H "traceparent: ${TRACEPARENT}")"
assert_eq "the traced request succeeded" "200" "$code"

# --- Retrieve it within 30 seconds (SC-012) --------------------------------
$K -n "${NS_OBS}" port-forward svc/tempo 13200:3100 >/dev/null 2>&1 &
PF=$!
trap 'kill "$PF" 2>/dev/null || true' EXIT
sleep 3   # WAIT_POLL_INTERVAL: let the port-forward establish

trace_json=""
deadline=$(( issued_at + 30 ))
while [[ "$(date +%s)" -lt "$deadline" ]]; do
  trace_json="$(curl -s --max-time 5 "http://localhost:13200/api/traces/${TRACE_ID}" 2>/dev/null || true)"
  [[ -n "$trace_json" && "$trace_json" != *"trace not found"* ]] && break
  sleep 2   # WAIT_POLL_INTERVAL
done
elapsed=$(( $(date +%s) - issued_at ))

if [[ -z "$trace_json" || "$trace_json" == *"trace not found"* ]]; then
  log_fail "trace ${TRACE_ID} was not retrievable within 30 seconds (SC-012)"
  log_context "Tempo returned nothing for this identifier.
Check the export path: agent -> OTel Collector (OTLP 4317) -> Tempo.
  kubectl -n ${NS_APP} logs deploy/order-service | grep -i otel
  kubectl -n ${NS_OBS} logs deploy/otel-collector-opentelemetry-collector --tail=40"
  log_summary; exit 1
fi
log_pass "the trace was retrieved by identifier in ${elapsed}s" "under the 30s budget (SC-012)"

# --- The spans present ------------------------------------------------------
services="$(printf '%s' "$trace_json" | jq -r '
  [ .batches[]?.resource.attributes[]? | select(.key=="service.name") | .value.stringValue ] | unique | .[]' 2>/dev/null \
  || printf '%s' "$trace_json" | jq -r '[.data[]?.processes[]?.serviceName] | unique | .[]' 2>/dev/null || true)"
log_info "services in the trace: $(printf '%s' "$services" | tr '\n' ' ')"

for svc in order-service auth-service; do
  if printf '%s' "$services" | grep -qx "$svc"; then
    log_pass "the trace contains a ${svc} span" "service.name=${svc}"
  else
    log_fail "the trace has NO ${svc} span"
  fi
done

# Datastore spans: the agent instruments JDBC and Lettuce automatically, so
# their absence means the agent is not instrumenting what it should.
span_names="$(printf '%s' "$trace_json" | jq -r '
  [ .batches[]?.scopeSpans[]?.spans[]?.name ] | unique | .[]' 2>/dev/null || true)"
if printf '%s' "$span_names" | grep -qiE 'select|insert|postgres|jdbc'; then
  log_pass "the trace contains a database span" "automatic JDBC instrumentation"
else
  log_info "no database span found; the request may not have touched Postgres on this path"
fi

# --- THE AT-RISK ASSERTION (D13, T103) -------------------------------------
log_section "the gateway span (SC-012's hard part)"
if printf '%s' "$services" | grep -qiE 'envoy|gateway|cilium'; then
  log_pass "the trace BEGINS AT THE GATEWAY" "an Envoy span is present — SC-012 fully met"
else
  # This is the honest-failure path D13 defines, written out in full because
  # the temptation to soften it is exactly what FR-116 exists to resist.
  log_fail "SC-012 NOT MET: the trace has no gateway span"
  log_context "CAUSE: the OpenTelemetry tracing provider could not be attached to Cilium's Envoy
listener, so the trace BEGINS AT order-service rather than at the gateway.

This is reported as a FAILURE, not as a partial pass. Everything downstream of
the gateway is connected and retrievable — but the hop SC-012 exists to prove is
precisely the one that is missing, and a service-side agent cannot instrument a
proxy it does not run inside.

WHY IT MATTERS BEYOND THE TICK: without the gateway span, the time a request
spends in TLS termination, routing and upstream connection is invisible. A
latency problem in the edge looks like a fast backend and a slow client.

WHAT THIS IS EVIDENCE OF: it belongs in docs/edge-finding.md as a real cost of
Kubernetes-as-edge with this gateway implementation — Cilium's Envoy is
configurable only through CiliumClusterwideEnvoyConfig, and if a tracing
provider cannot be attached that way, the gateway cannot participate in a trace
at all (D13, FR-113).

WHAT MUST NOT HAPPEN: this assertion must not be weakened to 'the trace exists'.
A trace starting at order-service is a MISS (FR-116)."
fi

log_summary
