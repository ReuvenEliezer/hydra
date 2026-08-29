#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# gitops.sh — the local git remote Argo CD reconciles from (D15, FR-083, FR-085).
#
# A bare repository inside the lab, not a hosted one. Three reasons, in order of
# importance:
#
#   1. The lab's steady state must work offline. A GitOps demonstration that
#      needs github.com is not reproducible on a plane.
#   2. No credentials. A hosted remote means a token, and a token means either a
#      secret in the tracked tree (FR-085) or a manual setup step.
#   3. The delivery loop is demonstrated by CHANGING a tracked value and
#      watching convergence. That works identically against a bare local repo,
#      and the mechanism being taught is the reconciliation, not the hosting.
#
# What is NOT here: any secret. The tracked tree carries Secret NAMES; the
# Secrets themselves are created out of band by app.sh (FR-085). There is no
# sealed-secrets and no encrypted blob — both are real answers to a real
# problem, and adopting one is a decision this feature has no mandate to make.
# ---------------------------------------------------------------------------
set -uo pipefail

LAB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${LAB_ROOT}/scripts/lib/versions.sh"
source "${LAB_ROOT}/scripts/lib/log.sh"

K="kubectl --context ${LAB_KUBECONTEXT}"
GITOPS_SRC="${LAB_ROOT}/gitops"
BARE_REPO="${LAB_ROOT}/.gitops-remote/hydra-lab.git"
GITOPS_BRANCH="main"

cmd_init() {
  log_suite "gitops remote"

  mkdir -p "$(dirname "$BARE_REPO")"

  if [[ ! -d "${BARE_REPO}" ]]; then
    git init --bare --initial-branch="${GITOPS_BRANCH}" "${BARE_REPO}" >/dev/null 2>&1 \
      && log_pass "bare repository created" "${BARE_REPO}" \
      || { log_fail "could not create the bare repository"; log_summary; return 1; }
  else
    log_pass "bare repository already exists" "${BARE_REPO}"
  fi

  # Push the tracked desired state into it. A working clone in a temp dir, so
  # nothing is added to the developer's own repository state.
  local work
  work="$(mktemp -d)"
  trap 'rm -rf "${work}"' RETURN

  git clone -q "${BARE_REPO}" "${work}/repo" 2>/dev/null || {
    git init -q -b "${GITOPS_BRANCH}" "${work}/repo"
    git -C "${work}/repo" remote add origin "${BARE_REPO}"
  }

  mkdir -p "${work}/repo/gitops"
  # Rendered, not copied. The tracked tree carries ${...} placeholders so no
  # version literal lives outside versions.env (FR-006, SC-022); what Argo CD
  # reconciles is the rendered form, because Argo applies manifests as-is and
  # has no substitution step of its own.
  local f rendered_line out
  for f in "${GITOPS_SRC}"/*.yaml "${GITOPS_SRC}"/*.yml; do
    [[ -r "$f" ]] || continue
    out="${work}/repo/gitops/$(basename "$f")"
    : > "$out"
    while IFS= read -r rendered_line; do
      rendered_line="${rendered_line//\$\{REGISTRY_IMAGE\}/${REGISTRY_IMAGE}}"
      rendered_line="${rendered_line//\$\{NS_APP\}/${NS_APP}}"
      printf '%s\n' "$rendered_line" >> "$out"
    done < "$f"
    if grep -q '\${' "$out"; then
      log_fail "unexpanded variables remain in $(basename "$f")"
      log_context "$(grep -n '\${' "$out")"
      log_summary; return 1
    fi
  done
  # Non-template files (README and the like) are copied unchanged.
  cp "${GITOPS_SRC}"/*.md "${work}/repo/gitops/" 2>/dev/null || true

  # FR-085, checked before the push rather than regretted after it. Git history
  # is the one place a mistake cannot simply be deleted.
  local suspicious
  suspicious="$(grep -rlEi '(BEGIN [A-Z ]*PRIVATE KEY|password:[[:space:]]*[^"$ ]|secretKey|apiKey)[^A-Za-z]' \
                "${work}/repo/gitops" 2>/dev/null || true)"
  if [[ -n "$suspicious" ]]; then
    log_fail "refusing to push: possible secret material in the gitops tree"
    log_context "$suspicious"
    log_summary; return 1
  fi
  log_pass "no secret material in the gitops tree" "grep before push (FR-085)"

  git -C "${work}/repo" add -A >/dev/null 2>&1
  if git -C "${work}/repo" diff --cached --quiet 2>/dev/null; then
    log_pass "gitops tree already current in the remote" "nothing to push"
  else
    git -C "${work}/repo" -c user.email=lab@hydra-lab -c user.name="k8s-lab" \
      commit -q -m "lab: sync tracked desired state" >/dev/null 2>&1
    git -C "${work}/repo" push -q origin "${GITOPS_BRANCH}" >/dev/null 2>&1 \
      && log_pass "desired state pushed" "branch ${GITOPS_BRANCH}" \
      || log_fail "could not push the desired state"
  fi

  log_summary
}

cmd_url()    { printf 'file://%s' "${BARE_REPO}"; }
cmd_branch() { printf '%s' "${GITOPS_BRANCH}"; }

case "${1:-init}" in
  init)   cmd_init ;;
  url)    cmd_url ;;
  branch) cmd_branch ;;
  *) log_error "usage: gitops.sh {init|url|branch}"; exit 2 ;;
esac
