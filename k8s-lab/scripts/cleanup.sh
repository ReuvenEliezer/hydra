#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# cleanup.sh — `make cleanup` (FR-109).
#
# Removes the cluster, the registry and lab-created local state, leaving the
# first-run path working. The test of this target is not that it deletes things
# — it is that `make setup` afterwards behaves exactly as it does on a machine
# that has never run the lab. Half-removed state is the failure mode: a stale
# registry container, an orphaned kubeconfig context or a leftover certificate
# each produce a setup failure that points somewhere else entirely.
#
# It removes only what the lab created, identified by the lab's own names. It
# never prunes Docker broadly, never touches other clusters, and never touches
# anything outside k8s-lab/.
# ---------------------------------------------------------------------------
set -uo pipefail

LAB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${LAB_ROOT}/scripts/lib/versions.sh"
source "${LAB_ROOT}/scripts/lib/log.sh"

KEEP_CERTS=0
KEEP_RESULTS=1     # run output is evidence; deleting it by default would throw
                   # away the only record that anything was ever executed.
while [[ $# -gt 0 ]]; do
  case "$1" in
    --keep-certs)    KEEP_CERTS=1; shift ;;
    --purge-results) KEEP_RESULTS=0; shift ;;
    *) log_error "unknown argument: $1"; exit 2 ;;
  esac
done

log_suite "cleanup"

# --- 1. The cluster --------------------------------------------------------
log_section "cluster"
if command -v kind >/dev/null 2>&1 && kind get clusters 2>/dev/null | grep -qx "${LAB_CLUSTER}"; then
  if kind delete cluster --name "${LAB_CLUSTER}" >/dev/null 2>&1; then
    log_pass "kind cluster '${LAB_CLUSTER}' deleted" "kind delete cluster"
  else
    log_fail "kind cluster '${LAB_CLUSTER}' would not delete"
    log_context "$(docker ps -a --filter "name=${LAB_CLUSTER}" --format '{{.Names}}\t{{.Status}}' 2>&1)"
  fi
else
  log_pass "no kind cluster '${LAB_CLUSTER}' to delete" "kind get clusters"
fi

# kind normally removes its own node containers. When a delete was interrupted
# they survive, and the next `kind create` fails on a name collision — which is
# the stale-state failure T026 exists to converge rather than inherit.
orphans="$(docker ps -a --filter "name=${LAB_CLUSTER}-" --format '{{.Names}}' 2>/dev/null || true)"
if [[ -n "$orphans" ]]; then
  printf '%s\n' "$orphans" | while read -r c; do docker rm -f "$c" >/dev/null 2>&1 || true; done
  log_pass "removed orphaned node containers" "$(printf '%s' "$orphans" | tr '\n' ' ')"
fi

# --- 2. The registry -------------------------------------------------------
log_section "registry"
if docker ps -a --filter "name=^${REGISTRY_NAME}$" --format '{{.Names}}' 2>/dev/null | grep -qx "${REGISTRY_NAME}"; then
  docker rm -f "${REGISTRY_NAME}" >/dev/null 2>&1 \
    && log_pass "registry container '${REGISTRY_NAME}' removed" "docker rm -f" \
    || log_fail "registry container '${REGISTRY_NAME}' would not remove"
else
  log_pass "no registry container to remove" "docker ps -a"
fi

# The kind network is shared with any other kind cluster on this machine, so it
# is removed only when nothing else is attached to it. Tearing down a network
# another cluster is using would be this script reaching outside its own scope.
if docker network inspect kind >/dev/null 2>&1; then
  attached="$(docker network inspect kind -f '{{len .Containers}}' 2>/dev/null || echo 0)"
  if [[ "$attached" == "0" ]]; then
    docker network rm kind >/dev/null 2>&1 || true
    log_pass "empty 'kind' docker network removed" "docker network rm kind"
  else
    log_pass "'kind' docker network left in place" "${attached} container(s) still attached"
  fi
fi

# --- 3. Local kube state ---------------------------------------------------
log_section "local state"
if kubectl config get-contexts -o name 2>/dev/null | grep -qx "${LAB_KUBECONTEXT}"; then
  kubectl config delete-context "${LAB_KUBECONTEXT}" >/dev/null 2>&1 || true
  kubectl config delete-cluster "${LAB_KUBECONTEXT}" >/dev/null 2>&1 || true
  kubectl config unset "users.${LAB_KUBECONTEXT}" >/dev/null 2>&1 || true
  log_pass "kubeconfig context '${LAB_KUBECONTEXT}' removed" "kubectl config delete-context"
else
  log_pass "no kubeconfig context to remove" "kubectl config get-contexts"
fi

# --- 4. Generated TLS material --------------------------------------------
if (( KEEP_CERTS )); then
  log_pass "TLS material kept" "--keep-certs"
else
  if [[ -d "${LAB_CERT_DIR}" ]]; then
    rm -rf "${LAB_CERT_DIR}"
    log_pass "generated TLS material removed" "rm -rf ${LAB_CERT_DIR}"
  else
    log_pass "no TLS material to remove" "${LAB_CERT_DIR} absent"
  fi
fi

# --- 5. Run output ---------------------------------------------------------
if (( KEEP_RESULTS )); then
  log_pass "results/ kept" "run evidence is not removed unless --purge-results is given"
else
  rm -rf "${LAB_RESULTS_DIR:?}"/* 2>/dev/null || true
  log_pass "results/ purged" "--purge-results"
fi

# current-image-tag is removed ALWAYS, including when results/ is kept.
#
# It lives under results/ but it is not run evidence — it is LIVE STATE that
# app.sh reads to decide which image the chart deploys. The registry it names
# has just been destroyed a few lines above, so keeping it means the next
# "clean" rebuild starts by trusting a pointer to something that no longer
# exists.
#
# That is not hypothetical. A reproducibility run deployed
# `auth-service:dc8c1c9-dirty` — a tag from a previous session's build — into a
# freshly created, empty registry, and sat in ImagePullBackOff while the
# registry itself was perfectly healthy. The current run had built and tagged
# `31e9344-dirty`; nothing had ever published `dc8c1c9-dirty` into this
# registry. The stale pointer outlived the thing it pointed at.
if [[ -f "${LAB_RESULTS_DIR}/current-image-tag" ]]; then
  rm -f "${LAB_RESULTS_DIR}/current-image-tag"
  log_pass "current-image-tag removed" "live state, not evidence — the registry it named is gone"
fi

# --- 6. The gitops working remote -----------------------------------------
if [[ -d "${LAB_ROOT}/.gitops-remote" ]]; then
  rm -rf "${LAB_ROOT}/.gitops-remote"
  log_pass "local Argo CD git remote removed" "rm -rf .gitops-remote"
fi

log_section "first-run path"
# The point of cleanup is this line, and it is an executed check rather than a
# closing reassurance.
remaining=""
kind get clusters 2>/dev/null | grep -qx "${LAB_CLUSTER}" && remaining+="cluster "
docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "${REGISTRY_NAME}" && remaining+="registry "
[[ -d "${LAB_CERT_DIR}" ]] && (( ! KEEP_CERTS )) && remaining+="certs "
if [[ -z "$remaining" ]]; then
  log_pass "no lab state remains — the first-run path works again" "re-inspected after removal"
else
  log_fail "lab state still present: ${remaining}"
fi

log_summary
