#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# wait.sh — condition-based waiting, and nothing else (FR-015).
#
# This file deliberately exposes no sleep-based helper. There is no
# `wait_seconds`, no `settle`, no `pause`. A fixed duration is never a readiness
# signal: it is a guess that passes on a fast machine and fails on a slow one,
# and the failure it produces points at the wrong component.
#
# `sleep` does appear below — inside the polling loops, as the interval between
# two evaluations of a condition. That is the only legitimate use of it in this
# tree, and `verify-versions.sh` checks that no other script calls sleep
# outside a polling construct.
#
# Every wait here:
#   - evaluates an actual condition,
#   - has a mandatory bounded timeout with no default that hides one,
#   - prints diagnostic context when the budget expires, so the timeout names a
#     component instead of only a duration.
# ---------------------------------------------------------------------------
set -uo pipefail

_WAIT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./log.sh
[[ -n "${LOG_PASS_COUNT:-}" ]] || source "${_WAIT_LIB_DIR}/log.sh"

WAIT_POLL_INTERVAL="${WAIT_POLL_INTERVAL:-3}"

# wait_for <description> <timeout-seconds> <command...>
#
# Polls the command until it exits zero or the budget expires. The timeout is
# positional and required — there is no default, because a default is how a
# bounded wait quietly becomes an unbounded one.
wait_for() {
  local desc="$1" timeout="$2"; shift 2
  [[ -n "$timeout" && "$timeout" =~ ^[0-9]+$ ]] || {
    log_error "wait_for('${desc}') called without a numeric timeout — FR-015 forbids an unbounded wait"
    return 2
  }

  local deadline=$(( SECONDS + timeout ))
  local attempts=0
  local last_output=""

  while (( SECONDS < deadline )); do
    attempts=$(( attempts + 1 ))
    if last_output="$("$@" 2>&1)"; then
      log_info "${desc}: satisfied after ${attempts} evaluation(s), $(( timeout - (deadline - SECONDS) ))s"
      return 0
    fi
    sleep "${WAIT_POLL_INTERVAL}"   # polling interval, not a readiness signal
  done

  log_fail "${desc}: condition not met within ${timeout}s"
  log_context "evaluated ${attempts} time(s)
command: $*
last output:
${last_output}"
  _wait_diagnostic_context
  return 1
}

# wait_for_output <description> <timeout> <expected> <command...>
# Same contract, but the condition is the command's stdout matching a value —
# for the many kubectl -o jsonpath conditions that succeed as a command while
# reporting the wrong state.
wait_for_output() {
  local desc="$1" timeout="$2" expected="$3"; shift 3
  [[ "$timeout" =~ ^[0-9]+$ ]] || {
    log_error "wait_for_output('${desc}') called without a numeric timeout (FR-015)"
    return 2
  }

  local deadline=$(( SECONDS + timeout ))
  local attempts=0 actual=""

  while (( SECONDS < deadline )); do
    attempts=$(( attempts + 1 ))
    actual="$("$@" 2>/dev/null || true)"
    if [[ "$actual" == "$expected" ]]; then
      log_info "${desc}: '${expected}' observed after ${attempts} evaluation(s)"
      return 0
    fi
    sleep "${WAIT_POLL_INTERVAL}"
  done

  log_fail "${desc}: expected '${expected}', last saw '${actual}' after ${timeout}s"
  log_context "command: $*"
  _wait_diagnostic_context
  return 1
}

# wait_for_http <description> <timeout> <expected-status> <url> [curl args...]
# The only readiness check that proves an endpoint actually serves. A Ready pod
# is not the same claim as a responding endpoint, and several checkpoints need
# the second one.
wait_for_http() {
  local desc="$1" timeout="$2" expected="$3" url="$4"; shift 4
  local deadline=$(( SECONDS + timeout ))
  local actual="000" attempts=0

  while (( SECONDS < deadline )); do
    attempts=$(( attempts + 1 ))
    actual="$(curl -s -o /dev/null -w '%{http_code}' \
      --cacert "${LAB_CA_CERT:-/nonexistent}" --max-time 10 "$@" "$url" 2>/dev/null || echo 000)"
    [[ "$actual" == "$expected" ]] && {
      log_info "${desc}: HTTP ${expected} after ${attempts} attempt(s)"
      return 0
    }
    sleep "${WAIT_POLL_INTERVAL}"
  done

  log_fail "${desc}: ${url} returned ${actual}, expected ${expected}, within ${timeout}s"
  _wait_diagnostic_context
  return 1
}

# wait_for_rollout <namespace> <kind/name> <timeout>
# kubectl rollout status is already condition-based and already bounded, so it
# is used directly rather than re-implemented — but the timeout is still passed
# explicitly, never left to kubectl's own default.
wait_for_rollout() {
  local ns="$1" target="$2" timeout="$3"
  if kubectl -n "$ns" rollout status "$target" --timeout="${timeout}s" >/dev/null 2>&1; then
    log_info "${target} in ${ns}: rollout complete"
    return 0
  fi
  log_fail "${target} in ${ns}: rollout did not complete within ${timeout}s"
  log_context "$(kubectl -n "$ns" get pods -o wide 2>&1 | head -20)"
  log_context "$(kubectl -n "$ns" get events --sort-by=.lastTimestamp 2>&1 | tail -15)"
  return 1
}

# wait_for_job <namespace> <job-name> <timeout>
# A Job that fails must fail the wait immediately rather than burning the whole
# budget: a Failed condition is a terminal answer, and treating it as "not yet"
# turns a 10-second failure into a 10-minute one.
wait_for_job() {
  local ns="$1" job="$2" timeout="$3"
  local deadline=$(( SECONDS + timeout ))

  while (( SECONDS < deadline )); do
    local complete failed
    complete="$(kubectl -n "$ns" get job "$job" \
      -o jsonpath='{.status.conditions[?(@.type=="Complete")].status}' 2>/dev/null || true)"
    failed="$(kubectl -n "$ns" get job "$job" \
      -o jsonpath='{.status.conditions[?(@.type=="Failed")].status}' 2>/dev/null || true)"

    if [[ "$complete" == "True" ]]; then
      log_info "job/${job} in ${ns}: Complete"
      return 0
    fi
    if [[ "$failed" == "True" ]]; then
      log_fail "job/${job} in ${ns}: Failed"
      log_context "$(kubectl -n "$ns" logs "job/${job}" --tail=60 2>&1 || true)"
      return 1
    fi
    sleep "${WAIT_POLL_INTERVAL}"
  done

  log_fail "job/${job} in ${ns}: neither Complete nor Failed within ${timeout}s"
  log_context "$(kubectl -n "$ns" describe job "$job" 2>&1 | tail -30 || true)"
  return 1
}

# Printed whenever a budget expires: enough to name a component without a
# second command, which is the same obligation `make dump` carries at cluster
# scale (FR-090, SC-018).
_wait_diagnostic_context() {
  command -v kubectl >/dev/null 2>&1 || return 0
  kubectl cluster-info >/dev/null 2>&1 || {
    log_context "cluster API is not reachable — the timeout is downstream of that"
    return 0
  }
  log_context "not-Running pods, cluster-wide:
$(kubectl get pods -A --field-selector=status.phase!=Running 2>&1 | head -20)"
  log_context "recent events:
$(kubectl get events -A --sort-by=.lastTimestamp 2>&1 | tail -15)"
}
