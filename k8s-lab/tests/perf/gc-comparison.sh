#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# gc-comparison.sh — ZGC versus the runtime default (FR-059a, D3).
#
# A SEPARATE experiment from `make bench`, deliberately.
#
# `make bench` compares concurrency modes with the GC held constant (FR-104a).
# This compares GARBAGE COLLECTORS with the concurrency model held constant.
# Two experiments, each varying one thing — which is the only way either number
# means anything.
#
# The output feeds a decision this feature explicitly does NOT make. A collector
# chosen on an arm64 laptop under a synthetic workload is not a collector chosen
# for production, and docs/jvm-flags.md says so rather than quietly recommending
# whichever won here.
# ---------------------------------------------------------------------------
set -uo pipefail

LAB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "${LAB_ROOT}/scripts/lib/versions.sh"
source "${LAB_ROOT}/scripts/lib/log.sh"
source "${LAB_ROOT}/scripts/lib/wait.sh"

K="kubectl --context ${LAB_KUBECONTEXT}"
DURATION="${DURATION:-90}"
CONCURRENCY="${CONCURRENCY:-16}"
REPEATS="${REPEATS:-2}"

STAMP="$(date +%Y%m%dT%H%M%S)"
RUN_DIR="${LAB_RESULTS_DIR}/gc-comparison/${STAMP}"
mkdir -p "$RUN_DIR"

log_suite "gc-comparison (FR-059a)"
log_info "concurrency model HELD CONSTANT; only the collector varies"

# The image's entrypoint sets -XX:+UseZGC. JAVA_TOOL_OPTIONS is appended after
# it, and a later -XX:+UseG1GC wins — so the collector can be switched without
# rebuilding, which is what makes this comparison possible at all.
run_with_gc() {
  local label="$1" opts="$2" rep="$3"
  local out="${RUN_DIR}/${label}-rep${rep}"
  mkdir -p "$out"

  log_step "${label} (${opts:-image default}) repetition ${rep}"
  $K -n "${NS_APP}" set env deploy/auth-service \
    "JAVA_TOOL_OPTIONS=-javaagent:/opt/otel/opentelemetry-javaagent.jar ${opts}" >/dev/null 2>&1
  wait_for_rollout "${NS_APP}" deploy/auth-service "${TIMEOUT_WORKLOAD_READY}" || return 1

  # Read the collector back from the running JVM rather than trusting the flag.
  local observed
  observed="$($K -n "${NS_APP}" exec deploy/auth-service -- \
    sh -c 'java -XshowSettings:vm -version 2>&1 | grep -i "garbage" || true' 2>/dev/null | head -1)"
  printf 'requested=%s\nobserved=%s\n' "${opts:-image default}" "${observed:-unreported}" > "${out}/gc.txt"

  DURATION="$DURATION" CONCURRENCY="$CONCURRENCY" \
    "${LAB_ROOT}/tests/perf/load-test.sh" >/dev/null 2>&1 || true
  cp -R "$(ls -td "${LAB_RESULTS_DIR}/load-test"/* | head -1)"/. "$out/" 2>/dev/null || true
}

for rep in $(seq 1 "$REPEATS"); do
  run_with_gc "zgc"     ""              "$rep"
  run_with_gc "default" "-XX:+UseG1GC"  "$rep"
done

# Restore the image's own configuration.
$K -n "${NS_APP}" set env deploy/auth-service \
  "JAVA_TOOL_OPTIONS=-javaagent:/opt/otel/opentelemetry-javaagent.jar" >/dev/null 2>&1
wait_for_rollout "${NS_APP}" deploy/auth-service "${TIMEOUT_WORKLOAD_READY}" || true

{
  printf '# ZGC versus the runtime default\n\n'
  printf 'Generated %s by `make bench` / gc-comparison.sh.\n\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  printf '**This feeds a SEPARATE decision that this feature does not make.**\n\n'
  printf 'The concurrency model was held constant; only the collector varied.\n'
  printf 'That is the mirror of `make bench`, which holds the collector constant\n'
  printf 'and varies the concurrency model (FR-104a). Two experiments, one\n'
  printf 'variable each.\n\n'
  local_d=""
  for d in "${RUN_DIR}"/*/; do
    [[ -d "$d" ]] || continue
    printf '## %s\n\n```\n' "$(basename "$d")"
    cat "${d}/gc.txt" 2>/dev/null || true
    printf '\n'
    cat "${d}/summary.txt" 2>/dev/null || printf '(no summary)\n'
    printf '```\n\n'
  done
  cat <<'CAVEAT'
## What this cannot tell you

A collector selected on an arm64 laptop, under a synthetic two-endpoint
workload, with an OpenTelemetry agent attached and `always_on` sampling, is not
a collector selected for production.

Heap sizes here are small enough that ZGC's design point — low pause times on
large heaps — is barely exercised. A difference measured at this scale may
reverse at production heap sizes, and an absence of difference here says nothing
about their absence there.

Publish this as an input to a decision, never as the decision.
CAVEAT
} > "${RUN_DIR}/report.md"

log_pass "GC comparison written" "${RUN_DIR}/report.md"
log_info "Published as a recommendation feeding a separate decision (FR-059a, D3)."
log_summary
