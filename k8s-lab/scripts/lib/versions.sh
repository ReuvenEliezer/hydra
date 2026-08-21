#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# versions.sh — the sole loader of versions.env (FR-006).
#
# No other script in this tree reads versions.env directly, and none hard-codes
# a version. Sourcing this file exports every entry as an environment variable
# and fails loudly if the matrix is missing, unreadable, or contains a moving
# reference. That last check runs on every load rather than only under
# `make verify-versions`, so a `latest` slipped into the matrix fails the next
# command someone runs rather than surviving until the next audit.
# ---------------------------------------------------------------------------
set -uo pipefail

LAB_ROOT="${LAB_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
export LAB_ROOT
VERSIONS_FILE="${LAB_ROOT}/versions.env"

if [[ ! -r "$VERSIONS_FILE" ]]; then
  printf 'ERROR the version matrix is missing or unreadable: %s\n' "$VERSIONS_FILE" >&2
  printf '      Every version the lab uses lives there. No script carries a fallback.\n' >&2
  exit 1
fi

# A moving reference is a version that can change underneath a reproducible
# run. Permitted only with a documented `# exception:` line immediately above
# the entry — a mechanism that exists so an exception has to be written down,
# not so one is convenient to add.
_versions_reject_moving_references() {
  local line prev="" lineno=0 offender=0
  while IFS= read -r line; do
    lineno=$((lineno + 1))
    if [[ "$line" =~ ^[A-Z_]+=(.*)$ ]]; then
      local value="${BASH_REMATCH[1]}"
      if [[ "$value" =~ (^|[:/=-])(latest|stable|main|master|edge|nightly)($|[[:space:]]) ]]; then
        if [[ "$prev" =~ ^#[[:space:]]*exception: ]]; then
          : # documented, and the reason is on the preceding line
        else
          printf 'ERROR versions.env:%d moving reference with no documented exception: %s\n' \
            "$lineno" "$line" >&2
          offender=1
        fi
      fi
    fi
    prev="$line"
  done < "$VERSIONS_FILE"
  return $offender
}

_versions_reject_moving_references || exit 1

# shellcheck disable=SC1090
set -a
source "$VERSIONS_FILE"
set +a

# versions_require <VAR...> — fail with the variable's name rather than an
# empty expansion downstream.
versions_require() {
  local var missing=0
  for var in "$@"; do
    if [[ -z "${!var:-}" ]]; then
      printf 'ERROR %s is not set in %s\n' "$var" "$VERSIONS_FILE" >&2
      missing=1
    fi
  done
  return $missing
}

# Derived values every script needs, computed once here so they cannot drift
# between callers.
export LAB_CLUSTER="${KIND_CLUSTER_NAME}"
export LAB_KUBECONTEXT="kind-${KIND_CLUSTER_NAME}"
export LAB_CERT_DIR="${LAB_ROOT}/.certs"
export LAB_CA_CERT="${LAB_CERT_DIR}/lab-ca.crt"
export LAB_TRUSTSTORE="${LAB_CERT_DIR}/lab-truststore.p12"
export LAB_TRUSTSTORE_PASSWORD_FILE="${LAB_CERT_DIR}/truststore-password"
export LAB_RESULTS_DIR="${LAB_ROOT}/results"
# The bare git repository Argo CD reconciles from. Bind-mounted into every kind
# node (cluster/kind-cluster.yaml) so the repo-server POD can read it without a
# git server, credentials or network access — the repo-server cannot see a
# file:// path on the workstation, which is a mistake that reports itself as
# "repository not found".
export LAB_GITOPS_REMOTE_DIR="${LAB_ROOT}/.gitops-remote"
export LAB_GITOPS_REPO_IN_CLUSTER="file:///gitops-remote/hydra-lab.git"
export LAB_PRIMARY_HOST="${LAB_PRIMARY_TENANT}.${LAB_BASE_DOMAIN}"
export LAB_SECOND_HOST="${LAB_SECOND_TENANT}.${LAB_BASE_DOMAIN}"
export LAB_LATE_HOST="${LAB_LATE_TENANT}.${LAB_BASE_DOMAIN}"
export LAB_BASE_URL="https://${LAB_PRIMARY_HOST}"
# The registry as the workstation addresses it, and as a node's containerd
# addresses it. They are not the same string, and FR-019 exists because
# assuming they are is the standard way this breaks (see registry.sh).
export LAB_REGISTRY_HOST_ADDR="localhost:${REGISTRY_PORT}"
export LAB_REGISTRY_NODE_ADDR="${REGISTRY_NAME}:5000"

versions_require KIND_VERSION KIND_NODE_IMAGE KUBERNETES_VERSION \
  CILIUM_CHART_VERSION GATEWAY_API_VERSION REGISTRY_IMAGE \
  POSTGRES_IMAGE REDIS_IMAGE MAVEN_BUILDER_IMAGE JAVA_RUNTIME_IMAGE \
  OTEL_JAVA_AGENT_VERSION || exit 1
