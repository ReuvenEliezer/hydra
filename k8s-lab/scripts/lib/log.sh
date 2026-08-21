#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# log.sh — the lab's verdict vocabulary.
#
# Four verdicts exist and no more (contracts/developer-interface.md):
#
#   PASS                      an executed check succeeded
#   FAIL                      an executed check failed
#   SKIPPED-BY-CONFIGURATION  reduced mode disabled the component under test;
#                             never presentable as a pass (FR-091, D18)
#   BLOCKED                   a prerequisite checkpoint failed, so this check
#                             was never executed
#
# There is deliberately no WARN at suite level. A check either validated
# something or it did not — and "it looked fine" is what FR-098 exists to
# forbid. `doctor.sh` is the single exception: it reports host findings, not
# suite verdicts, and WARN is meaningful for an optional prerequisite there.
# It uses log_warn, which is not counted in the suite tallies below.
# ---------------------------------------------------------------------------
set -uo pipefail

if [[ -t 1 ]] && [[ "${NO_COLOR:-}" == "" ]]; then
  _C_RESET=$'\033[0m'; _C_RED=$'\033[31m'; _C_GREEN=$'\033[32m'
  _C_YELLOW=$'\033[33m'; _C_BLUE=$'\033[34m'; _C_DIM=$'\033[2m'; _C_BOLD=$'\033[1m'
else
  _C_RESET=""; _C_RED=""; _C_GREEN=""; _C_YELLOW=""; _C_BLUE=""; _C_DIM=""; _C_BOLD=""
fi

LOG_PASS_COUNT=0
LOG_FAIL_COUNT=0
LOG_SKIP_COUNT=0
LOG_BLOCKED_COUNT=0
LOG_WARN_COUNT=0
LOG_SUITE_NAME="${LOG_SUITE_NAME:-lab}"
# Every failed check's name, so the summary can name them rather than only count.
LOG_FAILED_CHECKS=()

log_suite() {
  LOG_SUITE_NAME="$1"
  printf '%s\n' "${_C_BOLD}=== ${LOG_SUITE_NAME} ===${_C_RESET}"
}

log_section() { printf '\n%s\n' "${_C_BOLD}-- $* --${_C_RESET}"; }
log_info()    { printf '%s\n' "${_C_DIM}   $*${_C_RESET}"; }
log_step()    { printf '%s\n' "${_C_BLUE}==>${_C_RESET} $*"; }

# log_pass <check> [evidence]
# `evidence` is the command whose exit status produced the verdict (data-model
# §11). It is optional at call sites that already printed the command, and
# required by convention everywhere else — an asserted pass with no evidence is
# what the Validation Result entity is shaped to make hard to express.
log_pass() {
  LOG_PASS_COUNT=$((LOG_PASS_COUNT + 1))
  printf '%sPASS%s  %s%s\n' "${_C_GREEN}" "${_C_RESET}" "$1" \
    "${2:+  ${_C_DIM}[$2]${_C_RESET}}"
}

log_fail() {
  LOG_FAIL_COUNT=$((LOG_FAIL_COUNT + 1))
  LOG_FAILED_CHECKS+=("$1")
  printf '%sFAIL%s  %s%s\n' "${_C_RED}" "${_C_RESET}" "$1" \
    "${2:+  ${_C_DIM}[$2]${_C_RESET}}"
}

# log_skip <check> <reason>
# The reason is mandatory: a skip with no stated cause is indistinguishable
# from a check that quietly stopped running, which D18 calls worse than a
# failure.
log_skip() {
  LOG_SKIP_COUNT=$((LOG_SKIP_COUNT + 1))
  printf '%sSKIPPED-BY-CONFIGURATION%s  %s  %s(%s)%s\n' \
    "${_C_YELLOW}" "${_C_RESET}" "$1" "${_C_DIM}" "${2:?a skip must state its reason}" "${_C_RESET}"
}

log_blocked() {
  LOG_BLOCKED_COUNT=$((LOG_BLOCKED_COUNT + 1))
  printf '%sBLOCKED%s  %s  %s(%s)%s\n' \
    "${_C_YELLOW}" "${_C_RESET}" "$1" "${_C_DIM}" "${2:-prerequisite failed}" "${_C_RESET}"
}

# doctor.sh only — see the header.
log_warn() {
  LOG_WARN_COUNT=$((LOG_WARN_COUNT + 1))
  printf '%sWARN%s  %s%s\n' "${_C_YELLOW}" "${_C_RESET}" "$1" \
    "${2:+  ${_C_DIM}[$2]${_C_RESET}}"
}

log_error() { printf '%sERROR%s %s\n' "${_C_RED}" "${_C_RESET}" "$*" >&2; }

# Diagnostic context on failure. Printed indented so it is visibly subordinate
# to the FAIL line it explains, rather than competing with it.
log_context() {
  local line
  while IFS= read -r line; do
    printf '%s\n' "${_C_DIM}      | ${line}${_C_RESET}"
  done <<< "$*"
}

# log_summary — prints the tally and returns the suite's exit code.
# Non-zero when anything failed or was blocked. A blocked check is a non-zero
# outcome on purpose: the suite did not establish what it exists to establish.
log_summary() {
  local total=$((LOG_PASS_COUNT + LOG_FAIL_COUNT + LOG_SKIP_COUNT + LOG_BLOCKED_COUNT))
  printf '\n%s\n' "${_C_BOLD}--- ${LOG_SUITE_NAME}: ${total} checks ---${_C_RESET}"
  printf '  %sPASS%s %d   %sFAIL%s %d   SKIPPED-BY-CONFIGURATION %d   BLOCKED %d\n' \
    "${_C_GREEN}" "${_C_RESET}" "${LOG_PASS_COUNT}" \
    "${_C_RED}" "${_C_RESET}" "${LOG_FAIL_COUNT}" \
    "${LOG_SKIP_COUNT}" "${LOG_BLOCKED_COUNT}"
  if (( LOG_FAIL_COUNT > 0 )); then
    printf '  %sfailed:%s\n' "${_C_RED}" "${_C_RESET}"
    local c
    for c in "${LOG_FAILED_CHECKS[@]}"; do printf '    - %s\n' "$c"; done
  fi
  if (( LOG_FAIL_COUNT > 0 || LOG_BLOCKED_COUNT > 0 )); then
    printf '%s\n' "${_C_RED}${LOG_SUITE_NAME}: FAIL${_C_RESET}"
    return 1
  fi
  if (( total == 0 )); then
    # A suite that executed nothing has not passed. Silence is not success.
    printf '%s\n' "${_C_RED}${LOG_SUITE_NAME}: FAIL (no check executed)${_C_RESET}"
    return 1
  fi
  printf '%s\n' "${_C_GREEN}${LOG_SUITE_NAME}: PASS${_C_RESET}"
  return 0
}
