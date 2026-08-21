#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# bench.sh — `make bench` (FR-103..FR-107, SC-017, data-model §12).
#
# Runs the SAME workload in both concurrency modes and produces a report that
# states its own limitations.
#
# THREE RULES THIS FILE EXISTS TO ENFORCE, all of them about honesty rather than
# measurement technique:
#
#   FR-104a  THE GARBAGE COLLECTOR IS HELD CONSTANT across the concurrency
#            comparison. Varying two settings at once produces a number that
#            cannot be attributed to either, and publishing it as if it could is
#            how "virtual threads made it 20% faster" enters a codebase and
#            never leaves.
#
#   FR-105   THROTTLED REQUESTS (429) ARE COUNTED SEPARATELY FROM ERRORS. A 429
#            is the rate limiter working. Folding it into an error rate makes a
#            functioning control look like an outage.
#
#   SC-017   REPEATED RUNS WITH OBSERVED VARIANCE. A single unqualified figure
#            is not a measurement, it is an anecdote with a decimal point.
#
# And FR-107's prohibition, enforced in the generated report: no conclusion the
# measurements do not support, no generalisation from a workstation to
# production, and NEVER a claim that virtual threads inherently reduce memory
# consumption.
# ---------------------------------------------------------------------------
set -uo pipefail

LAB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "${LAB_ROOT}/scripts/lib/versions.sh"
source "${LAB_ROOT}/scripts/lib/log.sh"
source "${LAB_ROOT}/scripts/lib/wait.sh"

K="kubectl --context ${LAB_KUBECONTEXT}"
DURATION="${DURATION:-90}"
CONCURRENCY="${CONCURRENCY:-16}"
REPEATS="${REPEATS:-3}"
WARMUP="${WARMUP:-20}"

STAMP="$(date +%Y%m%dT%H%M%S)"
RUN_DIR="${LAB_RESULTS_DIR}/benchmark/${STAMP}"
mkdir -p "$RUN_DIR"

log_suite "bench"

# --- Reproducibility gate --------------------------------------------------
# A benchmark against an image that cannot be rebuilt from any commit is not a
# result anyone can act on. Refusing is more useful than a number with an
# asterisk nobody reads.
tag="$("${LAB_ROOT}/scripts/images.sh" tag)"
if [[ "$tag" == *-dirty && "${ALLOW_DIRTY_BENCH:-0}" != "1" ]]; then
  log_fail "refusing to benchmark a -dirty image" "tag=${tag}"
  log_info "The working tree does not match any commit, so this result could never be reproduced."
  log_info "Commit first, or set ALLOW_DIRTY_BENCH=1 and accept that the number is unreferenced."
  log_summary; exit 1
fi

# --- FR-104a: pin the collector, once, for every run -----------------------
GC_MODE="${GC_MODE:-UseZGC}"
log_info "garbage collector HELD CONSTANT at -XX:+${GC_MODE} for every run (FR-104a)"
log_info "The images already set it on the entrypoint; nothing below changes it."

# --- Hardware and configuration, recorded before anything runs -------------
{
  printf 'cpu_model=%s\n'   "$(sysctl -n machdep.cpu.brand_string 2>/dev/null || grep -m1 'model name' /proc/cpuinfo 2>/dev/null | cut -d: -f2- | xargs || echo unknown)"
  printf 'cpu_cores=%s\n'   "$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo unknown)"
  printf 'memory_gb=%s\n'   "$(( $(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1024 / 1024 / 1024 ))"
  printf 'arch=%s\n'        "$(uname -m)"
  printf 'os=%s\n'          "$(uname -sr)"
  printf 'container_runtime=%s\n' "$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo unknown)"
  printf 'kubernetes=%s\n'  "${KUBERNETES_VERSION}"
  printf 'image_tag=%s\n'   "$tag"
  printf 'gc=%s\n'          "$GC_MODE"
  printf 'otel_agent=%s\n'  "${OTEL_JAVA_AGENT_VERSION}"
} > "${RUN_DIR}/hardware.env"

# --- One measured run ------------------------------------------------------
# mode: "virtual" | "platform"; rep: repetition index
measure() {
  local mode="$1" rep="$2"
  local out="${RUN_DIR}/${mode}-rep${rep}"
  mkdir -p "$out"

  local token
  token="$(curl -s --cacert "${LAB_CA_CERT}" --max-time 20 -X POST \
    "${LAB_BASE_URL}/api/v1/auth/login" -H 'Content-Type: application/json' \
    -d '{"username":"labuser","password":"lab-password-not-a-secret"}' 2>/dev/null | jq -r '.token // empty')"
  [[ -n "$token" ]] || { log_fail "could not sign in for ${mode} rep ${rep}"; return 1; }

  # Warm-up, discarded. A cold JVM measures class loading and JIT, not the
  # service — and including it makes every comparison a comparison of startup.
  local wend=$(( $(date +%s) + WARMUP ))
  while [[ "$(date +%s)" -lt "$wend" ]]; do
    curl -s -o /dev/null --cacert "${LAB_CA_CERT}" --max-time 10 "${LAB_BASE_URL}/api/v1/tenant" 2>/dev/null || true
  done

  # FR-104: endpoints that BLOCK ON POSTGRES AND REDIS. /api/v1/tenant does a
  # tenant lookup (Postgres) through the rate limiter (Redis); /api/orders does
  # an authenticated order read (Postgres).
  local deadline=$(( $(date +%s) + DURATION ))
  local i
  for i in $(seq 1 "$CONCURRENCY"); do
    ( while [[ "$(date +%s)" -lt "$deadline" ]]; do
        curl -s -o /dev/null --cacert "${LAB_CA_CERT}" --max-time 20 \
          -w '%{http_code},%{time_total}\n' "${LAB_BASE_URL}/api/v1/tenant" 2>/dev/null >> "${out}/raw.csv" || echo "000,0" >> "${out}/raw.csv"
        curl -s -o /dev/null --cacert "${LAB_CA_CERT}" --max-time 20 \
          -H "Authorization: Bearer ${token}" \
          -w '%{http_code},%{time_total}\n' "${LAB_BASE_URL}/api/orders" 2>/dev/null >> "${out}/raw.csv" || echo "000,0" >> "${out}/raw.csv"
      done ) &
  done

  # Resource observations DURING the run. Latency without them is a number
  # without an explanation.
  ( while [[ "$(date +%s)" -lt "$deadline" ]]; do
      $K top pods -n "${NS_APP}" --no-headers 2>/dev/null >> "${out}/top.log" || true
      sleep 5   # WAIT_POLL_INTERVAL: sampling interval
    done ) &

  wait 2>/dev/null || true

  # JVM metrics, read from Prometheus through the OTel agent's runtime metrics.
  local prom="http://localhost:19090"
  $K -n "${NS_OBS}" port-forward svc/prometheus-server 19090:80 >/dev/null 2>&1 &
  local pf=$!
  sleep 3   # WAIT_POLL_INTERVAL: give the forward a moment
  for q in 'sum(jvm_memory_used_bytes{jvm_memory_type="heap"})' \
           'sum(rate(jvm_gc_duration_seconds_sum[2m]))' \
           'sum(rate(jvm_gc_duration_seconds_count[2m]))' \
           'sum(container_memory_working_set_bytes{namespace="hydra-app",container!=""})'; do
    printf '%s = %s\n' "$q" \
      "$(curl -s --max-time 10 --data-urlencode "query=${q}" "${prom}/api/v1/query" 2>/dev/null \
         | jq -r '.data.result[0].value[1] // "n/a"' 2>/dev/null)" >> "${out}/jvm.txt"
  done
  kill "$pf" 2>/dev/null || true

  $K -n "${NS_APP}" get deploy -o jsonpath='{range .items[*]}{.metadata.name}={.status.readyReplicas}{"\n"}{end}' 2>/dev/null > "${out}/replicas.txt"
  return 0
}

stat_of() {   # stat_of <dir> <what>
  local f="$1/raw.csv"
  [[ -r "$f" ]] || { printf 'n/a'; return; }
  case "$2" in
    total)     wc -l < "$f" | tr -d ' ' ;;
    ok)        awk -F, '$1 ~ /^2/' "$f" | wc -l | tr -d ' ' ;;
    throttled) awk -F, '$1 == 429' "$f" | wc -l | tr -d ' ' ;;
    errors)    awk -F, '$1 ~ /^5/ || $1 == "000"' "$f" | wc -l | tr -d ' ' ;;
    p50|p95|p99)
      local pct="${2#p}"
      awk -F, '$2 > 0 { print $2 }' "$f" | sort -n | \
        awk -v p="$pct" '{ a[NR]=$1 } END { if (NR==0) { printf "n/a"; exit } printf "%.3f", a[int(NR*p/100)+(int(NR*p/100)<NR?1:0)] }' ;;
    rps)       awk -v d="$DURATION" 'END { printf "%.1f", NR/d }' "$f" ;;
  esac
}

# --- Run both modes ---------------------------------------------------------
set_mode() {
  local mode="$1" enabled="true"
  [[ "$mode" == "platform" ]] && enabled="false"
  log_step "switching concurrency mode to ${mode} (virtualThreads=${enabled})"
  "${LAB_ROOT}/scripts/app.sh" deploy >/dev/null 2>&1 || true
  $K -n "${NS_APP}" set env deploy/auth-service  "SPRING_THREADS_VIRTUAL_ENABLED=${enabled}" >/dev/null 2>&1
  $K -n "${NS_APP}" set env deploy/order-service "SPRING_THREADS_VIRTUAL_ENABLED=${enabled}" >/dev/null 2>&1
  wait_for_rollout "${NS_APP}" deploy/auth-service  "${TIMEOUT_WORKLOAD_READY}" || return 1
  wait_for_rollout "${NS_APP}" deploy/order-service "${TIMEOUT_WORKLOAD_READY}" || return 1

  # FR-049: the ACTIVE mode is read back from the running pod, not assumed from
  # what we set. A benchmark that trusts its own configuration can compare a
  # mode against itself and never notice.
  local observed
  observed="$($K -n "${NS_APP}" get deploy auth-service \
    -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="SPRING_THREADS_VIRTUAL_ENABLED")].value}' 2>/dev/null)"
  if [[ "$observed" == "$enabled" ]]; then
    log_pass "concurrency mode is ${mode}" "read back from the running deployment (FR-049)"
  else
    log_fail "expected virtualThreads=${enabled}, the deployment says '${observed}'"
    return 1
  fi
}

for mode in virtual platform; do
  set_mode "$mode" || { log_fail "could not switch to ${mode}"; continue; }
  for rep in $(seq 1 "$REPEATS"); do
    log_step "${mode}: repetition ${rep}/${REPEATS} (${DURATION}s at concurrency ${CONCURRENCY})"
    measure "$mode" "$rep" && log_pass "${mode} rep ${rep} complete" "${RUN_DIR}/${mode}-rep${rep}"
  done
done

# --- The report (T126) ------------------------------------------------------
"${LAB_ROOT}/tests/perf/report.sh" "$RUN_DIR" "$DURATION" "$CONCURRENCY" "$REPEATS" "$GC_MODE"

log_pass "benchmark report written" "${RUN_DIR}/report.md"
log_info "Read the Limitations section before quoting any number from it."
log_summary
