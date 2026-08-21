#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# ratelimit.sh — establish a KNOWN login-limiter state before a suite that
# signs in more than once (SC-004, and the `make validate` interaction below).
#
# WHY THIS EXISTS, precisely.
#
# `make validate` reported `integration-suite` FAIL while the same suite passed
# 21/21 standalone moments later. The recorded diagnosis was "the smoke suite
# exhausts the login limit and the precondition's 180s budget is too narrow".
# Measuring it showed that diagnosis is wrong on both halves, and the fix it
# implied — a wider budget — would not have worked.
#
# What is actually true, measured against the running cluster:
#
#   1. The smoke suite makes exactly ONE login. It cannot exhaust a capacity-5
#      bucket on its own.
#
#   2. auth-service limits login on TWO INDEPENDENT DIMENSIONS:
#         login-ip        capacity 5 / PT1M   keyed by address
#         login-username  capacity 5 / PT1M   keyed by username
#      Both are Bucket4j `refillIntervally` buckets, so the whole capacity
#      returns as a LUMP at a boundary rather than gradually.
#
#   3. The two buckets are keyed differently, are created at different moments,
#      and therefore refill on INDEPENDENTLY PHASED boundaries. Measured
#      directly: draining `labuser` to 429 left the ip bucket with two tokens
#      still available to a different username from the same address.
#
#   4. Therefore usable headroom = min(ip_remaining, username_remaining), and
#      NO single probe can measure it. Waiting out a 429's `Retry-After` reached
#      only 3 usable logins, not 5, because it synchronised with one boundary
#      and not the other.
#
# The old precondition polled until ONE login returned 200 and then declared
# the window clear. One token is not a clear window: the suite goes on to spend
# three more logins (acme sign-in, beta sign-in, wrong-password), so it could
# and did pass its precondition and then fail two assertions later. Widening
# 180s to any larger number changes nothing — the precondition was already
# passing. It was measuring the wrong thing, not measuring it for too short.
#
# THE APPROACH HERE: drive every dimension to a state that is KNOWN rather than
# inferred — empty — and then wait for the limiter's own refill to be OBSERVED.
#
#   - Draining is deliberate. The limiter publishes no remaining-token count,
#     so "empty" is the only state a client can establish with certainty.
#   - A 429 consumes nothing, so draining costs only the tokens that were there.
#   - The FIRST 200 after a total drain is proof that BOTH dimensions have
#     refilled, because a login needs a token from each. That is a condition,
#     observed — not a duration, guessed (FR-015).
#
# It leaves capacity-1 tokens on every dimension. The integration suite spends
# three of them, so the margin is real and stated rather than hoped for.
# ---------------------------------------------------------------------------
set -uo pipefail

_RATELIMIT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./log.sh
[[ -n "${LOG_PASS_COUNT:-}" ]] || source "${_RATELIMIT_LIB_DIR}/log.sh"
# shellcheck source=./wait.sh
[[ -n "${WAIT_POLL_INTERVAL:-}" ]] || source "${_RATELIMIT_LIB_DIR}/wait.sh"

# _login_status <host> <username> <password> — HTTP status of one sign-in.
_login_status() {
  curl -s -o /dev/null -w '%{http_code}' \
    --cacert "${LAB_CA_CERT:-/nonexistent}" \
    --max-time "${CURL_MAX_TIME:-15}" \
    -X POST "https://$1/api/v1/auth/login" \
    -H 'Content-Type: application/json' \
    -d "{\"username\":\"$2\",\"password\":\"$3\"}" 2>/dev/null || echo "000"
}

# require_clean_login_window <host> <username> <password>
#
# On return 0: every login dimension this suite consumes sits at capacity-1.
# On return 1: it could not be established, and the reason is printed.
require_clean_login_window() {
  local host="$1" user="$2" pass="$3"
  local window="${RATE_LIMIT_LOGIN_WINDOW_SECONDS:?versions.env must define it}"
  local capacity="${RATE_LIMIT_LOGIN_CAPACITY:?versions.env must define it}"
  local margin="${RATE_LIMIT_QUIET_MARGIN_SECONDS:-5}"

  # --- 1. Drain the USERNAME dimension to a known-empty state --------------
  # Bounded by capacity: a bucket cannot hand out more than it holds, so a loop
  # that has not seen 429 within capacity+1 attempts is reporting that the
  # limiter is not enforcing at all, which is itself a failure worth naming.
  local i code drained=0
  for (( i = 0; i <= capacity + 1; i++ )); do
    code="$(_login_status "$host" "$user" "$pass")"
    if [[ "$code" == "429" ]]; then drained=1; break; fi
    if [[ "$code" == "000" ]]; then
      log_fail "the gateway did not answer a sign-in while establishing a clean limiter window"
      log_context "https://${host}/api/v1/auth/login returned no response"
      return 1
    fi
  done
  if (( ! drained )); then
    log_fail "login was never throttled after $(( capacity + 2 )) attempts" \
             "capacity is ${capacity}/${window}s — the limiter is not enforcing"
    log_context "This is not a flaky precondition. A limiter that never throttles
means SC-011 and the cross-replica result cannot mean what they claim."
    return 1
  fi

  # --- 2. Drain the ADDRESS dimension too ----------------------------------
  # The username bucket is empty; the ip bucket may not be. A UNIQUE throwaway
  # username isolates it: each fresh username brings its own full username
  # bucket, so the only shared thing left to exhaust is the address. Those
  # throwaway buckets expire on their own (ExpirationAfterWriteStrategy, 10m).
  drained=0
  for (( i = 0; i <= capacity + 1; i++ )); do
    code="$(_login_status "$host" "quiet-probe-$$-${i}" "$pass")"
    if [[ "$code" == "429" ]]; then drained=1; break; fi
  done
  if (( ! drained )); then
    log_fail "the per-address login limit did not engage" \
             "distinct usernames from one address were never throttled"
    log_context "login-ip is the dimension SC-011 depends on. If it does not
engage, a per-replica limiter would be indistinguishable from a shared one."
    return 1
  fi

  # --- 3. Wait for the refill to be OBSERVED, not assumed -------------------
  # A sign-in needs a token from EVERY dimension, so the first 200 after a total
  # drain proves every one of them has crossed its own boundary. The budget is
  # derived from the limiter's declared window, not guessed: two windows covers
  # the worst case where the two boundaries sit a full window apart.
  local budget=$(( window * 2 + margin ))
  if ! wait_for "every login limiter dimension has refilled" "$budget" \
       bash -c "[[ \"\$(curl -s -o /dev/null -w '%{http_code}' \
         --cacert '${LAB_CA_CERT}' --max-time ${CURL_MAX_TIME:-15} \
         -X POST 'https://${host}/api/v1/auth/login' \
         -H 'Content-Type: application/json' \
         -d '{\"username\":\"${user}\",\"password\":\"${pass}\"}' 2>/dev/null)\" == \"200\" ]]"; then
    log_fail "the login limiter did not refill within ${budget}s" \
             "declared window is ${window}s per dimension"
    log_info "That is the limiter failing to refill, not a flaky test. Check
that Redis is reachable from auth-service — a limiter that cannot read its
backing store fails closed by design (rate-limit.fail-open=false)."
    return 1
  fi

  log_pass "every login limiter dimension is at full capacity" \
           "drained ${capacity}/${window}s on address AND username, then observed the refill — $(( capacity - 1 )) sign-ins available"
  return 0
}
