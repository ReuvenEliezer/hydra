#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# edge-conformance.sh — Hydra's EXISTING suite against the lab gateway
# (FR-035, FR-042, FR-096, FR-032b, SC-005, SC-020).
#
# THIS SCRIPT WRITES NO TESTS. The transparent edge contract already has an
# executable suite, and this points it at a real gateway — which is the first
# time that contract has met anything other than a stand-in proxy.
#
# The entire integration is a Maven command line:
#
#   mvn -pl integration-tests test -Dgroups=edge-conformance \
#       -Dedge.base-url=https://acme.localhost \
#       -Djavax.net.ssl.trustStore=... -Djavax.net.ssl.trustStorePassword=... \
#       -Djavax.net.ssl.trustStoreType=PKCS12
#
# Three facts make that sufficient, all confirmed against source:
#
#   1. TransparentEdgeConformanceTest already reads `-Dedge.base-url` and skips
#      its nginx stand-in when the property is set. Designed in during 002.
#   2. EdgeConformanceAssertions builds every client with
#      HttpClients.createDefault(), which resolves the JVM's default
#      SSLContext — so the lab's CA reaches the suite through standard JVM
#      system properties, with no code change (research.md A7).
#   3. The suite's tenant constants are `acme.localhost` and `beta.localhost`,
#      exactly the hostnames the lab serves. Nothing needs overriding.
#
# TWO PROHIBITIONS, enforced below rather than trusted:
#   - certificate verification is NEVER disabled. A harness that skips
#     verification cannot test the `Secure` credential clause it exists to test.
#   - no plain-HTTP run may substitute for the TLS run. FR-032 is blocking with
#     no fallback.
#
# And SC-020 is checked, not assumed: `git diff --exit-code integration-tests/`
# proves no assertion was bent to accommodate the lab.
# ---------------------------------------------------------------------------
set -uo pipefail

LAB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "${LAB_ROOT}/.." && pwd)"
source "${LAB_ROOT}/scripts/lib/versions.sh"
source "${LAB_ROOT}/scripts/lib/log.sh"
source "${LAB_ROOT}/scripts/lib/wait.sh"
source "${LAB_ROOT}/scripts/lib/maven.sh"

K="kubectl --context ${LAB_KUBECONTEXT}"

# --available: can this host run the suite at all? Used by test.sh and
# validate.sh so a missing JVM is reported as BLOCKED rather than silently
# omitted or falsely passed.
if [[ "${1:-}" == "--available" ]]; then
  MVN="$(lab_resolve_mvn)" || exit 1
  [[ -r "$LAB_TRUSTSTORE" && -r "$LAB_TRUSTSTORE_PASSWORD_FILE" ]] || exit 1
  exit 0
fi

TARGET="${1:-lab}"

# Set by the hostile drill's EXIT trap when the revert could not be verified.
# Read by the final exit below so a failed restore cannot exit zero.
HOSTILE_RESTORE_FAILED=0

# ---------------------------------------------------------------------------
# The guards (T079). Checked before anything runs, because a conformance pass
# obtained with verification disabled is worse than no run at all: it looks
# like evidence.
# ---------------------------------------------------------------------------
guard() {
  local base_url="$1"

  if [[ "$base_url" != https://* ]]; then
    log_fail "refusing to run: base URL is not HTTPS" "$base_url"
    log_info "FR-032 makes TLS blocking with no plain-HTTP fallback. A conformance pass over"
    log_info "HTTP does not satisfy SC-005 — Clause 4 tests the credential's Secure attribute,"
    log_info "which is meaningless on an unencrypted transport."
    return 1
  fi

  if [[ ! -r "$LAB_TRUSTSTORE" ]]; then
    log_fail "no truststore at ${LAB_TRUSTSTORE}" "FR-032b"
    log_info "Run 'make setup' — the certs checkpoint produces it. There is no --insecure path."
    return 1
  fi
  if [[ ! -r "$LAB_TRUSTSTORE_PASSWORD_FILE" ]]; then
    log_fail "no truststore password file" "${LAB_TRUSTSTORE_PASSWORD_FILE}"
    return 1
  fi

  # The strongest available check that nobody has quietly added a bypass: this
  # script must contain no verification-disabling flag at all.
  # Strings are stripped before grepping. Without that, an explanatory message
  # that mentions `--insecure` — telling a reader there is no such path — reads
  # as the script offering one, and the guard fails on the exact behaviour it
  # exists to enforce. (The doctor's install-nothing guard had the same bug for
  # the same reason: `remedy "brew install helm"` is instruction, not action.)
  local bypass
  bypass="$(sed -e "s/'[^']*'/''/g" -e 's/"[^"]*"/""/g' "${BASH_SOURCE[0]}" \
            | grep -nE '(^|[^-[:alnum:]])(insecure|trustAll|NoopHostnameVerifier|--?k)([^[:alnum:]]|$)' \
            | grep -vE '^[0-9]+:[[:space:]]*#' || true)"
  if [[ -n "$bypass" ]]; then
    log_fail "this script contains a verification bypass"
    log_context "$bypass"
    return 1
  fi
  log_pass "certificate verification is enabled and cannot be disabled here" "FR-032b"
  return 0
}

# ---------------------------------------------------------------------------
# SC-020 (T081): zero assertion changes.
# ---------------------------------------------------------------------------
assert_suite_unmodified() {
  if ! git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    log_fail "not a git repository — cannot prove the suite is unmodified"
    return 1
  fi
  if git -C "$REPO_ROOT" diff --exit-code --quiet -- integration-tests/ 2>/dev/null \
     && git -C "$REPO_ROOT" diff --cached --exit-code --quiet -- integration-tests/ 2>/dev/null; then
    log_pass "integration-tests/ is unmodified" "git diff --exit-code (SC-020, FR-102)"
    return 0
  fi
  log_fail "integration-tests/ has been modified"
  log_context "$(git -C "$REPO_ROOT" diff --stat -- integration-tests/ 2>&1)"
  log_info "If a clause cannot be satisfied by the lab gateway, that is a FINDING about the"
  log_info "gateway — not a reason to amend the contract. Revert and report it instead."
  return 1
}

# ---------------------------------------------------------------------------
# The run itself.
# ---------------------------------------------------------------------------
run_suite() {
  local base_url="$1" label="$2" outdir="$3"
  local mvn password

  mvn="$(lab_resolve_mvn)" || {
    log_fail "no Maven found" "not on PATH and no distribution under ~/.m2/wrapper/dists"
    return 2
  }
  password="$(cat "$LAB_TRUSTSTORE_PASSWORD_FILE")"

  mkdir -p "$outdir"

  log_info "maven:      ${mvn} ($(lab_mvn_source))"
  log_info "base url:   ${base_url}"
  log_info "truststore: ${LAB_TRUSTSTORE} (PKCS#12, verification ENABLED)"
  log_info "target:     ${label}"

  # -Dgroups selects the tagged suite. Everything else is standard JVM trust
  # configuration — no test code is touched, which is the entire point.
  # errexit is saved and RESTORED, not assumed. This previously ended with a
  # bare `set -e`, which switches errexit ON in a script whose top line is
  # `set -uo pipefail` — it was never on. The leak was silent and destructive:
  # back in cmd_hostile the very next command is a `grep` that legitimately
  # matches nothing, and the whole drill exited there — no clause check, no
  # summary, every executed check reported PASS and an exit status of failure
  # with nothing saying why.
  local had_errexit=0
  [[ $- == *e* ]] && had_errexit=1
  set +e
  ( cd "$REPO_ROOT" && "$mvn" -B -pl integration-tests test \
      -Dgroups=edge-conformance \
      -Dedge.base-url="${base_url}" \
      -Djavax.net.ssl.trustStore="${LAB_TRUSTSTORE}" \
      -Djavax.net.ssl.trustStorePassword="${password}" \
      -Djavax.net.ssl.trustStoreType=PKCS12 ) > "${outdir}/maven.log" 2>&1
  local rc=$?
  (( had_errexit )) && set -e

  # Surefire XML is the Edge Conformance Result entity's substance (data-model §9).
  if [[ -d "${REPO_ROOT}/integration-tests/target/surefire-reports" ]]; then
    cp -R "${REPO_ROOT}/integration-tests/target/surefire-reports" "${outdir}/" 2>/dev/null || true
  fi

  printf '%s\n' "--- clause results (${label}) ---"
  grep -E '^\[(INFO|ERROR)\] (Tests run|.*Clause|.*edge)' "${outdir}/maven.log" 2>/dev/null | tail -25 \
    || tail -25 "${outdir}/maven.log"

  return $rc
}


# clauses_that_failed <outdir> — every conformance clause that FAILED, named as
# the suite itself names it.
#
# Surefire XML gives the failing METHOD; the clause wording is the @DisplayName
# on that method in the suite source. Reading both means this lab never carries
# its own copy of the method->clause mapping, so the mapping cannot drift out of
# step with a suite this feature is forbidden to modify (SC-020).
clauses_that_failed() {
  local outdir="$1"
  local src="${REPO_ROOT}/integration-tests/src/test/java/com/reuven/integration/edge/TransparentEdgeConformanceTest.java"
  local method
  for method in $(python3 - "$outdir" <<'PYEOF' 2>/dev/null
import glob, sys, xml.etree.ElementTree as ET
for f in glob.glob(sys.argv[1] + "/surefire-reports/TEST-*.xml"):
    try:
        root = ET.parse(f).getroot()
    except Exception:
        continue
    for tc in root.iter("testcase"):
        if tc.find("failure") is not None or tc.find("error") is not None:
            print(tc.get("name"))
PYEOF
  ); do
    # The @DisplayName sits on the line(s) above `void <method>(`.
    local label
    label="$(grep -B 3 "void ${method}(" "$src" 2>/dev/null \
             | grep -oE '@DisplayName\("[^"]*"\)' | tail -1 \
             | sed -e 's/@DisplayName("//' -e 's/")$//')"
    printf '%s\n' "${label:-${method}}"
  done | sort -u
}

# ---------------------------------------------------------------------------
# lab — all clauses must pass
# ---------------------------------------------------------------------------
cmd_lab() {
  log_suite "edge conformance: LAB GATEWAY"

  guard "${LAB_BASE_URL}" || { log_summary; return 1; }
  assert_suite_unmodified || { log_summary; return 1; }

  # The gateway must actually be serving before the suite starts, or a
  # connection failure is reported as a contract violation.
  if ! wait_for_http "the lab gateway is serving" "${TIMEOUT_HTTP_RESPONSIVE}" "200" \
       "${LAB_BASE_URL}/api/v1/tenant"; then
    log_summary; return 1
  fi

  local outdir="${LAB_RESULTS_DIR}/edge-conformance/lab-gateway-$(date +%Y%m%dT%H%M%S)"
  if run_suite "${LAB_BASE_URL}" "lab-gateway" "$outdir"; then
    log_pass "every clause passes against the lab gateway over TLS" "${outdir}"
    log_info "This is the first time the transparent edge contract has met a real gateway"
    log_info "rather than a stand-in proxy — Clause 1 is now proven through TLS termination"
    log_info "and host-based routing, not merely through a transparent pass-through."
  else
    log_fail "the conformance suite failed against the lab gateway" "${outdir}/maven.log"
    log_context "$(grep -E 'FAIL|expected|AssertionFailed' "${outdir}/maven.log" 2>/dev/null | head -20)"
    log_info "A failure here is a finding about the GATEWAY. Do not amend the suite (SC-020)."
  fi

  log_summary
}

# ---------------------------------------------------------------------------
# hostile — the same suite MUST FAIL, naming the violated clause (T089, FR-042)
#
# A suite that only ever meets a correct edge cannot distinguish "the edge is
# transparent" from "the assertions no longer work". The pass alone proves
# nothing, which is why both targets are required.
# ---------------------------------------------------------------------------

# restore — revert the hostile configuration. Idempotent: clears HOSTILE_APPLIED
# when it runs, so being called both explicitly and from the EXIT trap is safe.
restore() {
  (( HOSTILE_APPLIED )) || return 0
  HOSTILE_APPLIED=0
  printf '\n'
  log_step "reverting the hostile configuration"
  $K delete -f "${LAB_ROOT}/hostile-edge/" --ignore-not-found >/dev/null 2>&1 || true
  # Reapplying the chart's own routes restores the correct edge.
  "${LAB_ROOT}/scripts/app.sh" deploy >/dev/null 2>&1 || true
  # Verified by SUBSTANCE, not by status code. The hostile edge returns
  # HTTP 200 too — it answers {"status":"unknown"} with a 200 — so the
  # original check here could not tell a restored gateway from a still
  # hostile one, and would have reported a successful restore either way.
  # The condition is that the tenant RESOLVES again.
  if wait_for "the lab gateway resolves tenants again" 180 \
       bash -c "curl -s --cacert '${LAB_CA_CERT}' --max-time 10 \
         '${LAB_BASE_URL}/api/v1/tenant' 2>/dev/null | grep -q '\"status\":\"recognized\"'"; then
    log_pass "the environment is back to a state where conformance passes" \
             "GET /api/v1/tenant resolves the tenant again — not merely HTTP 200 (FR-042)"
  else
    log_fail "the environment did NOT return to a passing state"
    log_info "A drill that cannot restore the environment is a failed drill."
    log_context "$(curl -s --cacert "${LAB_CA_CERT}" --max-time 10 "${LAB_BASE_URL}/api/v1/tenant" 2>&1)"
    # Recorded rather than returned, because this also runs from an EXIT trap
    # where a return value goes nowhere. The caller folds it into the exit
    # status. Without it the drill exits 0 having left the gateway hostile —
    # which is exactly what happened once.
    HOSTILE_RESTORE_FAILED=1
  fi
}

cmd_hostile() {
  log_suite "edge conformance: HOSTILE GATEWAY (the suite MUST fail)"

  guard "${LAB_BASE_URL}" || { log_summary; return 1; }
  assert_suite_unmodified || { log_summary; return 1; }

  # DELIBERATELY NOT `local`. This is read by the EXIT trap below, which fires
  # at script scope after cmd_hostile has returned — at which point a `local`
  # is out of scope and `set -u` aborts the trap with "applied: unbound
  # variable" BEFORE the revert runs.
  #
  # That is not hypothetical. It was masked for as long as run_suite leaked
  # `set -e`, because the drill then died INSIDE this function, where the local
  # was still visible. Fixing the leak surfaced it: the drill reported 5/5 PASS
  # and exit 0 while leaving the gateway rewriting Host on every request.
  # A drill that does not restore is a failed drill even when every assertion
  # in it passed.
  HOSTILE_APPLIED=0


  log_step "applying the deliberately hostile gateway configuration"
  if $K apply -f "${LAB_ROOT}/hostile-edge/" >/dev/null 2>&1; then
    HOSTILE_APPLIED=1
    log_pass "hostile configuration applied" "one documented command (FR-042)"
  else
    log_fail "could not apply the hostile configuration"
    log_context "$($K apply -f "${LAB_ROOT}/hostile-edge/" 2>&1)"
    log_summary; return 1
  fi

  # The hostile configuration must be OBSERVED to be in force before the suite
  # runs, and failing to establish that is FATAL rather than a warning.
  #
  # This previously logged "running the suite anyway" and continued. That turned
  # a broken precondition into a false accusation: a hostile manifest that had
  # no effect (see hostile-edge/host-rewrite.yaml — Gateway API silently ignores
  # a RequestHeaderModifier on Host) left a perfectly correct edge in place, the
  # suite passed as it should have, and the drill reported "the suite PASSED
  # against the hostile gateway", i.e. blamed the assertions for working.
  #
  # If the edge cannot be made hostile, this drill has established NOTHING about
  # the suite, and saying so is the only honest outcome.
  if ! wait_for "the hostile configuration is in force" 120 \
       bash -c "curl -s --cacert '${LAB_CA_CERT}' --max-time 10 \
         '${LAB_BASE_URL}/api/v1/tenant' 2>/dev/null | grep -q '\"status\":\"unknown\"'"; then
    log_fail "the hostile configuration never took effect" \
             "the edge still resolves tenants, so there is nothing hostile to detect"
    log_info "This is a defect in the HOSTILE CONFIGURATION or in the gateway's handling"
    log_info "of it — NOT in the conformance suite. Running the suite now would test a"
    log_info "correct edge and misreport the pass as a suite failure, which is exactly"
    log_info "what this check exists to prevent."
    log_context "GET ${LAB_BASE_URL}/api/v1/tenant -> $(curl -s --cacert "${LAB_CA_CERT}" --max-time 10 "${LAB_BASE_URL}/api/v1/tenant" 2>&1)
applied HTTPRoute filters:
$($K -n "${NS_APP}" get httproute hydra-api -o jsonpath='{.spec.rules[0].filters}' 2>&1)"
    log_summary; return 1
  fi

  local outdir="${LAB_RESULTS_DIR}/edge-conformance/hostile-gateway-$(date +%Y%m%dT%H%M%S)"
  if run_suite "${LAB_BASE_URL}" "hostile-gateway" "$outdir"; then
    # THE SUITE PASSED AGAINST A DELIBERATELY BROKEN EDGE. That is the worst
    # outcome available here: it means the assertions no longer detect the
    # violation they exist to detect.
    log_fail "the suite PASSED against the hostile gateway" "${outdir}/maven.log"
    log_info "This is a failure of the SUITE, not of the gateway. The hostile configuration"
    log_info "rewrites Host and emits duplicate CORS headers; a conformance suite that does"
    log_info "not notice has stopped testing the contract."
  else
    log_pass "the suite FAILED against the hostile gateway, as required" "${outdir}"

    # WHICH clause it failed on, read from the Surefire XML — the Edge
    # Conformance Result entity's substance (data-model §9) — and labelled from
    # the suite's OWN @DisplayName.
    #
    # The previous version grepped maven.log for 'Clause [0-9]+'. The suite
    # never prints that: Surefire reports a failure by METHOD name
    # (`hostIsPreserved`), and the clause wording lives in the @DisplayName
    # annotation. So the check could only ever report "it failed but did not
    # name a clause" — against a suite that names it precisely. Reading the
    # annotation keeps integration-tests/ the single authority for the mapping
    # rather than duplicating it here, where it would drift.
    local violated
    violated="$(clauses_that_failed "${outdir}")"
    if [[ -n "$violated" ]]; then
      log_pass "it named the violated clause(s)" "$(printf '%s' "$violated" | tr '\n' ';' | sed 's/;$//')"
    else
      log_fail "it failed but did not name a clause"
      log_context "$(grep -E 'FAILURE|expected' "${outdir}/maven.log" 2>/dev/null | head -10)"
    fi
  fi

  log_summary
}

case "$TARGET" in
  lab)     cmd_lab ;;
  hostile)
    # The revert is invoked EXPLICITLY here and guarded by an EXIT trap that
    # only fires if we never reach it (an early exit, or an interrupt). It runs
    # exactly once either way: `restore` clears HOSTILE_APPLIED when it is done.
    trap restore EXIT
    cmd_hostile
    rc=$?
    restore
    trap - EXIT
    # A drill that leaves the gateway hostile has failed, however many of its
    # own assertions passed. Without this it exits 0 with Host still rewritten.
    if (( HOSTILE_RESTORE_FAILED )); then
      printf '\nedge-conformance: FAIL — the hostile configuration was not reverted.\n'
      printf 'The gateway may still be rewriting Host. Recover with: make app-deploy\n'
      exit 1
    fi
    exit $rc ;;
  *) log_error "usage: edge-conformance.sh {lab|hostile|--available}"; exit 2 ;;
esac
