#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# client-load.sh — the continuous external client (FR-066, SC-008).
#
# Issues requests THROUGH THE GATEWAY for a bounded window and reports the
# observed success rate. Used by the drills that must show a client sees no
# sustained loss while something is being broken underneath.
#
# It measures what a client actually experiences, which is deliberately not the
# same as what the cluster reports about itself: a pod can be Ready while the
# endpoint has not propagated, and the cluster will call that healthy while
# requests fail.
#
# Usage:
#   client-load.sh <duration-seconds> [concurrency]
# Prints:
#   total=<n> success=<n> failed=<n> throttled=<n> rate=<percent>
#
# `rate` is AVAILABILITY: the share of requests the service answered at all,
# counting 429 as an answer. `throttled` is reported alongside so a drill can
# see when the limiter was active without that inflating the failure count.
# ---------------------------------------------------------------------------
set -uo pipefail

LAB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
source "${LAB_ROOT}/scripts/lib/versions.sh"

DURATION="${1:-60}"
CONCURRENCY="${2:-4}"
URL="${CLIENT_LOAD_URL:-${LAB_BASE_URL}/api/v1/tenant}"

TMPDIR_RUN="$(mktemp -d "${TMPDIR:-/tmp}/client-load-XXXXXX")"
trap 'rm -rf "${TMPDIR_RUN}"' EXIT

worker() {
  local id="$1" deadline="$2"
  local total=0 success=0
  while [[ "$(date +%s)" -lt "$deadline" ]]; do
    local code
    code="$(curl -s -o /dev/null -w '%{http_code}' --cacert "${LAB_CA_CERT}" \
      --max-time 10 "$URL" 2>/dev/null || echo 000)"
    total=$(( total + 1 ))
    # WHAT COUNTS AS SERVED, and this distinction is the whole measurement.
    #
    # 2xx, 3xx AND 429 all mean the service answered. A 429 is the rate limiter
    # doing its job — a deliberate, correct response — and it is emphatically
    # not the client losing service because a pod was deleted.
    #
    # The first version counted only 2xx/3xx, and the pod-delete drill duly
    # reported a 0.45% success rate against a perfectly healthy cluster: four
    # workers in a tight loop exhausted the per-address limit within seconds, so
    # 13,097 of 13,156 requests were throttled. The drill was measuring the rate
    # limiter, not availability (FR-079).
    #
    # What counts as LOST service: 5xx, and no response at all.
    case "$code" in
      2*|3*) success=$(( success + 1 )) ;;
      429)   success=$(( success + 1 )); printf '429\n' >> "${TMPDIR_RUN}/throttled" ;;
    esac
    # Paced deliberately. An unpaced loop measures how fast curl can start, and
    # saturates a per-address limit that exists precisely to stop that.
    sleep "${CLIENT_LOAD_INTERVAL:-0.25}"   # WAIT_POLL_INTERVAL: request pacing, not a readiness signal
  done
  printf '%d %d\n' "$total" "$success" > "${TMPDIR_RUN}/w${id}"
}

deadline=$(( $(date +%s) + DURATION ))
for i in $(seq 1 "$CONCURRENCY"); do
  worker "$i" "$deadline" &
done
wait

total=0; success=0
for f in "${TMPDIR_RUN}"/w*; do
  [[ -r "$f" ]] || continue
  read -r t s < "$f"
  total=$(( total + t )); success=$(( success + s ))
done
throttled="$(wc -l < "${TMPDIR_RUN}/throttled" 2>/dev/null | tr -d ' ' || echo 0)"

failed=$(( total - success ))
if (( total > 0 )); then
  rate="$(awk -v s="$success" -v t="$total" 'BEGIN { printf "%.2f", (s / t) * 100 }')"
else
  rate="0.00"
fi

printf 'total=%d success=%d failed=%d throttled=%s rate=%s\n' \
  "$total" "$success" "$failed" "${throttled:-0}" "$rate"
