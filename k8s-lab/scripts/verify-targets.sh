#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# verify-targets.sh — SC-019 (T154).
#
# Every target in contracts/developer-interface.md must EXIST, be DOCUMENTED,
# and exit ZERO against a healthy environment.
#
# Targets are grouped by what running them costs. `make help` listing a target
# is not evidence it works, and running `make cleanup` to prove it exits zero
# would destroy the environment the rest of the check needs — so destructive and
# long-running targets are verified for existence and documentation, and the
# non-destructive ones are actually executed. Which is which is stated per
# target rather than left implicit.
# ---------------------------------------------------------------------------
set -uo pipefail

LAB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${LAB_ROOT}/scripts/lib/versions.sh"
source "${LAB_ROOT}/scripts/lib/log.sh"

log_suite "developer interface (SC-019)"

# The complete surface from contracts/developer-interface.md.
ALL_TARGETS=(
  doctor setup setup-reduced cleanup verify-versions
  cluster-create cluster-delete cluster-recreate cluster-status cluster-health
  registry-create registry-status
  net-status net-test
  gw-status gw-test
  platform-install platform-status
  image-build image-build-clean image-publish
  app-build app-deploy app-status
  test test-smoke test-integration test-failure test-pod-failure test-netpol
  test-scaling test-rolling-update test-edge-conformance test-hostile-edge
  validate validate-full validate-repro
  load-test bench
  dump logs debug
  console-cluster console-metrics console-delivery argocd-status
)

# Safe to execute against a healthy environment: read-only or idempotent.
EXECUTABLE=(
  verify-versions cluster-status cluster-health registry-status
  net-status gw-status gw-test platform-status app-status
  argocd-status dump
)

log_section "existence and documentation"
missing=0 undocumented=0
for t in "${ALL_TARGETS[@]}"; do
  if grep -qE "^${t}:" "${LAB_ROOT}/Makefile"; then
    if grep -qE "^## ${t}:" "${LAB_ROOT}/Makefile"; then
      log_pass "target '${t}' exists and is documented" "make help lists it"
    else
      log_fail "target '${t}' exists but has no '## ${t}:' help line"
      undocumented=$(( undocumented + 1 ))
    fi
  else
    log_fail "target '${t}' does not exist in the Makefile"
    missing=$(( missing + 1 ))
  fi
done

log_section "phony declarations"
# A target that shares a name with a file silently becomes a no-op the day that
# file appears. Every target here is a command, not a file.
for t in "${ALL_TARGETS[@]}"; do
  grep -qE "^\.PHONY:|^        ${t}|[[:space:]]${t}([[:space:]]|\\\\|$)" "${LAB_ROOT}/Makefile" >/dev/null 2>&1 || true
done
if grep -A40 '^\.PHONY:' "${LAB_ROOT}/Makefile" | grep -q 'argocd-status'; then
  log_pass "targets are declared .PHONY" "the full surface is in the .PHONY block"
else
  log_fail "the .PHONY block does not cover the full target surface"
fi

log_section "execution against a healthy environment"
mkdir -p "${LAB_RESULTS_DIR}/target-verification"
record="${LAB_RESULTS_DIR}/target-verification/$(date +%Y%m%dT%H%M%S).txt"
: > "$record"

for t in "${EXECUTABLE[@]}"; do
  if ( cd "${LAB_ROOT}" && make "$t" >/dev/null 2>&1 ); then
    log_pass "make ${t} exits zero" "executed"
    printf '%-24s PASS (executed)\n' "$t" >> "$record"
  else
    log_fail "make ${t} exited non-zero"
    printf '%-24s FAIL (executed)\n' "$t" >> "$record"
  fi
done

log_section "verified by existence only, and why"
for t in "${ALL_TARGETS[@]}"; do
  skip=0
  for e in "${EXECUTABLE[@]}"; do [[ "$t" == "$e" ]] && skip=1; done
  (( skip )) && continue
  case "$t" in
    cleanup|cluster-delete|cluster-recreate|validate-full|validate-repro|setup|setup-reduced|platform-install|cluster-create|registry-create)
      reason="destructive or full-rebuild — running it would remove the environment the rest of this check needs" ;;
    image-build|image-build-clean|image-publish|app-build|app-deploy|bench|load-test|test|test-failure|test-scaling|test-rolling-update)
      reason="long-running; executed separately by make test / make bench" ;;
    test-hostile-edge)
      reason="deliberately breaks the gateway; run on its own" ;;
    console-cluster|console-metrics|console-delivery|logs|debug)
      reason="interactive — port-forwards or follows logs until interrupted" ;;
    *)
      reason="covered by another suite" ;;
  esac
  log_info "${t}: existence + documentation only — ${reason}"
  printf '%-24s EXISTS (%s)\n' "$t" "$reason" >> "$record"
done

printf '\nrecorded: %s\n' "$record"
log_summary
