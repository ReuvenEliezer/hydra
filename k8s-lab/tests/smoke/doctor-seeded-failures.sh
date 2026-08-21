#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# doctor-seeded-failures.sh — SC-002 (T021).
#
# SC-002 asks for something stronger than "the diagnostic works": for each
# seeded missing prerequisite, the diagnostic must name *that specific tool*,
# exit non-zero, and leave no side effect on the host.
#
# The seeding mechanism is PATH manipulation, not uninstallation. Each case
# runs doctor.sh with a PATH that hides exactly one tool, which produces a host
# that genuinely lacks it from the script's point of view while changing
# nothing about the real machine. Uninstalling a tool to test a diagnostic
# would be a strange thing to do to someone's workstation, and it would also
# make the install-nothing assertion below untestable — you cannot prove a
# script left no side effect in a run where the harness itself did.
#
# The third assertion is the one that matters most and is easiest to skip: a
# before/after fingerprint of everything doctor.sh could plausibly touch. FR-003
# is a promise about what the script does *not* do, and only a comparison can
# check that.
# ---------------------------------------------------------------------------
set -uo pipefail

LAB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "${LAB_ROOT}/scripts/lib/versions.sh"
source "${LAB_ROOT}/scripts/lib/log.sh"
source "${LAB_ROOT}/scripts/lib/assert.sh"

log_suite "doctor seeded failures (SC-002)"

SHIM_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/doctor-seed.XXXXXX")"
trap 'rm -rf "${SHIM_ROOT}"' EXIT

# A PATH that contains only shims for the tools we want visible. Hiding a tool
# means simply not creating a shim for it.
build_path_hiding() {
  local hidden="$1"
  # Bash 3.2 (the macOS default) will not let a second name in the same `local`
  # statement reference the first under `set -u`. Two statements, deliberately.
  local bindir="${SHIM_ROOT}/${hidden}-hidden"
  rm -rf "$bindir"; mkdir -p "$bindir"
  # Mirror *every* executable on the current PATH except the hidden one. An
  # allow-list of "tools doctor.sh probably uses" was the first attempt and it
  # was wrong: it silently omitted bash itself, so the seeded runs all died at
  # exit 127 and every assertion below failed for a reason that had nothing to
  # do with the diagnostic. A host missing exactly one tool is the thing being
  # simulated, so mirror the host and remove exactly one thing.
  local dir entry name
  local IFS=:
  for dir in $PATH; do
    [[ -d "$dir" ]] || continue
    for entry in "$dir"/*; do
      [[ -x "$entry" && ! -d "$entry" ]] || continue
      name="$(basename "$entry")"
      [[ "$name" == "$hidden" ]] && continue
      [[ -e "${bindir}/${name}" ]] && continue   # first on PATH wins, as it would
      ln -sf "$entry" "${bindir}/${name}" 2>/dev/null || true
    done
  done
  printf '%s' "$bindir"
}

# A fingerprint of the state FR-003 promises not to touch.
host_fingerprint() {
  {
    printf 'kube-contexts: '
    kubectl config get-contexts -o name 2>/dev/null | sort | tr '\n' ',' || true
    printf '\nkind-clusters: '
    kind get clusters 2>/dev/null | sort | tr '\n' ',' || true
    printf '\ndocker-containers: '
    docker ps -a --format '{{.Names}}' 2>/dev/null | sort | tr '\n' ',' || true
    printf '\ndocker-networks: '
    docker network ls --format '{{.Name}}' 2>/dev/null | sort | tr '\n' ',' || true
    printf '\ndocker-images: '
    docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | sort | md5 2>/dev/null || \
      docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | sort | md5sum 2>/dev/null || true
    printf '\nlab-certs: '
    ls -1 "${LAB_CERT_DIR}" 2>/dev/null | sort | tr '\n' ',' || true
    printf '\nhosts-file: '
    md5 -q /etc/hosts 2>/dev/null || md5sum /etc/hosts 2>/dev/null | awk '{print $1}' || true
    printf '\n'
  } 2>/dev/null
}

# The host's own baseline. This suite runs on a real workstation which may
# genuinely be missing a required tool — this one is, at the time of writing:
# kind and helm are absent, so doctor.sh exits non-zero no matter what is
# seeded. An optional-prerequisite assertion phrased as "the run still exits
# zero" would therefore be measuring the host, not the diagnostic. What is
# actually being asserted is narrower and host-independent: hiding an *optional*
# tool must not increase the required-failure count.
doctor_required_failures() {
  sed -n 's/^ *\([0-9][0-9]*\) passed  *\([0-9][0-9]*\) failed (required).*/\2/p' <<< "$1" | head -1
}

BASELINE_OUT="$("${LAB_ROOT}/scripts/doctor.sh" 2>&1 || true)"
BASELINE_REQUIRED_FAILURES="$(doctor_required_failures "$BASELINE_OUT")"
printf 'Host baseline: %s required failure(s) with nothing seeded.\n' "${BASELINE_REQUIRED_FAILURES:-?}"

# seed_case <tool> required|optional
seed_case() {
  local tool="$1"
  local level="$2"
  local bindir out rc before after seeded_failures

  before="$(host_fingerprint)"

  bindir="$(build_path_hiding "$tool")"
  out="$(PATH="${bindir}" "${LAB_ROOT}/scripts/doctor.sh" 2>&1)"; rc=$?

  after="$(host_fingerprint)"
  seeded_failures="$(doctor_required_failures "$out")"

  # 1. It names the specific tool that is missing. "Names it" means the tool
  #    appears on a line that reports a problem — not that a particular
  #    sentence was used. doctor.sh legitimately phrases these differently:
  #    a missing `docker` is reported as "container CLI is not installed
  #    [neither docker nor podman on PATH]", because the *check* is about the
  #    container CLI and the tool names are the evidence.
  if grep -E '^(FAIL|WARN)' <<< "$out" | grep -qiE "(^|[^a-z])${tool}([^a-z]|$)"; then
    log_pass "seeded missing '${tool}': the diagnostic names ${tool}" "PATH without ${tool}"
  else
    log_fail "seeded missing '${tool}': no FAIL or WARN line mentions it"
    log_context "$(grep -E '^(FAIL|WARN)' <<< "$out" | head -10)"
  fi

  if [[ "$level" == "required" ]]; then
    # 2. A missing required prerequisite makes the run non-zero and says so.
    if (( rc != 0 )); then
      log_pass "seeded missing '${tool}': exit ${rc} (non-zero)" "FR-002"
    else
      log_fail "seeded missing '${tool}': exited zero on a missing required prerequisite"
    fi
    if grep -q 'ENVIRONMENT NOT READY' <<< "$out"; then
      log_pass "seeded missing '${tool}': states ENVIRONMENT NOT READY" "readiness statement"
    else
      log_fail "seeded missing '${tool}': no ENVIRONMENT NOT READY statement"
    fi
    # 3. And it is *this* tool that pushed the count up, not an unrelated one.
    #    Only meaningful when the tool actually passes at baseline: on a host
    #    that is already missing kind, hiding kind cannot raise the count, and
    #    a failure here would be a statement about the workstation rather than
    #    about the diagnostic. Assertions 1 and 2 still cover that case fully.
    # "Already failing at baseline" covers two cases, not one: the tool is
    # absent, and the tool is present but its own check already fails — this
    # host's kubectl is a minor behind the pin, so hiding it swaps one failure
    # for another and the count does not move.
    if grep -E '^FAIL' <<< "$BASELINE_OUT" | grep -qiE "(^|[^a-z])${tool}([^a-z]|$)"; then
      log_info "delta check not applicable for '${tool}': it already fails on this host at baseline (${BASELINE_REQUIRED_FAILURES} required failures), so hiding it cannot raise the count"
    elif [[ -n "$seeded_failures" && -n "$BASELINE_REQUIRED_FAILURES" ]] \
       && (( seeded_failures > BASELINE_REQUIRED_FAILURES )); then
      log_pass "seeded missing '${tool}': required failures ${BASELINE_REQUIRED_FAILURES} -> ${seeded_failures}" \
               "the seeded tool is what changed the verdict"
    elif [[ -n "$seeded_failures" ]]; then
      log_fail "seeded missing '${tool}': required failures unchanged at ${seeded_failures}"
      log_context "Hiding a required tool must add a required failure, or some other check is compensating for it."
    fi
  else
    # An optional prerequisite may warn. It must not turn into a required
    # failure, and it must not go unmentioned.
    if [[ -n "$seeded_failures" && -n "$BASELINE_REQUIRED_FAILURES" ]] \
       && (( seeded_failures == BASELINE_REQUIRED_FAILURES )); then
      log_pass "seeded missing '${tool}': optional — required failures stay at ${seeded_failures}" \
               "FR-001: optional checks may warn without failing the run"
    else
      log_fail "seeded missing '${tool}': optional prerequisite changed the required-failure count (${BASELINE_REQUIRED_FAILURES} -> ${seeded_failures})"
    fi
  fi

  # 4. It changed nothing (FR-003) — the assertion the requirement turns on.
  if [[ "$before" == "$after" ]]; then
    log_pass "seeded missing '${tool}': no host side effect" "fingerprint unchanged across the run"
  else
    log_fail "seeded missing '${tool}': the diagnostic changed host state"
    log_context "$(diff <(printf '%s' "$before") <(printf '%s' "$after") || true)"
  fi

  # 5. It offers a remedy rather than only a complaint.
  if grep -q '→' <<< "$out"; then
    log_pass "seeded missing '${tool}': output includes an instruction" "reports and instructs (FR-003)"
  else
    log_fail "seeded missing '${tool}': named the problem with no instruction"
  fi
}

log_section "required prerequisites"
seed_case kind    required
seed_case kubectl required
seed_case helm    required
seed_case docker  required
seed_case jq      required
seed_case curl    required

log_section "optional prerequisites"
# Java and Maven are needed only by `make test-edge-conformance`; the image
# build uses the pinned toolchain image (D2). They warn; they do not block.
seed_case mvn  optional
seed_case java optional

log_section "install-nothing guarantee, stated directly"
out_full="$("${LAB_ROOT}/scripts/doctor.sh" 2>&1 || true)"
assert_contains "the diagnostic states its install-nothing guarantee in its own output" \
  "$out_full" "installed, modified or upgraded"

# The strongest available check that doctor.sh cannot install anything: it
# contains no package-manager, download or write invocation at all.
log_section "static guard"
# Strings are stripped before grepping. Without that, every `remedy "brew
# install helm"` line — which is the script *telling a human what to run* —
# reads as the script running it, and the guard fails on the exact behaviour
# FR-003 asks for. What is left after stripping is command position only.
forbidden="$(sed -e "s/'[^']*'/''/g" -e 's/"[^"]*"/""/g' "${LAB_ROOT}/scripts/doctor.sh" \
  | grep -nE '(^|[;|&(]|&&|\|\|)[[:space:]]*(brew|apt-get|yum|dnf|pacman|snap|npm|pip3?|wget|kind[[:space:]]+create|helm[[:space:]]+(install|upgrade)|kubectl[[:space:]]+(apply|create|delete)|docker[[:space:]]+(run|pull|build|rm))([[:space:]]|$)' \
  | grep -vE '^[0-9]+:[[:space:]]*#' || true)"
if [[ -z "$forbidden" ]]; then
  log_pass "doctor.sh contains no install, download or apply invocation" "static grep over the script"
else
  log_fail "doctor.sh contains an invocation that could modify the host"
  log_context "$forbidden"
fi

log_summary
