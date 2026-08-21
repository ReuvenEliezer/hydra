#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# load-test.sh — `make load-test` (FR-071).
#
# Drives traffic THROUGH THE ACTUAL GATEWAY. Not to a Service, not through a
# port-forward, not against a pod address — through the same path a real client
# takes, because a load test that bypasses the edge measures a system nobody
# runs.
#
# The endpoints chosen BLOCK ON POSTGRES AND REDIS (FR-104). A load test against
# an endpoint that returns a constant measures the JVM's ability to serialise a
# constant, which is not a property anyone cares about.
# ---------------------------------------------------------------------------
set -uo pipefail

LAB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "${LAB_ROOT}/scripts/lib/versions.sh"
source "${LAB_ROOT}/scripts/lib/log.sh"
source "${LAB_ROOT}/scripts/lib/wait.sh"

DURATION="${DURATION:-120}"
CONCURRENCY="${CONCURRENCY:-16}"
K="kubectl --context ${LAB_KUBECONTEXT}"

log_suite "load-test"
log_info "duration ${DURATION}s, concurrency ${CONCURRENCY}, through ${LAB_BASE_URL}"
log_info "endpoints block on Postgres (tenant lookup, order read) and Redis (rate limiter) — FR-104"

if ! wait_for_http "the gateway is serving" 120 "200" "${LAB_BASE_URL}/api/v1/tenant"; then
  log_summary; exit 1
fi

TOKEN="$(curl -s --cacert "${LAB_CA_CERT}" --max-time 20 -X POST \
  "${LAB_BASE_URL}/api/v1/auth/login" -H 'Content-Type: application/json' \
  -d '{"username":"labuser","password":"lab-password-not-a-secret"}' 2>/dev/null | jq -r '.token // empty')"
if [[ -z "$TOKEN" ]]; then
  log_fail "could not sign in to obtain a token for the load run"
  log_summary; exit 1
fi

RUN_DIR="${LAB_RESULTS_DIR}/load-test/$(date +%Y%m%dT%H%M%S)"
mkdir -p "$RUN_DIR"

printf '\nreplica counts before:\n' | tee "${RUN_DIR}/replicas-before.txt"
$K -n "${NS_APP}" get deploy -o wide 2>&1 | tee -a "${RUN_DIR}/replicas-before.txt"

worker() {
  local id="$1" deadline="$2"
  local out="${RUN_DIR}/w${id}.csv"
  : > "$out"
  while [[ "$(date +%s)" -lt "$deadline" ]]; do
    # Alternates two endpoints: one hits Postgres through tenant resolution and
    # the rate limiter through Redis; the other hits Postgres through the order
    # repository. Both are real work.
    curl -s -o /dev/null --cacert "${LAB_CA_CERT}" --max-time 20 \
      -w '%{http_code},%{time_total}\n' "${LAB_BASE_URL}/api/v1/tenant" 2>/dev/null >> "$out" || echo "000,0" >> "$out"
    curl -s -o /dev/null --cacert "${LAB_CA_CERT}" --max-time 20 \
      -H "Authorization: Bearer ${TOKEN}" \
      -w '%{http_code},%{time_total}\n' "${LAB_BASE_URL}/api/orders" 2>/dev/null >> "$out" || echo "000,0" >> "$out"
  done
}

start="$(date +%s)"
deadline=$(( start + DURATION ))
for i in $(seq 1 "$CONCURRENCY"); do worker "$i" "$deadline" & done

# Sample resource state during the run — the numbers that make a latency figure
# interpretable rather than merely true.
( while [[ "$(date +%s)" -lt "$deadline" ]]; do
    printf '%s ' "$(date +%s)" >> "${RUN_DIR}/replicas.log"
    $K -n "${NS_APP}" get deploy -o jsonpath='{range .items[*]}{.metadata.name}={.status.readyReplicas} {end}' 2>/dev/null >> "${RUN_DIR}/replicas.log"
    printf '\n' >> "${RUN_DIR}/replicas.log"
    sleep 5   # WAIT_POLL_INTERVAL: sampling interval
  done ) &
sampler=$!

wait $(jobs -p | grep -v "$sampler") 2>/dev/null || true
kill "$sampler" 2>/dev/null || true
wait 2>/dev/null || true
elapsed=$(( $(date +%s) - start ))

cat "${RUN_DIR}"/w*.csv > "${RUN_DIR}/all.csv" 2>/dev/null

total="$(wc -l < "${RUN_DIR}/all.csv" | tr -d ' ')"
ok="$(awk -F, '$1 ~ /^2/' "${RUN_DIR}/all.csv" | wc -l | tr -d ' ')"
throttled="$(awk -F, '$1 == 429' "${RUN_DIR}/all.csv" | wc -l | tr -d ' ')"
errors="$(awk -F, '$1 ~ /^5/ || $1 == "000"' "${RUN_DIR}/all.csv" | wc -l | tr -d ' ')"

# Percentiles from the observed distribution.
percentile() {
  awk -F, -v p="$1" '$2 > 0 { print $2 }' "${RUN_DIR}/all.csv" | sort -n | \
    awk -v p="$1" '{ a[NR]=$1 } END { if (NR==0) { print "n/a"; exit } printf "%.3f", a[int(NR*p/100)+ (int(NR*p/100)<NR?1:0)] }'
}

rps="$(awk -v t="$total" -v s="$elapsed" 'BEGIN { printf "%.1f", (s>0)? t/s : 0 }')"

{
  printf 'requests   %s over %ss  (%s rps)\n' "$total" "$elapsed" "$rps"
  printf '2xx        %s\n' "$ok"
  printf '429        %s   <- throttled, counted SEPARATELY from errors (FR-105, D11)\n' "$throttled"
  printf '5xx/none   %s\n' "$errors"
  printf 'p50        %ss\n' "$(percentile 50)"
  printf 'p95        %ss\n' "$(percentile 95)"
  printf 'p99        %ss\n' "$(percentile 99)"
} | tee "${RUN_DIR}/summary.txt"

printf '\nreplica counts after:\n' | tee "${RUN_DIR}/replicas-after.txt"
$K -n "${NS_APP}" get deploy,hpa -o wide 2>&1 | tee -a "${RUN_DIR}/replicas-after.txt"

log_pass "load run complete" "${RUN_DIR}"
log_info "A 429 is the limiter working, not a failure. It is never folded into the error count."
log_info "These numbers describe THIS workstation under THIS workload. See docs/resource-tuning.md"
log_info "before drawing any conclusion from them."
log_summary
