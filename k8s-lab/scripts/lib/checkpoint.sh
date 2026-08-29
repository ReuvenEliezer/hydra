#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# checkpoint.sh — the PENDING -> RUNNING -> PASSED|FAILED state machine
# (data-model §2, FR-014, FR-098).
#
# The single invariant this file exists to enforce:
#
#     A checkpoint may report PASSED only if its VALIDATION command exited
#     zero. No checkpoint asserts its own success.
#
# That is why `checkpoint_run` takes the action and the validation as two
# separate arguments and ignores the action's exit code for the verdict. An
# action that "succeeded" and left nothing working is a failure here, which is
# the whole point: `helm install` returning zero is not evidence that anything
# is serving.
#
# There is no SKIPPED-BUT-OK state. A checkpoint whose precondition failed is
# BLOCKED, reports as BLOCKED, and contributes a non-zero exit — it did not
# establish what it exists to establish.
# ---------------------------------------------------------------------------
set -uo pipefail

_CP_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./log.sh
[[ -n "${LOG_PASS_COUNT:-}" ]] || source "${_CP_LIB_DIR}/log.sh"

# Ordered registry. Parallel arrays rather than an associative array because
# order is part of the contract and macOS ships Bash 3.2, where associative
# arrays do not exist.
CHECKPOINT_NAMES=()
CHECKPOINT_STATES=()      # PENDING | RUNNING | PASSED | FAILED | BLOCKED
CHECKPOINT_SUMMARIES=()
CHECKPOINT_FAILED_AT=""   # the first failure; everything after it is BLOCKED

checkpoint_register() {
  CHECKPOINT_NAMES+=("$1")
  CHECKPOINT_STATES+=("PENDING")
  CHECKPOINT_SUMMARIES+=("")
}

_checkpoint_index() {
  local name="$1" i
  for i in "${!CHECKPOINT_NAMES[@]}"; do
    [[ "${CHECKPOINT_NAMES[$i]}" == "$name" ]] && { printf '%s' "$i"; return 0; }
  done
  return 1
}

checkpoint_state() {
  local i; i="$(_checkpoint_index "$1")" || { printf 'UNKNOWN'; return 1; }
  printf '%s' "${CHECKPOINT_STATES[$i]}"
}

_checkpoint_set() {
  local i; i="$(_checkpoint_index "$1")" || return 1
  CHECKPOINT_STATES[$i]="$2"
  [[ -n "${3:-}" ]] && CHECKPOINT_SUMMARIES[$i]="$3"
  return 0
}

# checkpoint_run <name> <action-command> <validation-command> [summary]
#
# `action` and `validation` are shell strings, evaluated with `bash -c`. They
# are separate on purpose — see the header.
checkpoint_run() {
  local name="$1" action="$2" validation="$3" summary="${4:-}"

  _checkpoint_index "$name" >/dev/null || checkpoint_register "$name"

  # Precondition: any earlier failure blocks everything after it (FR-014).
  if [[ -n "$CHECKPOINT_FAILED_AT" ]]; then
    _checkpoint_set "$name" "BLOCKED"
    log_blocked "checkpoint ${name}" "checkpoint '${CHECKPOINT_FAILED_AT}' failed earlier in this run"
    return 1
  fi

  _checkpoint_set "$name" "RUNNING"
  log_step "checkpoint ${name}: running"

  # ── HOW THE EXIT STATUS IS CAPTURED, and why it is written THIS way ──────
  #
  #   out="$(cmd)" || rc=$?          correct
  #   if ! out="$(cmd)"; then rc=$?  WRONG — rc is ALWAYS 0
  #
  # In `if ! cmd; then`, `$?` inside the branch is the status of the NEGATION,
  # not of `cmd`. When `cmd` fails, `! cmd` SUCCEEDS, so `$?` is 0.
  #
  # Both captures below were written in the wrong form, and it defeated this
  # file's single stated invariant completely: `validation_rc` was always 0, so
  # `(( validation_rc == 0 ))` was always true, so EVERY checkpoint reported
  # PASSED no matter what its validation did. A runner whose whole purpose is
  # "no checkpoint asserts its own success" asserted the success of all of them.
  #
  # Measured, not reasoned about: during an SC-003 reproducibility run the
  # `images` checkpoint printed `image publish: FAIL — refusing to publish a
  # -dirty image` from its own validation command and was recorded as
  #
  #     PASS  checkpoint images  [images.sh publish]
  #
  # Setup then reported "All 15 checkpoints PASSED", the registry was empty, and
  # the first honest signal came two checkpoints later as ImagePullBackOff —
  # naming a registry that was perfectly healthy.
  #
  # The same bug on `action_rc` silenced the "the action exited N while the
  # validation passed" note, which is precisely the diagnostic that would have
  # surfaced this years earlier.
  local action_rc=0 action_out=""
  if [[ -n "$action" ]]; then
    action_out="$(bash -c "$action" 2>&1)" || action_rc=$?
    # Action output is shown regardless of exit code: a helm install that fails
    # halfway is diagnosed from what it printed, not from its status alone.
    [[ -n "$action_out" ]] && log_context "$action_out"
  fi

  # The verdict comes from the validation, and only from the validation.
  local validation_out="" validation_rc=0
  validation_out="$(bash -c "$validation" 2>&1)" || validation_rc=$?

  if (( validation_rc == 0 )); then
    _checkpoint_set "$name" "PASSED" "$summary"
    log_pass "checkpoint ${name}" "${validation}"
    [[ -n "$summary" ]] && log_info "$summary"
    if (( action_rc != 0 )); then
      # Worth saying out loud rather than absorbing: the state is correct, but
      # the action reported a problem and someone should know why.
      log_info "note: the action exited ${action_rc} while the validation passed — converged from existing state, or the action is noisier than it should be"
    fi
    return 0
  fi

  _checkpoint_set "$name" "FAILED" "$summary"
  CHECKPOINT_FAILED_AT="$name"
  log_fail "checkpoint ${name}" "${validation}"
  log_context "validation exit ${validation_rc}
${validation_out}"
  [[ "$action_rc" != 0 ]] && log_context "the action had already exited ${action_rc}"
  return 1
}

# checkpoint_report — the ordered state table plus the run's exit code.
checkpoint_report() {
  local i name state failed=0 blocked=0 passed=0
  printf '\n%s\n' "--- checkpoints ---"
  for i in "${!CHECKPOINT_NAMES[@]}"; do
    name="${CHECKPOINT_NAMES[$i]}"
    state="${CHECKPOINT_STATES[$i]}"
    printf '  %-20s %s%s\n' "$name" "$state" \
      "${CHECKPOINT_SUMMARIES[$i]:+  — ${CHECKPOINT_SUMMARIES[$i]}}"
    case "$state" in
      FAILED)  failed=$((failed + 1)) ;;
      BLOCKED) blocked=$((blocked + 1)) ;;
      PASSED)  passed=$((passed + 1)) ;;
      PENDING) blocked=$((blocked + 1)) ;;   # never reached = never established
    esac
  done

  if (( failed > 0 || blocked > 0 )); then
    printf '\nSETUP FAILED at checkpoint: %s\n' "${CHECKPOINT_FAILED_AT:-<not reached>}"
    printf '  %d passed, %d failed, %d blocked or never reached\n' "$passed" "$failed" "$blocked"
    printf '  Run `make dump` for the cluster-wide picture.\n'
    return 1
  fi
  printf '\nAll %d checkpoints PASSED.\n' "$passed"
  return 0
}
