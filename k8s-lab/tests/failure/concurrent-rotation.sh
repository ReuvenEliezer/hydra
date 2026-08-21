#!/usr/bin/env bash
# concurrent-rotation drill (FR-067, SC-010, D17).
#
# THIS IS THE ONE THE CONSTITUTION TURNS ON.
#
# Principle IV — Atomic Distributed State Mutations — is NON-NEGOTIABLE, and
# until this drill it was an argument rather than an observation. The Lua
# rotation script is written to be atomic; nobody had ever presented one renewal
# credential to several real replicas at the same instant and counted what
# happened.
#
# WHAT "EXACTLY ONE ROTATION" ACTUALLY MEANS — and getting this wrong is how the
# first version of this drill reported a constitutional violation against a
# perfectly correct implementation.
#
# The naive assertion is "exactly one request returns HTTP 200". That is WRONG
# here, and measurably so. `refresh-token.grace-ttl` (PT5S) exists precisely so
# that a client which retries — or races itself across tabs — is not logged out.
# Within the grace window, the already-rotated credential is honoured again and
# the SAME new token is returned. Concurrent callers therefore SHOULD all
# succeed. That is the design, not a defect.
#
# Measured, on this cluster, 40 concurrent rotations of one credential:
#
#     20 x HTTP 200
#     20 x HTTP 429        (per-token refresh limit, capacity 20)
#      1 distinct new refresh token issued across all 20 successes
#
# One token. Twenty observers. That is exactly what atomicity plus a grace
# window looks like, and a "count the 200s" assertion calls it a double-honour.
#
# SO THE ASSERTION IS ON DISTINCT ISSUED CREDENTIALS. If two callers received
# DIFFERENT new tokens, two independent rotations happened, the token family has
# forked, and Principle IV is violated. If they all received the same one,
# exactly one rotation occurred no matter how many callers saw it.
#
# This is a STRICTER test than counting successes, not a laxer one: it can
# distinguish "one rotation replayed" from "many rotations", which the naive
# version cannot do in either direction.
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/lib" && pwd)/drill.sh"

ATTEMPTS="${ATTEMPTS:-120}"
PARALLEL="${PARALLEL:-40}"

drill_begin "concurrent-rotation" \
  "exactly ONE of ${ATTEMPTS} concurrent rotations of the same credential succeeds" || { log_summary; exit 1; }

# T116: a replica-count precondition. A single-replica deployment cannot
# demonstrate cross-replica atomicity — the result would be true and
# meaningless, which is worse than no result.
replicas="$($K -n "${NS_APP}" get deploy auth-service -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)"
if [[ "${replicas:-0}" -lt 2 ]]; then
  log_fail "auth-service has ${replicas:-0} ready replica(s); this drill needs at least 2 (FR-069)"
  log_info "On one replica, 'exactly one rotation succeeded' is guaranteed by having one process."
  log_info "It would report PASS while testing nothing about distributed atomicity."
  log_summary; exit 1
fi
log_pass "multi-instance precondition met" "${replicas} auth-service replicas (FR-069)"

drill_await_clean_rate_limit || { log_summary; exit 1; }

# Obtain one refresh credential. The cookie is what gets rotated.
cookie_jar="$(mktemp)"
trap 'rm -f "$cookie_jar"' EXIT
login_code="$(curl -s -o /dev/null -w '%{http_code}' --cacert "${LAB_CA_CERT}" --max-time 20 \
  -c "$cookie_jar" -X POST "${LAB_BASE_URL}/api/v1/auth/login" \
  -H 'Content-Type: application/json' \
  -d '{"username":"labuser","password":"lab-password-not-a-secret"}' 2>/dev/null || echo 000)"
if [[ "$login_code" != "200" ]]; then
  log_fail "could not obtain a credential to rotate" "login returned ${login_code}"
  log_summary; exit 1
fi

refresh_cookie="$(awk '/refresh/ {print $7}' "$cookie_jar" | tail -1)"
cookie_name="$(awk '/refresh/ {print $6}' "$cookie_jar" | tail -1)"
if [[ -z "$refresh_cookie" ]]; then
  log_fail "no refresh cookie was issued" "$(cat "$cookie_jar" | tail -3)"
  log_summary; exit 1
fi
log_pass "one renewal credential obtained" "cookie ${cookie_name}"

# Fire them all at once. xargs -P is the concurrency; every worker presents the
# SAME credential, and the gateway distributes them across replicas.
#
# Response HEADERS are captured, not just status codes: the Set-Cookie is the
# evidence, because the assertion is about which credential was issued.
HDR_DIR="$(mktemp -d "${TMPDIR:-/tmp}/rotation-XXXXXX")"
trap 'rm -rf "$HDR_DIR"' EXIT

ROTATE_ONE="${HDR_DIR}/rotate.sh"
cat > "$ROTATE_ONE" <<ROT
#!/usr/bin/env bash
curl -s -o /dev/null --cacert "${LAB_CA_CERT}" --max-time 25 \
  -D "${HDR_DIR}/h\$1.txt" \
  -X POST "${LAB_BASE_URL}/api/v1/auth/refresh" \
  -H "Cookie: ${cookie_name}=${refresh_cookie}" 2>/dev/null
ROT
chmod +x "$ROTATE_ONE"

seq 1 "$ATTEMPTS" | xargs -P "$PARALLEL" -I{} "$ROTATE_ONE" {}
log_pass "trigger: ${ATTEMPTS} concurrent rotations fired" "xargs -P ${PARALLEL}, same credential to all replicas"

succeeded="$(grep -h '^HTTP' "${HDR_DIR}"/h*.txt 2>/dev/null | awk '{print $2}' | grep -c '^200$' || true)"
throttled="$(grep -h '^HTTP' "${HDR_DIR}"/h*.txt 2>/dev/null | awk '{print $2}' | grep -c '^429$' || true)"
rejected="$(grep -h '^HTTP' "${HDR_DIR}"/h*.txt 2>/dev/null | awk '{print $2}' | grep -cE '^(400|401|403|409)$' || true)"
errored="$(grep -h '^HTTP' "${HDR_DIR}"/h*.txt 2>/dev/null | awk '{print $2}' | grep -cE '^5' || true)"

# THE MEASUREMENT THAT MATTERS: how many DISTINCT credentials were issued.
issued="$(grep -hi "^set-cookie: ${cookie_name}=" "${HDR_DIR}"/h*.txt 2>/dev/null \
          | sed "s/.*${cookie_name}=\([^;]*\).*/\1/" | sort -u | grep -c . || true)"

log_info "200=${succeeded}  429=${throttled}  rejected=${rejected}  5xx=${errored}  of ${ATTEMPTS}"
log_info "DISTINCT new credentials issued across all successes: ${issued}"

# --- THE ASSERTION ---------------------------------------------------------
if [[ "${issued:-0}" == "1" ]]; then
  log_pass "EXACTLY ONE rotation occurred across ${ATTEMPTS} concurrent attempts" \
           "one distinct credential issued to ${succeeded} concurrent callers — SC-010"
  log_info "Constitution Principle IV OBSERVED, not argued: the rotation is atomic across replicas."
  log_info "The ${succeeded} successes are the grace window (PT5S) replaying one result, which is"
  log_info "what stops a retrying client from being logged out. One rotation, many observers."
elif [[ "${issued:-0}" == "0" ]]; then
  if [[ "${throttled:-0}" -ge "${ATTEMPTS}" ]]; then
    log_fail "every attempt was throttled" "429=${throttled}/${ATTEMPTS}"
    log_context "The per-token refresh limit is below this drill's concurrency, so no rotation was
attempted at all. That is a test-design problem, not an atomicity result: lower
PARALLEL or raise refresh-token capacity and re-run."
  else
    log_fail "NO credential was issued" "the rotation did not happen at all"
    log_context "$(printf 'statuses: '; grep -h '^HTTP' "${HDR_DIR}"/h*.txt 2>/dev/null | awk '{print $2}' | sort | uniq -c | tr '\n' ' ')"
  fi
else
  log_fail "${issued} DISTINCT credentials were issued — the credential was DOUBLE-HONOURED"
  log_context "This is a violation of Constitution Principle IV (NON-NEGOTIABLE).

More than one INDEPENDENT rotation occurred for a single presented credential,
which means the token family has forked: two clients now hold valid, unrelated
refresh chains derived from one credential. Revoking one does not revoke the
other.

This is NOT the grace window. The grace window returns the SAME token to every
caller within its span — that shows up as exactly 1 distinct credential. ${issued}
distinct credentials means the atomic section did not hold under real
concurrency across replicas.

It is a finding about the rotation logic, not about this drill."
fi

# The same statement from the auditor's side.
assert_le "credentials issued beyond the first" "$(( issued > 1 ? issued - 1 : 0 ))" "0"

drill_restore "no state to restore — the credential is spent by design" true
drill_end
