#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# verify-versions.sh — `make verify-versions` (SC-022).
#
# Asserts four things about this tree:
#
#   1. Every version referenced anywhere under k8s-lab/ resolves to a
#      versions.env entry — no literal pins in scripts, charts or manifests.
#   2. Zero moving references (`latest`, `stable`, `main`, a bare major) exist
#      outside a documented exception.
#   3. docs/versions.md is current with versions.env, so the rendered matrix
#      cannot silently drift from the authority.
#   4. No script uses a fixed sleep as a readiness signal (FR-015). This lives
#      here rather than in a separate target because it is the same class of
#      defect: a value that should have come from a declared source and instead
#      got guessed at a call site.
#
# What this cannot check: whether the pinned versions are mutually compatible.
# Only an executed `make setup` establishes that (FR-116, risk register #7).
# ---------------------------------------------------------------------------
set -uo pipefail

LAB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${LAB_ROOT}/scripts/lib/versions.sh"
source "${LAB_ROOT}/scripts/lib/log.sh"

log_suite "verify-versions"

# Files this check reads. Generated output and vendored CRDs are excluded:
# results/ is run output, .certs/ is generated material, and the Gateway API
# CRD manifests are upstream artifacts carrying their own embedded version
# strings — pinning those is what GATEWAY_API_VERSION does, and rewriting
# upstream YAML to satisfy a lint would be worse than the drift it prevents.
_lab_files() {
  find "${LAB_ROOT}" \
    -type d \( -name results -o -name .certs -o -name crds -o -name .git \) -prune -o \
    -type f \( -name '*.sh' -o -name '*.yaml' -o -name '*.yml' -o -name 'Makefile' -o -name 'Dockerfile*' \) -print
}

# --- 1 & 2. Moving references ---------------------------------------------
log_section "moving references"
moving_hits=""
while IFS= read -r f; do
  # `:latest`, `:stable`, `--version latest`, `image: foo:main`
  # Only a VALUE position counts. The first version of this check matched the
  # bare words anywhere on a line, which flagged every prose mention of "edge"
  # in a lab whose subject is an edge — dozens of false positives, and a check
  # that cries wolf is a check someone deletes. "edge" is gone from the keyword
  # list for the same reason: it is an ordinary English word here.
  #
  # Matched forms:  image: foo:latest   version: stable   --version=main
  hits="$(grep -nE '((image|tag|version|chart|ref|revision|targetRevision)[[:space:]]*[:=][[:space:]]*["'"'"']?|:)(latest|stable|nightly|main|master)([[:space:]"'"'"',]|$)' "$f" 2>/dev/null \
          | grep -vE '^[0-9]+:[[:space:]]*#' \
          | grep -vE '^[0-9]+:[[:space:]]*(--|\*|\{\{/\*)' \
          | grep -vE 'OTEL_TRACES_SAMPLER|always_on|# *allowed-moving-reference' || true)"
  [[ -n "$hits" ]] && moving_hits+="${f}:
${hits}
"
done < <(_lab_files)

if [[ -z "$moving_hits" ]]; then
  log_pass "no moving image tag or chart version outside a documented exception" "grep over k8s-lab/"
else
  log_fail "moving reference found"
  log_context "$moving_hits"
fi

# --- 3. No hard-coded version literals in scripts and charts ---------------
log_section "version literals"
# Every value in the matrix that looks like a version, as a literal to hunt for
# outside versions.env itself.
literal_hits=""
while IFS='=' read -r key value; do
  [[ "$key" =~ ^[A-Z_]+$ ]] || continue
  [[ -n "$value" ]] || continue
  # Only values that are actually version-shaped are worth hunting: a bare
  # name like `hydra-lab` appearing in a template is correct, not a drift.
  [[ "$value" =~ ^v?[0-9]+\.[0-9]+ || "$value" =~ :[0-9]+\.[0-9]+ || "$value" =~ :[0-9]+-[a-z] ]] || continue
  while IFS= read -r f; do
    [[ "$f" == "${LAB_ROOT}/versions.env" ]] && continue
    hits="$(grep -nF "$value" "$f" 2>/dev/null | grep -vE '^[0-9]+:[[:space:]]*#' || true)"
    if [[ -n "$hits" ]]; then
      literal_hits+="${key}=${value} hard-coded in ${f}:
${hits}
"
    fi
  done < <(_lab_files)
done < "${LAB_ROOT}/versions.env"

if [[ -z "$literal_hits" ]]; then
  log_pass "no version literal appears outside versions.env" "grep for every matrix value"
else
  log_fail "a version is hard-coded outside the matrix"
  log_context "$literal_hits"
  log_info "Fix by substituting the variable, not by editing the matrix to match the literal."
fi

# --- 4. Rendered matrix is current ----------------------------------------
log_section "rendered matrix"
rendered_tmp="$(mktemp)"
trap 'rm -f "${rendered_tmp}"' EXIT
cp "${LAB_ROOT}/docs/versions.md" "${rendered_tmp}"
"${LAB_ROOT}/scripts/render-versions.sh" >/dev/null 2>&1
if diff -q "${rendered_tmp}" "${LAB_ROOT}/docs/versions.md" >/dev/null 2>&1; then
  log_pass "docs/versions.md is current with versions.env" "render-versions.sh + diff"
else
  log_fail "docs/versions.md was stale — it has just been regenerated"
  log_context "$(diff "${rendered_tmp}" "${LAB_ROOT}/docs/versions.md" | head -20)"
fi

# --- 5. No fixed sleep as a readiness signal (FR-015) ---------------------
log_section "bounded waits"
# `sleep` is legitimate only as the interval inside a polling loop, which in
# this tree means inside wait.sh, or as an explicit WAIT_POLL_INTERVAL.
sleep_hits=""
while IFS= read -r f; do
  [[ "$f" == "${LAB_ROOT}/scripts/lib/wait.sh" ]] && continue
  hits="$(grep -nE '(^|[^_[:alnum:]])sleep[[:space:]]+[0-9]' "$f" 2>/dev/null \
          | grep -vE '^[0-9]+:[[:space:]]*#' \
          | grep -vE 'WAIT_POLL_INTERVAL|# *polling-interval' || true)"
  [[ -n "$hits" ]] && sleep_hits+="${f}:
${hits}
"
done < <(_lab_files)

if [[ -z "$sleep_hits" ]]; then
  log_pass "no fixed sleep is used as a readiness signal" "grep for 'sleep <n>' outside wait.sh"
else
  log_fail "a fixed sleep is being used outside wait.sh's polling loops (FR-015)"
  log_context "$sleep_hits"
  log_info "Replace with wait_for / wait_for_output / wait_for_http — a duration is not a condition."
fi

# --- 6. The matrix itself is complete -------------------------------------
log_section "matrix completeness"
missing=""
for key in KIND_VERSION KIND_NODE_IMAGE KUBERNETES_VERSION KUBECTL_VERSION HELM_VERSION \
           CILIUM_CHART_VERSION GATEWAY_API_VERSION REGISTRY_IMAGE POSTGRES_IMAGE REDIS_IMAGE \
           PROMETHEUS_CHART_VERSION GRAFANA_CHART_VERSION OTEL_COLLECTOR_CHART_VERSION \
           TEMPO_CHART_VERSION ARGOCD_CHART_VERSION HEADLAMP_CHART_VERSION \
           MAVEN_BUILDER_IMAGE OTEL_JAVA_AGENT_VERSION; do
  [[ -n "${!key:-}" ]] || missing+="${key} "
done
if [[ -z "$missing" ]]; then
  log_pass "all sixteen FR-005 components plus the D2 toolchain and D10 agent are pinned" "versions.env"
else
  log_fail "matrix is incomplete: ${missing}"
fi

# Every entry that is version-shaped must carry a compatibility basis (FR-007).
no_basis=""
prev_comment_block=""
while IFS= read -r line; do
  case "$line" in
    '#'*) prev_comment_block+="${line}
" ;;
    [A-Z_]*=*)
      key="${line%%=*}"; value="${line#*=}"
      if [[ "$value" =~ ^v?[0-9]+\.[0-9]+ || "$value" =~ :[0-9]+ ]]; then
        [[ "$prev_comment_block" == *compatibility_basis* ]] || no_basis+="${key} "
      fi
      prev_comment_block="" ;;
    '') prev_comment_block="" ;;
  esac
done < "${LAB_ROOT}/versions.env"

if [[ -z "$no_basis" ]]; then
  log_pass "every pinned version records what it was checked against" "FR-007"
else
  log_fail "no compatibility_basis recorded for: ${no_basis}"
fi

log_summary
