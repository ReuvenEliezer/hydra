#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# registry.sh — the local image registry (FR-016, FR-019, FR-020, FR-021).
#
# FR-019 is the whole reason this file is longer than "docker run registry".
# There are FOUR distinct addresses for one registry, and every one of them is
# a different string:
#
#   1. Workstation -> registry        localhost:5001
#      Bound to a host port by the registry container. This is the address
#      `docker push` uses.
#
#   2. Node container -> registry     hydra-lab-registry:5000
#      Both are on the `kind` docker network, so the container name resolves.
#      `localhost` here means the node container itself, which is running no
#      registry — this is the mistake FR-019 exists to prevent, and it produces
#      a "connection refused" that looks like the registry is down when it is
#      running perfectly.
#
#   3. containerd inside the node -> registry
#      containerd does not use the node's /etc/hosts the way you might expect;
#      it needs an explicit `hosts.toml` mirror entry per registry host. This
#      is configured per node under /etc/containerd/certs.d/.
#
#   4. Kubernetes image reference     localhost:5001/hydra/auth-service:<tag>
#      The string in the pod spec. It must be one that containerd can resolve
#      through the mirror configured in (3) — which is why the mirror is keyed
#      on `localhost:5001` even though nothing on the node listens there.
#
# The standard kind + registry recipe works precisely because (3) maps (4) onto
# (2). Written down here because the next person to debug an ImagePullBackOff
# will need it, and the failure gives no hint.
# ---------------------------------------------------------------------------
set -uo pipefail

LAB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${LAB_ROOT}/scripts/lib/versions.sh"
source "${LAB_ROOT}/scripts/lib/log.sh"
source "${LAB_ROOT}/scripts/lib/wait.sh"

QUIET=0
[[ "${2:-}" == "--quiet" ]] && QUIET=1

REGISTRY_INTERNAL_PORT=5000

registry_running() {
  [[ "$(docker inspect -f '{{.State.Running}}' "${REGISTRY_NAME}" 2>/dev/null || echo false)" == "true" ]]
}

# ---------------------------------------------------------------------------
# create (T027, T028)
# ---------------------------------------------------------------------------
cmd_create() {
  log_suite "registry create"

  # --- 1. The container itself, idempotently.
  if registry_running; then
    log_pass "registry container '${REGISTRY_NAME}' already running" "docker inspect"
  else
    if docker inspect "${REGISTRY_NAME}" >/dev/null 2>&1; then
      # Exists but stopped. Start it rather than recreating, so any images
      # already pushed survive a workstation reboot.
      docker start "${REGISTRY_NAME}" >/dev/null 2>&1 || true
      log_pass "existing registry container restarted" "docker start"
    else
      if docker run -d --restart=always \
           --name "${REGISTRY_NAME}" \
           -p "127.0.0.1:${REGISTRY_PORT}:${REGISTRY_INTERNAL_PORT}" \
           "${REGISTRY_IMAGE}" >/dev/null 2>&1; then
        log_pass "registry container created" "${REGISTRY_IMAGE} on 127.0.0.1:${REGISTRY_PORT}"
      else
        log_fail "could not start the registry container"
        log_context "$(docker logs "${REGISTRY_NAME}" 2>&1 | tail -20 || true)"
        log_summary; return 1
      fi
    fi
  fi

  # --- 2. Address (1): reachable from the workstation.
  if ! wait_for_http "registry answers on the workstation address" "${TIMEOUT_HTTP_RESPONSIVE}" \
       "200" "http://${LAB_REGISTRY_HOST_ADDR}/v2/"; then
    log_context "$(docker logs "${REGISTRY_NAME}" 2>&1 | tail -20 || true)"
    log_summary; return 1
  fi
  log_pass "registry reachable at ${LAB_REGISTRY_HOST_ADDR}" "GET /v2/ -> 200"

  # --- 3. Address (2): on the kind network, so node containers can resolve it
  #        by name. Attaching is idempotent; "already exists" is success.
  if docker network inspect kind >/dev/null 2>&1; then
    local attached
    attached="$(docker inspect -f '{{json .NetworkSettings.Networks}}' "${REGISTRY_NAME}" 2>/dev/null | grep -c '"kind"' || true)"
    if [[ "$attached" == "0" ]]; then
      if docker network connect kind "${REGISTRY_NAME}" >/dev/null 2>&1; then
        log_pass "registry attached to the 'kind' network" "docker network connect"
      else
        log_fail "could not attach the registry to the 'kind' network"
      fi
    else
      log_pass "registry already on the 'kind' network" "docker inspect"
    fi
  else
    log_fail "the 'kind' docker network does not exist"
    log_info "The cluster must be created first — the network is created with it."
    log_summary; return 1
  fi

  # --- 4. Address (3): containerd's mirror, per node. Without this, a pod
  #        referencing localhost:5001/... asks the node's own localhost, finds
  #        nothing, and reports ErrImagePull with no clue that the mirror is
  #        missing.
  local nodes node configured=0 failed=0
  nodes="$(kind get nodes --name "${LAB_CLUSTER}" 2>/dev/null || true)"
  if [[ -z "$nodes" ]]; then
    log_fail "no nodes found for cluster '${LAB_CLUSTER}'"
    log_summary; return 1
  fi

  local certs_dir="/etc/containerd/certs.d/${LAB_REGISTRY_HOST_ADDR}"
  while IFS= read -r node; do
    [[ -n "$node" ]] || continue
    if docker exec "$node" mkdir -p "$certs_dir" 2>/dev/null &&
       docker exec "$node" sh -c "cat > ${certs_dir}/hosts.toml <<'TOML'
# Written by k8s-lab/scripts/registry.sh (FR-019).
#
# The key below is the address that appears in pod specs. The mirror it points
# at is the address a node container can actually reach — the registry's name
# on the shared docker network. These are different strings for the same
# registry, and conflating them is the standard way this breaks.
[host.\"http://${LAB_REGISTRY_NODE_ADDR}\"]
  capabilities = [\"pull\", \"resolve\"]
  skip_verify = true
TOML" 2>/dev/null; then
      configured=$(( configured + 1 ))
    else
      failed=$(( failed + 1 ))
      log_context "node ${node}: could not write ${certs_dir}/hosts.toml"
    fi
  done <<< "$nodes"

  if (( failed == 0 )); then
    log_pass "containerd mirror configured on ${configured} node(s)" "${certs_dir}/hosts.toml"
  else
    log_fail "containerd mirror failed on ${failed} node(s)"
  fi

  # --- 5. Advertise the registry in-cluster, the documented kind convention.
  #        This is how a reader of the cluster learns the registry exists.
  if kubectl --context "${LAB_KUBECONTEXT}" apply -f - >/dev/null 2>&1 <<YAML
apiVersion: v1
kind: ConfigMap
metadata:
  name: local-registry-hosting
  namespace: kube-public
data:
  localRegistryHosting.v1: |
    host: "${LAB_REGISTRY_HOST_ADDR}"
    hostFromClusterNetwork: "${LAB_REGISTRY_NODE_ADDR}"
    help: "k8s-lab/docs/registry.md"
YAML
  then
    log_pass "registry advertised in kube-public" "local-registry-hosting ConfigMap"
  else
    log_fail "could not advertise the registry in kube-public"
  fi

  log_summary
}

# ---------------------------------------------------------------------------
# status (T029) — proven by an executed pull, not by inspection.
# ---------------------------------------------------------------------------
cmd_status() {
  (( QUIET )) || log_suite "registry status"

  if ! registry_running; then
    log_fail "registry container '${REGISTRY_NAME}' is not running" "docker inspect"
    log_summary; return 1
  fi
  log_pass "registry container running" "docker inspect ${REGISTRY_NAME}"

  # Address (1).
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "http://${LAB_REGISTRY_HOST_ADDR}/v2/" 2>/dev/null || echo 000)"
  if [[ "$code" == "200" ]]; then
    log_pass "reachable from the workstation" "GET http://${LAB_REGISTRY_HOST_ADDR}/v2/ -> 200"
  else
    log_fail "not reachable from the workstation" "GET /v2/ -> ${code}"
  fi

  printf '\nCatalogue: '
  curl -s --max-time 10 "http://${LAB_REGISTRY_HOST_ADDR}/v2/_catalog" 2>/dev/null || printf '(unavailable)'
  printf '\n\n'

  # THE check: the cluster must actually pull from it. Everything above is
  # inspection; only this is evidence. A registry that answers /v2/ on the
  # workstation and cannot be pulled from by a node is the exact FR-019
  # failure, and it looks perfectly healthy until a pod tries.
  local probe_src="${JAVA_RUNTIME_IMAGE}"
  local probe_ref="${LAB_REGISTRY_HOST_ADDR}/hydra-lab/registry-probe:v1"

  if ! docker image inspect "$probe_src" >/dev/null 2>&1; then
    docker pull "$probe_src" >/dev/null 2>&1 || {
      log_fail "could not obtain a probe image to test the registry with" "docker pull ${probe_src}"
      log_summary; return 1
    }
  fi
  docker tag "$probe_src" "$probe_ref" >/dev/null 2>&1
  if ! docker push "$probe_ref" >/dev/null 2>&1; then
    log_fail "could not push the probe image" "docker push ${probe_ref}"
    log_summary; return 1
  fi
  log_pass "probe image pushed" "${probe_ref}"

  local probe_pod="registry-probe-$$"
  kubectl --context "${LAB_KUBECONTEXT}" -n kube-public delete pod "$probe_pod" --ignore-not-found >/dev/null 2>&1
  kubectl --context "${LAB_KUBECONTEXT}" -n kube-public run "$probe_pod" \
    --image="$probe_ref" --image-pull-policy=Always --restart=Never \
    --command -- /bin/true >/dev/null 2>&1

  if wait_for_output "cluster pulls from the lab registry" 180 "Succeeded" \
       bash -c "kubectl --context '${LAB_KUBECONTEXT}' -n kube-public get pod '${probe_pod}' -o jsonpath='{.status.phase}' 2>/dev/null"; then
    log_pass "cluster pulled an image from the lab registry" "executed pull, not an inspection"
  else
    log_fail "cluster could not pull from the lab registry"
    log_context "$(kubectl --context "${LAB_KUBECONTEXT}" -n kube-public describe pod "$probe_pod" 2>&1 | tail -25)"
    log_context "Most likely: the containerd mirror is missing on one or more nodes. See the address map at the top of registry.sh."
  fi
  kubectl --context "${LAB_KUBECONTEXT}" -n kube-public delete pod "$probe_pod" --force --grace-period=0 >/dev/null 2>&1 || true

  log_summary
}

# ---------------------------------------------------------------------------
# load — the direct `kind load` fallback (T030, FR-020).
#
# This is a FALLBACK, never the primary path. The registry is the primary path
# because it is what a real cluster does: an image is published and pulled, and
# the pull is a step that can fail and be diagnosed. `kind load` side-loads
# straight into each node's image store, which works and teaches nothing —
# and silently diverges from production, where no such mechanism exists.
#
# It is here because FR-020 asks for a documented fallback for the case where
# the registry cannot be reached at all, which on a locked-down workstation is
# a real possibility.
# ---------------------------------------------------------------------------
cmd_load() {
  log_suite "registry load (FALLBACK PATH)"
  local image="${2:-}"
  [[ -n "$image" ]] || { log_error "usage: registry.sh load <image:tag>"; return 2; }

  printf '%s\n' "NOTE: 'kind load' is the documented fallback (FR-020), not the primary path."
  printf '%s\n' "      It side-loads into each node's image store, bypassing the pull entirely."
  printf '%s\n' "      Nothing about this path resembles how a real cluster obtains an image."
  printf '%s\n' "      Prefer: make image-publish"
  printf '\n'

  if kind load docker-image "$image" --name "${LAB_CLUSTER}"; then
    log_pass "image side-loaded onto every node" "kind load docker-image ${image}"
    log_info "Set imagePullPolicy: IfNotPresent for this image, or the kubelet will try to pull anyway."
  else
    log_fail "kind load failed for ${image}"
  fi
  log_summary
}

case "${1:-status}" in
  create) cmd_create ;;
  status) cmd_status ;;
  load)   cmd_load "$@" ;;
  *) log_error "usage: registry.sh {create|status|load <image>}"; exit 2 ;;
esac
