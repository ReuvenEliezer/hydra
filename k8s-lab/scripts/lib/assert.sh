#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# assert.sh — the assertion helpers every suite shares.
#
# Each one executes something and records a verdict through log.sh. None of
# them can pass without running a command, which is the structural half of
# FR-098: a suite cannot report a component healthy by asserting it.
#
# Every helper returns 0 on PASS and 1 on FAIL, so callers may branch, but the
# verdict is already recorded either way — a caller cannot swallow a failure by
# ignoring the return value.
# ---------------------------------------------------------------------------
set -uo pipefail

_ASSERT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./log.sh
[[ -n "${LOG_PASS_COUNT:-}" ]] || source "${_ASSERT_LIB_DIR}/log.sh"

# assert_eq <description> <expected> <actual>
assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    log_pass "$desc" "expected=${expected}"
    return 0
  fi
  log_fail "$desc"
  log_context "expected: ${expected}
actual:   ${actual}"
  return 1
}

# assert_ne <description> <not-expected> <actual>
assert_ne() {
  local desc="$1" unexpected="$2" actual="$3"
  if [[ "$unexpected" != "$actual" ]]; then
    log_pass "$desc" "actual=${actual}"
    return 0
  fi
  log_fail "$desc"
  log_context "value must not be: ${unexpected}"
  return 1
}

# assert_contains <description> <haystack> <needle>
assert_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    log_pass "$desc" "contains '${needle}'"
    return 0
  fi
  log_fail "$desc"
  log_context "expected to contain: ${needle}
actual: ${haystack}"
  return 1
}

# assert_not_contains <description> <haystack> <needle>
assert_not_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    log_pass "$desc" "does not contain '${needle}'"
    return 0
  fi
  log_fail "$desc"
  log_context "must not contain: ${needle}
actual: ${haystack}"
  return 1
}

# assert_cmd <description> <command...>
# Runs the command, captures combined output, and reports the command itself as
# the evidence string.
assert_cmd() {
  local desc="$1"; shift
  local out rc
  out="$("$@" 2>&1)"; rc=$?
  if (( rc == 0 )); then
    log_pass "$desc" "$*"
    return 0
  fi
  log_fail "$desc" "$*"
  log_context "exit ${rc}
${out}"
  return 1
}

# assert_exit_nonzero <description> <command...>
# For the cases where success is a failure: the hostile-edge run, the seeded
# diagnostic failures, the denied network paths.
assert_exit_nonzero() {
  local desc="$1"; shift
  local out rc
  out="$("$@" 2>&1)"; rc=$?
  if (( rc != 0 )); then
    log_pass "$desc" "exit ${rc} from: $*"
    return 0
  fi
  log_fail "$desc" "$*"
  log_context "command succeeded but was required to fail
${out}"
  return 1
}

# curl_status <url> [curl args...]
# Prints the HTTP status. Every HTTPS call in the lab goes through the lab CA;
# --insecure is never used anywhere in this tree (FR-032b).
curl_status() {
  local url="$1"; shift
  curl -s -o /dev/null -w '%{http_code}' \
    --cacert "${LAB_CA_CERT:-/nonexistent}" \
    --max-time "${CURL_MAX_TIME:-15}" \
    "$@" "$url" 2>/dev/null || echo "000"
}

# curl_headers <url> [curl args...] — response headers only, lower-cased names.
curl_headers() {
  local url="$1"; shift
  curl -s -D - -o /dev/null \
    --cacert "${LAB_CA_CERT:-/nonexistent}" \
    --max-time "${CURL_MAX_TIME:-15}" \
    "$@" "$url" 2>/dev/null | tr 'A-Z' 'a-z'
}

# curl_body <url> [curl args...]
curl_body() {
  local url="$1"; shift
  curl -s \
    --cacert "${LAB_CA_CERT:-/nonexistent}" \
    --max-time "${CURL_MAX_TIME:-15}" \
    "$@" "$url" 2>/dev/null
}

# assert_http_status <description> <expected-status> <url> [curl args...]
assert_http_status() {
  local desc="$1" expected="$2" url="$3"; shift 3
  local actual
  actual="$(curl_status "$url" "$@")"
  if [[ "$actual" == "$expected" ]]; then
    log_pass "$desc" "HTTP ${actual} from ${url}"
    return 0
  fi
  log_fail "$desc" "GET ${url}"
  log_context "expected HTTP ${expected}, got ${actual}"
  return 1
}

# assert_header_absent <description> <url> <header-name> [curl args...]
# The gateway-CORS check (FR-037) and the double-header check both need this.
assert_header_absent() {
  local desc="$1" url="$2" header="$3"; shift 3
  local headers count
  headers="$(curl_headers "$url" "$@")"
  count="$(printf '%s\n' "$headers" | grep -c "^$(printf '%s' "$header" | tr 'A-Z' 'a-z'):" || true)"
  if [[ "$count" == "0" ]]; then
    log_pass "$desc" "${header} absent from ${url}"
    return 0
  fi
  log_fail "$desc" "${header} present ${count}x on ${url}"
  log_context "$(printf '%s\n' "$headers" | grep "^$(printf '%s' "$header" | tr 'A-Z' 'a-z'):" || true)"
  return 1
}

# assert_header_count <description> <url> <header-name> <expected-count> [curl args...]
# Clause 2 of the transparent edge contract is a *count* assertion, not a
# presence one: two Access-Control-Allow-Origin headers is the failure, and one
# is the pass.
assert_header_count() {
  local desc="$1" url="$2" header="$3" expected="$4"; shift 4
  local headers count
  headers="$(curl_headers "$url" "$@")"
  count="$(printf '%s\n' "$headers" | grep -c "^$(printf '%s' "$header" | tr 'A-Z' 'a-z'):" || true)"
  if [[ "$count" == "$expected" ]]; then
    log_pass "$desc" "${header} x${count}"
    return 0
  fi
  log_fail "$desc" "${header} x${count}, expected x${expected}"
  log_context "$headers"
  return 1
}

# assert_json_field <description> <json> <jq-filter> <expected>
assert_json_field() {
  local desc="$1" json="$2" filter="$3" expected="$4"
  local actual
  actual="$(printf '%s' "$json" | jq -r "$filter" 2>/dev/null || echo '<unparseable>')"
  assert_eq "$desc" "$expected" "$actual"
}

# assert_ge <description> <actual> <minimum>
assert_ge() {
  local desc="$1" actual="$2" minimum="$3"
  # Integer or decimal; awk keeps this honest for percentages like 99.4.
  if awk -v a="$actual" -v m="$minimum" 'BEGIN { exit !(a + 0 >= m + 0) }'; then
    log_pass "$desc" "${actual} >= ${minimum}"
    return 0
  fi
  log_fail "$desc"
  log_context "observed ${actual}, required at least ${minimum}"
  return 1
}

# assert_le <description> <actual> <maximum>
assert_le() {
  local desc="$1" actual="$2" maximum="$3"
  if awk -v a="$actual" -v m="$maximum" 'BEGIN { exit !(a + 0 <= m + 0) }'; then
    log_pass "$desc" "${actual} <= ${maximum}"
    return 0
  fi
  log_fail "$desc"
  log_context "observed ${actual}, permitted at most ${maximum}"
  return 1
}

# ready_replicas <namespace> <kind/name> — Ready replica count, with ABSENT
# normalised to 0.
#
# Kubernetes marks `.status.readyReplicas` `omitempty`, so a workload scaled to
# ZERO does not report `0` — it reports NOTHING, and a jsonpath query returns an
# empty string while kubectl exits successfully.
#
# That makes the common idiom
#     "$($K ... -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)"
# wrong in exactly the case that matters: the `|| echo 0` fires only when
# kubectl FAILS, and kubectl succeeds. The caller compares "" against "0" and
# never sees the scale-down it is waiting for.
#
# Measured: the cache-down drill scaled Redis to zero, the StatefulSet reported
# no readyReplicas at all, and "redis is gone" timed out after 120s against a
# Redis that had been gone for 118 of them. The drill then went on to observe
# the correct fail-closed 429 — so it reported the right behaviour and a failed
# assertion at the same time.
ready_replicas() {
  local ns="$1" target="$2" value
  value="$(kubectl --context "${LAB_KUBECONTEXT}" -n "$ns" get "$target" \
             -o jsonpath='{.status.readyReplicas}' 2>/dev/null)" || value=""
  printf '%s' "${value:-0}"
}
# Exported because the wait_for conditions that need it run in `bash -c`
# subshells, which inherit exported functions but not shell-local ones.
export -f ready_replicas
