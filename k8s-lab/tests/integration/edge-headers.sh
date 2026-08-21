#!/usr/bin/env bash
# edge-headers.sh — the gateway must not emit CORS of its own (FR-037).
#
# FR-037 requires any CORS handling the gateway implementation enables by
# default to be explicitly disabled. Cilium's Gateway API does not enable it,
# and this is the executed assertion that it stays that way — a future chart
# version or a values change could turn it on, and the symptom would appear only
# in a browser.
set -uo pipefail
LAB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "${LAB_ROOT}/scripts/lib/versions.sh"
source "${LAB_ROOT}/scripts/lib/log.sh"
source "${LAB_ROOT}/scripts/lib/assert.sh"

ORIGIN="http://${LAB_PRIMARY_HOST}:5173"
log_suite "edge headers (FR-037)"

# EXACTLY ONE Access-Control-Allow-Origin. Not "present" — one. Two is the
# failure, and it is the failure a gateway with its own CORS produces.
assert_header_count "exactly one Access-Control-Allow-Origin on a CORS request" \
  "${LAB_BASE_URL}/api/v1/tenant" "access-control-allow-origin" "1" \
  -H "Origin: ${ORIGIN}"

headers="$(curl_headers "${LAB_BASE_URL}/api/v1/tenant" -H "Origin: ${ORIGIN}")"
echoed="$(printf '%s' "$headers" | sed -n 's/^access-control-allow-origin: *//p' | tr -d '\r')"
if [[ "$echoed" == "$(printf '%s' "$ORIGIN" | tr 'A-Z' 'a-z')" ]]; then
  log_pass "the single header echoes the caller's origin" "${echoed}"
elif [[ "$echoed" == "*" ]]; then
  log_fail "Access-Control-Allow-Origin is '*'"
  log_context "A browser rejects '*' outright when credentials are involved, and the
refresh-cookie flow requires credentials. This is the signature of a GATEWAY
emitting CORS rather than the service."
else
  log_fail "unexpected Access-Control-Allow-Origin: '${echoed}'"
fi

# A preflight must never be 401 (Clause 3): the browser sends it without
# credentials by definition.
assert_http_status "an unauthenticated preflight is not 401" "200" \
  "${LAB_BASE_URL}/api/v1/auth/login" \
  -X OPTIONS -H "Origin: ${ORIGIN}" \
  -H 'Access-Control-Request-Method: POST' \
  -H 'Access-Control-Request-Headers: content-type'

# On a NON-CORS request there should be no CORS headers at all. A gateway that
# adds them unconditionally shows up here.
assert_header_absent "no CORS headers on a request without an Origin" \
  "${LAB_BASE_URL}/api/v1/tenant" "access-control-allow-origin"

log_summary
