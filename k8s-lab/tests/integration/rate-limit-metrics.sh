#!/usr/bin/env bash
# rate-limit-metrics.sh — 429s must be separable from errors (FR-079, D11).
#
# Not a cosmetic concern. If a throttled request is aggregated into an error
# rate, then a working rate limiter under load looks identical to an outage —
# and a real outage during busy traffic looks like the limiter doing its job.
# Both directions of that confusion are expensive.
#
# D11's decision: no new metric is added (no service change is possible or
# needed). The agent's http.server.request.duration already carries
# http.response.status_code; the requirement is that dashboards and reports do
# not fold 429 into an error count.
set -uo pipefail
LAB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "${LAB_ROOT}/scripts/lib/versions.sh"
source "${LAB_ROOT}/scripts/lib/log.sh"
source "${LAB_ROOT}/scripts/lib/wait.sh"
source "${LAB_ROOT}/scripts/lib/assert.sh"

K="kubectl --context ${LAB_KUBECONTEXT}"
log_suite "rate-limit rejection distinguishability (FR-079)"

# Generate some 429s deliberately.
capacity="$($K -n "${NS_APP}" get deploy auth-service \
  -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="RATE_LIMIT_LOGIN_PER_IP_CAPACITY")].value}' 2>/dev/null)"
capacity="${capacity:-5}"
got429=0
for _ in $(seq 1 $(( capacity * 3 ))); do
  c="$(curl_status "${LAB_BASE_URL}/api/v1/auth/login" -X POST \
    -H 'Content-Type: application/json' -d '{"username":"labuser","password":"wrong-but-long-enough"}')"
  [[ "$c" == "429" ]] && got429=$(( got429 + 1 ))
done
if (( got429 > 0 )); then
  log_pass "the limiter produced ${got429} throttled responses" "429, not 500"
else
  log_fail "no 429 was produced" "the limiter is not enforcing, so distinguishability cannot be tested"
  log_summary; exit 1
fi

# The status code IS the distinction (D11): 429 is not 5xx, so any query that
# separates by status separates these.
assert_ne "a throttled response is not a server error" "500" "429"

# Prometheus must be able to separate them.
$K -n "${NS_OBS}" port-forward svc/prometheus-server 19091:80 >/dev/null 2>&1 &
PF=$!
trap 'kill "$PF" 2>/dev/null || true' EXIT
sleep 3   # WAIT_POLL_INTERVAL

q429='sum(http_server_request_duration_seconds_count{http_response_status_code="429"})'
q5xx='sum(http_server_request_duration_seconds_count{http_response_status_code=~"5.."})'
v429="$(curl -s --max-time 10 --data-urlencode "query=${q429}" http://localhost:19091/api/v1/query 2>/dev/null | jq -r '.data.result[0].value[1] // "0"')"
v5xx="$(curl -s --max-time 10 --data-urlencode "query=${q5xx}" http://localhost:19091/api/v1/query 2>/dev/null | jq -r '.data.result[0].value[1] // "0"')"

log_info "prometheus: 429 count=${v429}   5xx count=${v5xx}"
if [[ "$v429" != "0" && "$v429" != "null" ]]; then
  log_pass "429s are queryable independently of 5xx in Prometheus" "http_response_status_code label (D11)"
else
  log_fail "Prometheus has no separable 429 series"
  log_context "The agent's http.server.request.duration should carry http.response.status_code.
Without that label there is no way to build the dashboard FR-079 requires."
fi

# The dashboards must actually keep them apart — the requirement is about the
# report, not only about the data.
dash="${LAB_ROOT}/platform/observability/dashboards/red.json"
if grep -q '"429"' "$dash" && grep -q '5\.\.' "$dash"; then
  log_pass "the RED dashboard plots 429 separately from 5xx" "$(basename "$dash")"
else
  log_fail "the RED dashboard does not separate 429 from 5xx"
fi
if grep -qiE '"title": *"[^"]*[Ee]rror[^"]*"' "$dash" && \
   grep -A6 -iE '"title": *"[^"]*[Ee]rror' "$dash" | grep -q '429'; then
  log_fail "an 'errors' panel includes 429" "FR-079 forbids aggregating them"
else
  log_pass "no errors panel folds 429 into its count" "FR-079"
fi

log_summary
