#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# validate.sh — `make validate` and `make validate-full` (FR-100, FR-101, SC-015).
#
# THE DIVISION OF LABOUR, which FR-101 and FR-099 draw deliberately:
#
#   make test       EXECUTES the suites
#   make validate   REPORTS a per-component verdict and one overall verdict
#   make validate-full  destroys, rebuilds and then does both
#
# The Validation Result entity (data-model §11) requires an `evidence` field on
# every row: the command whose exit status produced the verdict. That is not
# bookkeeping — it is what makes an asserted pass structurally impossible to
# express here. Every row below carries the command that produced it.
#
# `SKIPPED-BY-CONFIGURATION` exists only for reduced mode and is NEVER
# presentable as a pass (D18).
# ---------------------------------------------------------------------------
set -uo pipefail

LAB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${LAB_ROOT}/scripts/lib/versions.sh"
source "${LAB_ROOT}/scripts/lib/log.sh"

FULL=0
[[ "${1:-}" == "--full" ]] && FULL=1
REDUCED="${LAB_REDUCED:-0}"

# Parallel arrays: macOS ships Bash 3.2, which has no associative arrays, and
# row ORDER is part of the report.
ROW_COMPONENT=()
ROW_VERDICT=()
ROW_EVIDENCE=()

# record <component> <verdict> <evidence>
record() {
  ROW_COMPONENT+=("$1")
  ROW_VERDICT+=("$2")
  ROW_EVIDENCE+=("$3")
}

# check <component> <command...> — the verdict comes from the exit status, and
# the command itself becomes the evidence.
check() {
  local component="$1"; shift
  local evidence="$*"
  if "$@" >/dev/null 2>&1; then
    record "$component" "PASS" "$evidence"
  else
    record "$component" "FAIL" "$evidence"
  fi
}

# ---------------------------------------------------------------------------
# validate-full (FR-100): destroy -> remove local state -> recreate -> install
# -> deploy -> wait -> smoke + integration + conformance.
#
# NEVER part of `make test` (FR-099). It is the reproducibility check, and it
# takes as long as a full setup because that is what it is measuring.
# ---------------------------------------------------------------------------
if (( FULL )); then
  log_suite "validate-full"
  printf 'Destroying and rebuilding the entire environment. This is not a fast path.\n\n'

  local_start="$(date +%s)"

  if ! "${LAB_ROOT}/scripts/cleanup.sh"; then
    printf '\nvalidate-full: FAIL at cleanup — the environment could not be torn down.\n'
    printf 'A lab that cannot be destroyed cannot be rebuilt reproducibly (FR-109).\n'
    exit 1
  fi

  setup_args=()
  (( REDUCED )) && setup_args+=(--reduced)
  if ! "${LAB_ROOT}/scripts/setup.sh" ${setup_args[@]+"${setup_args[@]}"}; then
    printf '\nvalidate-full: FAIL during setup. The checkpoint report above names where.\n'
    exit 1
  fi

  elapsed=$(( $(date +%s) - local_start ))
  printf '\nRebuild took %dm %ds.\n' $(( elapsed / 60 )) $(( elapsed % 60 ))

  # Then the ordinary verdict, over the environment just rebuilt.
fi

# ---------------------------------------------------------------------------
# The verdict table.
# ---------------------------------------------------------------------------
log_suite "validate"

K="kubectl --context ${LAB_KUBECONTEXT}"

if ! $K cluster-info >/dev/null 2>&1; then
  printf '\nNo cluster. Every component below would report FAIL for the same reason,\n'
  printf 'which is not a useful report. Run `make setup` first.\n'
  exit 1
fi

# --- Platform --------------------------------------------------------------
check "cluster"          "${LAB_ROOT}/scripts/cluster.sh" health --quiet
check "networking"       "${LAB_ROOT}/scripts/platform.sh" net-status --quiet
check "gateway-api-crds" "${LAB_ROOT}/scripts/platform.sh" gateway-api-check --quiet
check "gateway"          "${LAB_ROOT}/scripts/platform.sh" gw-status --quiet
check "registry"         "${LAB_ROOT}/scripts/registry.sh" status --quiet
check "tls-material"     "${LAB_ROOT}/scripts/certs.sh" verify
check "namespaces"       "${LAB_ROOT}/scripts/platform.sh" namespaces-check --quiet

# --- Data and applications -------------------------------------------------
check "datastores"       "${LAB_ROOT}/scripts/app.sh" backing-services-check --quiet
check "schema"           "${LAB_ROOT}/scripts/app.sh" migrate-check --quiet
check "fixture"          "${LAB_ROOT}/scripts/app.sh" fixture-check --quiet
check "applications"     "${LAB_ROOT}/scripts/app.sh" status --quiet

# --- Observability and delivery -------------------------------------------
check "observability"    "${LAB_ROOT}/scripts/platform.sh" observability-check --quiet
check "delivery"         "${LAB_ROOT}/scripts/consoles.sh" argocd-status --quiet
check "console"          "${LAB_ROOT}/scripts/platform.sh" console-check --quiet

# --- Suites ----------------------------------------------------------------
check "smoke-suite"       "${LAB_ROOT}/tests/smoke/run.sh"
check "integration-suite" "${LAB_ROOT}/tests/integration/run.sh"

if "${LAB_ROOT}/scripts/edge-conformance.sh" --available >/dev/null 2>&1; then
  check "edge-conformance" "${LAB_ROOT}/scripts/edge-conformance.sh" lab
else
  # NOT a pass, and not silence either. A component whose check could not run
  # has established nothing, and the report says which and why.
  record "edge-conformance" "BLOCKED" "no usable Maven/JVM on this host — 'make doctor' names it"
fi

# --- Reduced-mode exclusions ----------------------------------------------
if (( REDUCED )); then
  record "end-to-end-trace (SC-012)" "SKIPPED-BY-CONFIGURATION" \
         "reduced mode disables Tempo (D18) — never reported as a pass"
fi

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
printf '\n'
printf '%-26s %-26s %s\n' "COMPONENT" "VERDICT" "EVIDENCE"
printf '%-26s %-26s %s\n' "--------------------------" "--------------------------" "------------------------------------------"

fails=0; blocked=0; skips=0; passes=0
for i in "${!ROW_COMPONENT[@]}"; do
  printf '%-26s %-26s %s\n' "${ROW_COMPONENT[$i]}" "${ROW_VERDICT[$i]}" "${ROW_EVIDENCE[$i]}"
  case "${ROW_VERDICT[$i]}" in
    PASS)                     passes=$(( passes + 1 )) ;;
    FAIL)                     fails=$(( fails + 1 )) ;;
    BLOCKED)                  blocked=$(( blocked + 1 )) ;;
    SKIPPED-BY-CONFIGURATION) skips=$(( skips + 1 )) ;;
  esac
done

printf '\n%d PASS   %d FAIL   %d BLOCKED   %d SKIPPED-BY-CONFIGURATION\n' \
  "$passes" "$fails" "$blocked" "$skips"

# A BLOCKED component counts against the overall verdict. It did not establish
# what it exists to establish, and reporting green while a check never ran is
# precisely what FR-098 forbids.
if (( fails > 0 || blocked > 0 )); then
  printf '\nOVERALL: FAIL\n'
  (( blocked > 0 )) && printf '  (%d component(s) BLOCKED — a check that did not run is not a pass.)\n' "$blocked"
  exit 1
fi

printf '\nOVERALL: PASS\n'
if (( skips > 0 )); then
  printf '  %d component(s) SKIPPED-BY-CONFIGURATION. Those scenarios are UNAVAILABLE in this\n' "$skips"
  printf '  mode, not passing. Run `make setup` rather than `make setup-reduced` to cover them.\n'
fi
exit 0
