#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# reproducibility.sh — T156 / SC-003 / FR-108.
#
# SC-003 asks for `make validate-full` executed THREE CONSECUTIVE TIMES WITH NO
# MANUAL INTERVENTION BETWEEN PASSES.
#
# The "no manual intervention" clause is the whole criterion, and it is the part
# that is easy to lose. Three rebuilds run by hand, one after another, are three
# rebuilds — they are not this. A human between passes silently supplies things
# the sequence is supposed to supply for itself: noticing a container that did
# not die, retrying a flaky pull, waiting a little longer before the next run,
# clearing something that "obviously" needed clearing. Every one of those is a
# dependency on a person, and SC-003 exists to find them.
#
# So this script starts the passes and does not touch them. Between pass N and
# pass N+1 there is exactly one thing: the loop counter. No cleanup (each
# validate-full performs its own destroy), no settling pause, no conditional
# recovery, no human.
#
# WHAT IT RECORDS, per pass, to results/reproducibility/:
#   - the complete log
#   - exit status
#   - wall-clock duration
#   - the checkpoint table and the validate verdict table, extracted
# and one summary across all passes.
#
# EXIT STATUS: zero only if EVERY pass succeeded. A run in which pass 2 fails
# and pass 3 succeeds is not a pass — reproducibility is a property of the
# sequence, not the best result in it.
# ---------------------------------------------------------------------------
set -uo pipefail

LAB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${LAB_ROOT}/scripts/lib/versions.sh"
source "${LAB_ROOT}/scripts/lib/log.sh"

PASSES="${LAB_REPRO_PASSES:-3}"
[[ "${1:-}" =~ ^[0-9]+$ ]] && PASSES="$1"

RUN_ID="$(date +%Y%m%dT%H%M%S)"
OUT="${LAB_RESULTS_DIR}/reproducibility/${RUN_ID}"
mkdir -p "$OUT"

log_suite "reproducibility: ${PASSES} consecutive validate-full passes (SC-003)"

printf 'No manual intervention occurs between passes. Each pass destroys and rebuilds\n'
printf 'the entire environment from nothing, then validates it.\n\n'
printf 'Recording to: %s\n\n' "$OUT"

# The environment this ran on, captured once. A reproducibility result that does
# not say what it was reproducible ON is not worth much later.
{
  printf 'run-id:      %s\n' "$RUN_ID"
  printf 'passes:      %s\n' "$PASSES"
  printf 'started:     %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'host:        %s %s\n' "$(uname -s)" "$(uname -m)"
  printf 'docker:      %s\n' "$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo unknown)"
  printf 'kind:        %s\n' "$(kind version 2>/dev/null | head -1 || echo unknown)"
  printf 'kubernetes:  %s\n' "${KUBERNETES_VERSION:-unknown}"
} > "${OUT}/environment.txt"
cat "${OUT}/environment.txt"
printf '\n'

PASS_RC=()
PASS_SECONDS=()

for (( n = 1; n <= PASSES; n++ )); do
  printf '\n'
  printf '════════════════════════════════════════════════════════════\n'
  printf '  pass %d of %d — make validate-full\n' "$n" "$PASSES"
  printf '  started %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '════════════════════════════════════════════════════════════\n'

  pass_log="${OUT}/pass-${n}.log"
  started=$(date +%s)

  # THE PASS. Nothing surrounds it: no pre-clean, no retry, no recovery.
  # validate-full destroys and rebuilds on its own, which is exactly the
  # property under test.
  "${LAB_ROOT}/scripts/validate.sh" --full > "$pass_log" 2>&1
  rc=$?

  elapsed=$(( $(date +%s) - started ))
  PASS_RC+=("$rc")
  PASS_SECONDS+=("$elapsed")

  # Extract the two tables that carry the substance, so a reader does not have
  # to open a multi-megabyte log to see what happened.
  grep -E '^(cluster|namespaces|gateway-api|cilium|registry|images|certs|gateway|backing-services|observability|argocd|console|migrate|fixture|apps)[[:space:]]+(PASSED|FAILED)' \
    "$pass_log" > "${OUT}/pass-${n}.checkpoints.txt" 2>/dev/null || true
  sed -n '/^COMPONENT /,/^OVERALL/p' "$pass_log" > "${OUT}/pass-${n}.verdict.txt" 2>/dev/null || true

  {
    printf 'pass:     %d\n' "$n"
    printf 'exit:     %d\n' "$rc"
    printf 'seconds:  %d\n' "$elapsed"
    printf 'finished: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } > "${OUT}/pass-${n}.summary.txt"

  if (( rc == 0 )); then
    log_pass "pass ${n}: validate-full returned zero" "$(printf '%dm %ds' $(( elapsed / 60 )) $(( elapsed % 60 )))"
  else
    log_fail "pass ${n}: validate-full returned ${rc}" "$(printf '%dm %ds' $(( elapsed / 60 )) $(( elapsed % 60 )))"
    # Recorded and the loop CONTINUES. Stopping here would hide whether the
    # failure is reproducible or a one-off, which is the single most useful
    # thing this run can establish about it.
    log_context "$(tail -30 "$pass_log")"
    log_info "Continuing to the next pass anyway: whether this recurs is the finding."
  fi
done

# ---------------------------------------------------------------------------
# The summary
# ---------------------------------------------------------------------------
printf '\n'
printf '%-8s %-10s %-12s %s\n' "PASS" "EXIT" "DURATION" "VERDICT"
printf '%-8s %-10s %-12s %s\n' "-------" "---------" "-----------" "-------"

failures=0
total=0
for i in "${!PASS_RC[@]}"; do
  rc="${PASS_RC[$i]}"; secs="${PASS_SECONDS[$i]}"
  total=$(( total + secs ))
  (( rc == 0 )) || failures=$(( failures + 1 ))
  printf '%-8s %-10s %-12s %s\n' \
    "$(( i + 1 ))" "$rc" "$(printf '%dm %02ds' $(( secs / 60 )) $(( secs % 60 )))" \
    "$( (( rc == 0 )) && echo PASS || echo FAIL )"
done

{
  printf 'passes:   %d\n' "$PASSES"
  printf 'failures: %d\n' "$failures"
  printf 'total:    %dm %02ds\n' $(( total / 60 )) $(( total % 60 ))
  for i in "${!PASS_RC[@]}"; do
    printf 'pass-%d:   exit=%s seconds=%s\n' "$(( i + 1 ))" "${PASS_RC[$i]}" "${PASS_SECONDS[$i]}"
  done
} > "${OUT}/summary.txt"

printf '\ntotal wall-clock: %dm %02ds across %d passes\n' \
  $(( total / 60 )) $(( total % 60 )) "$PASSES"
printf 'recorded in: %s\n\n' "$OUT"

if (( failures > 0 )); then
  printf 'SC-003: FAIL — %d of %d consecutive passes did not succeed.\n' "$failures" "$PASSES"
  printf 'Reproducibility is a property of the SEQUENCE. One good pass among several\n'
  printf 'does not establish it, and this run does not claim it.\n'
  log_summary
  exit 1
fi

printf 'SC-003: PASS — %d consecutive validate-full passes, no manual intervention.\n' "$PASSES"
log_summary
