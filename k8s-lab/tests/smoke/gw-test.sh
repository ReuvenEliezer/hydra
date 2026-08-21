#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# gw-test.sh — `make gw-test` (FR-034).
#
# Proves the full workstation -> serving-process path with an actual request:
#
#   curl https://acme.localhost
#     -> resolver: *.localhost is loopback by RFC 6761 (no /etc/hosts, no sudo)
#     -> kind extraPortMapping: host 443 -> control-plane node port 30443
#     -> NodePort Service (fixed) for the Gateway
#     -> Cilium Envoy listener, TLS terminated with the lab wildcard certificate
#     -> whatever the routes say
#
# The requirement is that the response is "produced inside the cluster" and not
# a placeholder. That distinction is the whole check: a connection refused, a
# TLS failure and a response from something else on the workstation are three
# different outcomes and only one of them is a gateway.
#
# TWO VALID STATES, and the script must not confuse them:
#
#   End of US1 (no chart, no routes)  -> Envoy answers, and with no matching
#                                        route the correct answer is 404. A 404
#                                        *from Envoy* is a pass here: it proves
#                                        the listener terminated TLS and made a
#                                        routing decision.
#   After US2 (routes installed)      -> real application traffic. T072 adds
#                                        those assertions; they run only when
#                                        routes exist.
#
# Certificate verification is never disabled (FR-032b). Every request below is
# made with --cacert against the lab CA, which is also what proves the Gateway
# is serving the certificate the lab issued rather than some other one.
# ---------------------------------------------------------------------------
set -uo pipefail

LAB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "${LAB_ROOT}/scripts/lib/versions.sh"
source "${LAB_ROOT}/scripts/lib/log.sh"
source "${LAB_ROOT}/scripts/lib/wait.sh"
source "${LAB_ROOT}/scripts/lib/assert.sh"

K="kubectl --context ${LAB_KUBECONTEXT}"
BASE="https://${LAB_PRIMARY_HOST}"

log_suite "gw-test (workstation -> in-cluster Envoy)"

[[ -r "$LAB_CA_CERT" ]] || {
  log_fail "no lab CA at ${LAB_CA_CERT}" "run 'make setup' — the certs checkpoint produces it"
  log_summary; exit 1
}

# --- 1. Resolution, with no hosts-file edit and no privilege (FR-033) ------
# Asserted rather than assumed: this is the requirement that makes the whole
# addressing scheme legitimate, and it is one resolver away from being false.
hosts_before="$(md5 -q /etc/hosts 2>/dev/null || md5sum /etc/hosts 2>/dev/null | awk '{print $1}')"

resolved="$(getent hosts "${LAB_PRIMARY_HOST}" 2>/dev/null | awk '{print $1}' | head -1)"
if [[ -z "$resolved" ]]; then
  # macOS has no getent; dscacheutil or a plain ping resolution is the fallback.
  resolved="$(dscacheutil -q host -a name "${LAB_PRIMARY_HOST}" 2>/dev/null | sed -n 's/^ip_address: //p' | head -1)"
fi
if [[ "$resolved" == "127.0.0.1" || "$resolved" == "::1" ]]; then
  log_pass "${LAB_PRIMARY_HOST} resolves to loopback" "RFC 6761, resolver answered ${resolved}"
else
  # Not fatal on its own — curl may still resolve it. Report what was seen.
  log_info "resolver returned '${resolved:-nothing}' for ${LAB_PRIMARY_HOST}; curl's own resolution is tested next"
fi

if ! grep -qE "[[:space:]]${LAB_PRIMARY_HOST}([[:space:]]|$)" /etc/hosts 2>/dev/null; then
  log_pass "no /etc/hosts entry exists for ${LAB_PRIMARY_HOST}" "FR-033: no hosts-file edit, no elevated privilege"
else
  log_fail "an /etc/hosts entry exists for ${LAB_PRIMARY_HOST} (FR-033)"
  log_context "The lab must work without one. Remove it and re-run, or the result proves nothing about FR-033."
fi

# --- 2. The port mapping actually exists ----------------------------------
mapping="$(docker port "${LAB_CLUSTER}-control-plane" 2>/dev/null | grep -E "^${GATEWAY_NODEPORT_HTTPS}/tcp" || true)"
if [[ -n "$mapping" ]]; then
  log_pass "kind maps host 443 to node port ${GATEWAY_NODEPORT_HTTPS}" "docker port: ${mapping}"
else
  log_fail "no host port mapping for node port ${GATEWAY_NODEPORT_HTTPS}"
  log_context "$(docker port "${LAB_CLUSTER}-control-plane" 2>&1)"
fi

# --- 3. TLS handshake against the lab CA ----------------------------------
# Wait for the listener rather than assuming Envoy is instantly serving after
# the Gateway reports Programmed — those are close together but not the same
# moment.
if ! wait_for "the gateway accepts a TLS connection" "${TIMEOUT_HTTP_RESPONSIVE}" \
     bash -c "curl -s -o /dev/null --cacert '${LAB_CA_CERT}' --max-time 10 '${BASE}/' 2>/dev/null || curl -s -o /dev/null --cacert '${LAB_CA_CERT}' --max-time 10 -w '%{http_code}' '${BASE}/' 2>/dev/null | grep -qE '^[0-9]{3}$'"; then
  log_context "$($K -n "${NS_APP}" get gateway hydra-gateway -o wide 2>&1)"
  log_context "$($K -n kube-system get pods -l k8s-app=cilium-envoy -o wide 2>&1)"
  log_summary; exit 1
fi

tls_info="$(curl -sv --cacert "$LAB_CA_CERT" --max-time 15 -o /dev/null "${BASE}/" 2>&1 || true)"
if grep -qiE 'SSL connection using|TLS.*handshake|SSL certificate verify ok|subject:' <<< "$tls_info"; then
  log_pass "TLS handshake completed with verification enabled" "--cacert ${LAB_CA_CERT##*/}, never --insecure (FR-032b)"
else
  log_fail "TLS handshake did not complete"
  log_context "$(printf '%s\n' "$tls_info" | grep -E '^\*' | head -20)"
fi

# The certificate served must be the lab's wildcard, not something else that
# happens to be listening on 443.
subject="$(printf '%s\n' "$tls_info" | sed -n 's/^\*  subject: //p' | head -1)"
if [[ "$subject" == *"*.${LAB_BASE_DOMAIN}"* ]]; then
  log_pass "the gateway serves the lab wildcard certificate" "subject: ${subject}"
else
  log_fail "unexpected certificate subject: ${subject:-<none>}"
  log_context "Something other than the lab gateway may be listening on 443."
fi

# --- 4. The response was produced INSIDE the cluster ----------------------
# This is FR-034's actual demand, and the assertion needs care: a 404 is a
# perfectly good answer at this stage, so the check cannot be "status is 200".
# What distinguishes an in-cluster response from a placeholder is the server
# identity — Envoy sets `server: envoy` on responses it generates.
code="$(curl -s -o /dev/null -w '%{http_code}' --cacert "$LAB_CA_CERT" --max-time 15 "${BASE}/" 2>/dev/null || echo 000)"
headers="$(curl_headers "${BASE}/")"

if [[ "$code" == "000" ]]; then
  log_fail "no HTTP response at all from ${BASE}/"
  log_context "The TLS handshake succeeded but no HTTP response arrived — check the Envoy listener."
else
  log_pass "gateway returned HTTP ${code}" "an answer, not a refused connection"
fi

if grep -qE '^server:.*(envoy|cilium)' <<< "$headers"; then
  log_pass "the response was produced by the in-cluster Envoy listener" \
           "$(grep -E '^server:' <<< "$headers" | head -1)"
else
  log_fail "the response did not come from Envoy"
  log_context "$headers"
  log_context "FR-034 requires a response produced inside the cluster, not a placeholder from the workstation."
fi

# --- 5. Report which of the two valid states this is -----------------------
route_count="$($K -n "${NS_APP}" get httproute --no-headers 2>/dev/null | grep -c . 2>/dev/null | head -1 | tr -d ' ')"
[[ -n "$route_count" ]] || route_count=0
if [[ "$route_count" == "0" ]]; then
  if [[ "$code" == "404" ]]; then
    log_pass "no routes installed and the gateway returns 404" \
             "Envoy terminated TLS and made a routing decision — the correct US1 state"
  else
    log_info "no HTTPRoutes exist yet; the gateway answered ${code}"
  fi
  log_info "This is the end-of-US1 state. T072 adds application-traffic assertions once routes exist."
else
  log_info "${route_count} HTTPRoute(s) installed — application-traffic assertions follow in tests/smoke/run.sh"
  # A gateway with routes that still 404s on every path means the routes are
  # not attached, which is worth catching here rather than in the integration
  # suite where it will look like an application fault.
  auth_code="$(curl -s -o /dev/null -w '%{http_code}' --cacert "$LAB_CA_CERT" --max-time 15 \
               "${BASE}/api/v1/tenant" 2>/dev/null || echo 000)"
  if [[ "$auth_code" != "404" && "$auth_code" != "000" ]]; then
    log_pass "a routed path reaches a backend" "GET /api/v1/tenant -> ${auth_code}"
  else
    log_fail "routes exist but /api/v1/tenant returned ${auth_code}"
    log_context "$($K -n "${NS_APP}" get httproute -o wide 2>&1)"
  fi
fi

# --- 6. FR-033 again, from the other side ---------------------------------
hosts_after="$(md5 -q /etc/hosts 2>/dev/null || md5sum /etc/hosts 2>/dev/null | awk '{print $1}')"
if [[ "$hosts_before" == "$hosts_after" ]]; then
  log_pass "/etc/hosts was not modified by this test" "FR-033"
else
  log_fail "/etc/hosts changed during the test run"
fi

log_summary
