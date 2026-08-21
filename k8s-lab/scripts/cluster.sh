#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# cluster.sh — cluster lifecycle (FR-010..FR-013).
#
#   create    idempotent; converges or fails clearly, never half-adopts (T026)
#   delete    removes the cluster and its context
#   recreate  delete then create
#   status    what exists
#   health    whether it works
#
# `status` and `health` are genuinely different questions and FR-012 requires
# them kept apart. `kubectl get nodes` showing three nodes is status. Whether
# the API answers, whether every node is Ready, whether the scheduler will
# actually place a pod — that is health, and a cluster can have perfect status
# and no health at all (three NotReady nodes is exactly that state, and it is
# the state this cluster is *supposed* to be in between `create` and the Cilium
# checkpoint).
# ---------------------------------------------------------------------------
set -uo pipefail

LAB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${LAB_ROOT}/scripts/lib/versions.sh"
source "${LAB_ROOT}/scripts/lib/log.sh"
source "${LAB_ROOT}/scripts/lib/wait.sh"

QUIET=0
[[ "${2:-}" == "--quiet" ]] && QUIET=1
say() { (( QUIET )) || printf '%s\n' "$*"; }

require_kind() {
  command -v kind >/dev/null 2>&1 || {
    log_error "kind is not installed. Run 'make doctor' — it will name this and tell you how to fix it."
    exit 1
  }
}

cluster_exists() { kind get clusters 2>/dev/null | grep -qx "${LAB_CLUSTER}"; }

# ---------------------------------------------------------------------------
# Render the topology template. The worker count is a matrix value, so the
# rendered config is produced here rather than committed — a committed config
# with two literal workers plus a matrix that says something else is exactly
# the divergence versions.env exists to prevent.
# ---------------------------------------------------------------------------
render_cluster_config() {
  local out="$1"
  local template="${LAB_ROOT}/cluster/kind-cluster.yaml"

  [[ -r "$template" ]] || { log_error "missing topology template: ${template}"; return 1; }
  [[ "${KIND_WORKER_COUNT}" =~ ^[0-9]+$ ]] || { log_error "KIND_WORKER_COUNT is not a number"; return 1; }
  # FR-065 spreads workloads across workers and FR-069 needs real multi-instance
  # behaviour, so a single-worker cluster cannot demonstrate what the lab exists
  # to demonstrate. Refuse rather than produce a cluster whose results would be
  # quietly meaningless.
  (( KIND_WORKER_COUNT >= 2 )) || {
    log_error "KIND_WORKER_COUNT=${KIND_WORKER_COUNT}: topology spread (FR-065) and cross-replica behaviour (FR-069) need at least 2 workers."
    return 1
  }

  # envsubst is not on a stock macOS, so substitution is done with the shell.
  local line rendered=""
  while IFS= read -r line; do
    if [[ "$line" == *"# WORKER_NODES"* ]]; then
      local i
      for (( i = 1; i <= KIND_WORKER_COUNT; i++ )); do
        # EVERY node gets the gitops bind mount, not just the control plane.
        #
        # The first version put extraMounts only on the control-plane entry in
        # the template. The scheduler then placed argocd-repo-server on a
        # worker, and the pod sat in Init forever with:
        #
        #   MountVolume.SetUp failed for volume "gitops-remote":
        #   hostPath type check failed: /gitops-remote is not a directory
        #
        # A hostPath is a promise about EVERY node the pod might land on. Making
        # it true on one node and hoping for the best is a scheduling lottery —
        # and it would have "worked" on any run where the scheduler happened to
        # choose the control plane, which is the worst kind of bug.
        rendered+="  - role: worker
    image: ${KIND_NODE_IMAGE}
    extraMounts:
      - hostPath: ${LAB_GITOPS_REMOTE_DIR}
        containerPath: /gitops-remote
        readOnly: false
"
      done
      continue
    fi
    line="${line//\$\{KIND_CLUSTER_NAME\}/${KIND_CLUSTER_NAME}}"
    line="${line//\$\{KIND_NODE_IMAGE\}/${KIND_NODE_IMAGE}}"
    line="${line//\$\{KIND_WORKER_COUNT\}/${KIND_WORKER_COUNT}}"
    line="${line//\$\{GATEWAY_NODEPORT_HTTPS\}/${GATEWAY_NODEPORT_HTTPS}}"
    line="${line//\$\{GATEWAY_NODEPORT_HTTP\}/${GATEWAY_NODEPORT_HTTP}}"
    line="${line//\$\{LAB_GITOPS_REMOTE_DIR\}/${LAB_GITOPS_REMOTE_DIR}}"
    rendered+="${line}
"
  done < "$template"

  printf '%s' "$rendered" > "$out"

  # An empty render is the dangerous case, not a malformed one: `kind create
  # --config <empty file>` silently falls back to kind's DEFAULTS — one node,
  # default CNI, kube-proxy enabled — which is the exact opposite of the
  # topology this lab requires, and every later checkpoint then fails somewhere
  # else. This guard exists because that is precisely how it failed the first
  # time it was run.
  if [[ ! -s "$out" ]]; then
    log_error "the rendered cluster config is empty (${out})"
    log_error "kind would silently fall back to its defaults: 1 node, default CNI, kube-proxy on."
    return 1
  fi
  local worker_lines
  worker_lines="$(grep -c 'role: worker' "$out" || true)"
  if [[ "$worker_lines" != "${KIND_WORKER_COUNT}" ]]; then
    log_error "rendered ${worker_lines} worker entries, expected ${KIND_WORKER_COUNT}"
    return 1
  fi

  # A rendered config that still contains an unexpanded ${...} would produce a
  # cluster subtly different from the one described. Comments are excluded: the
  # template's own header explains the substitution mechanism and therefore
  # contains the literal `${...}` — the first version of this guard flagged its
  # own documentation and refused to create a cluster.
  local unexpanded
  unexpanded="$(grep -vE '^[[:space:]]*#' "$out" | grep -n '\${' || true)"
  if [[ -n "$unexpanded" ]]; then
    log_error "the rendered cluster config still contains unexpanded variables:"
    printf '%s\n' "$unexpanded" >&2
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# create (T023, T026)
# ---------------------------------------------------------------------------
cmd_create() {
  require_kind
  log_suite "cluster create"

  # --- T026: stale state. Converge or fail with an instruction. Never
  # half-adopt: a cluster that exists but was built from a different topology
  # or a different node image will fail later, in a place that points at the
  # wrong component.
  if cluster_exists; then
    say "A cluster named '${LAB_CLUSTER}' already exists. Checking whether it matches the declared topology."

    local expected_nodes actual_nodes actual_image mismatch=""
    expected_nodes=$(( 1 + KIND_WORKER_COUNT ))
    actual_nodes="$(kubectl --context "${LAB_KUBECONTEXT}" get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')"
    actual_image="$(kubectl --context "${LAB_KUBECONTEXT}" get nodes -o jsonpath='{.items[0].status.nodeInfo.kubeletVersion}' 2>/dev/null || true)"

    [[ "$actual_nodes" == "$expected_nodes" ]] || \
      mismatch+="node count: have ${actual_nodes}, declared ${expected_nodes}
"
    [[ -z "$actual_image" || "${KIND_NODE_IMAGE}" == *"${actual_image}"* ]] || \
      mismatch+="kubelet version: have ${actual_image}, node image declares ${KIND_NODE_IMAGE}
"

    if [[ -n "$mismatch" ]]; then
      log_fail "existing cluster '${LAB_CLUSTER}' does not match the declared topology"
      log_context "$mismatch"
      log_error "Refusing to adopt it. A cluster built from a different topology fails later, somewhere else."
      log_error "Run: make cluster-recreate    (or 'make cleanup' for a full reset)"
      return 1
    fi

    log_pass "existing cluster matches the declared topology" "${actual_nodes} nodes, kubelet ${actual_image}"
    say "Converged on the existing cluster; nothing to create."
  else
    # The extraMount source must exist BEFORE `kind create`. Docker creates a
    # missing bind-mount source itself, owned by root — and the workstation then
    # cannot write the git repository into it.
    mkdir -p "${LAB_GITOPS_REMOTE_DIR}"
    
    local cfg
    # No suffix after the X's: BSD mktemp (macOS) does not substitute X's that
    # are not at the end of the template, so `kind-cluster.XXXXXX.yaml` produces
    # a file named literally that — shared between runs, and a collision waiting
    # to happen. kind does not care about the extension.
    cfg="$(mktemp "${TMPDIR:-/tmp}/kind-cluster-XXXXXX")"
    render_cluster_config "$cfg" || return 1
    say "Rendered topology: 1 control-plane + ${KIND_WORKER_COUNT} workers, image ${KIND_NODE_IMAGE}"
    say "  default CNI disabled, kube-proxy disabled — Cilium supplies both (D4)"

    if ! kind create cluster --config "$cfg" --wait 0s; then
      log_fail "kind create cluster failed"
      log_context "$(docker ps -a --filter "name=${LAB_CLUSTER}" --format '{{.Names}}\t{{.Status}}' 2>&1)"
      rm -f "$cfg"
      return 1
    fi
    # Keep the rendered config next to the run output: reproducing a result
    # later means knowing the exact topology it was produced on.
    mkdir -p "${LAB_RESULTS_DIR}"
    cp "$cfg" "${LAB_RESULTS_DIR}/kind-cluster.rendered.yaml"
    rm -f "$cfg"
    log_pass "kind cluster '${LAB_CLUSTER}' created" "kind create cluster"
  fi

  # --- T023: every expected node must reach Ready before this reports success.
  #
  # With disableDefaultCNI the nodes CANNOT be Ready yet — there is no pod
  # network. So the check here is the one that is actually true at this point:
  # every node is registered and its kubelet is reporting. Readiness is the
  # `cilium` checkpoint's assertion, and claiming it here would be asserting
  # something this checkpoint has not done.
  local expected=$(( 1 + KIND_WORKER_COUNT ))
  if ! wait_for_output "all ${expected} nodes registered with the API server" "${TIMEOUT_NODE_READY}" \
       "$expected" \
       bash -c "kubectl --context '${LAB_KUBECONTEXT}' get nodes --no-headers 2>/dev/null | wc -l | tr -d ' '"; then
    return 1
  fi
  log_pass "all ${expected} nodes registered" "kubectl get nodes"

  local not_ready
  not_ready="$(kubectl --context "${LAB_KUBECONTEXT}" get nodes --no-headers 2>/dev/null | grep -c 'NotReady' || true)"
  if (( not_ready > 0 )); then
    say ""
    say "${not_ready} node(s) are NotReady. That is the expected state right now:"
    say "  disableDefaultCNI is set, so there is no pod network until Cilium is installed."
    say "  The 'cilium' checkpoint is what makes these Ready. This is not a fault."
  fi

  log_summary
}

# ---------------------------------------------------------------------------
# delete / recreate
# ---------------------------------------------------------------------------
cmd_delete() {
  require_kind
  log_suite "cluster delete"
  if ! cluster_exists; then
    log_pass "no cluster '${LAB_CLUSTER}' to delete" "kind get clusters"
    log_summary; return
  fi
  if kind delete cluster --name "${LAB_CLUSTER}"; then
    log_pass "cluster '${LAB_CLUSTER}' deleted" "kind delete cluster"
  else
    log_fail "cluster '${LAB_CLUSTER}' would not delete"
  fi
  log_summary
}

cmd_recreate() { cmd_delete && cmd_create; }

# ---------------------------------------------------------------------------
# status — what exists (FR-012)
# ---------------------------------------------------------------------------
cmd_status() {
  require_kind
  log_suite "cluster status (what exists)"

  if ! cluster_exists; then
    log_fail "cluster '${LAB_CLUSTER}' does not exist" "kind get clusters"
    log_info "Run: make cluster-create"
    log_summary; return 1
  fi
  log_pass "cluster '${LAB_CLUSTER}' exists" "kind get clusters"

  printf '\nNodes:\n'
  kubectl --context "${LAB_KUBECONTEXT}" get nodes -o wide 2>&1 || true

  printf '\nNode containers:\n'
  docker ps --filter "name=${LAB_CLUSTER}-" --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' 2>&1 || true

  printf '\nNamespaces:\n'
  kubectl --context "${LAB_KUBECONTEXT}" get ns 2>&1 || true

  printf '\nWorkloads by namespace:\n'
  kubectl --context "${LAB_KUBECONTEXT}" get deploy,statefulset,daemonset -A 2>&1 | head -30 || true

  log_summary
}


# ---------------------------------------------------------------------------
# registered — what must be true BEFORE a CNI exists (FR-013, FR-014)
#
# This is the `cluster` checkpoint's validation, and it exists because `health`
# cannot be that validation: `health` asserts every node is Ready, and a node
# does not become Ready until a CNI is running — which happens three
# checkpoints later, at `cilium`.
#
# The `cluster` checkpoint was validated with `health --quiet` and therefore
# could NEVER have passed on its own terms. Nothing noticed, because
# checkpoint.sh captured its exit status with `if ! out="$(cmd)"` and recorded
# every checkpoint as PASSED regardless (see scripts/lib/checkpoint.sh). Fixing
# that capture is what made this surface, as:
#
#     FAIL  only 0/3 nodes Ready
#     FAIL  scheduler places and completes a probe pod: ... after 120s
#
# against a cluster that was in exactly the state it should have been in.
#
# So this checks what is genuinely establishable at that point: the cluster
# exists, the API answers, and every declared node has REGISTERED. Node
# readiness is asserted by `platform.sh cilium`, which waits for it explicitly
# and says why, and full `health` runs in `validate.sh` once everything is up.
# ---------------------------------------------------------------------------
cmd_registered() {
  require_kind
  (( QUIET )) || log_suite "cluster registered (pre-CNI)"

  if ! cluster_exists; then
    log_fail "cluster '${LAB_CLUSTER}' does not exist" "kind get clusters"
    log_summary; return 1
  fi
  log_pass "cluster '${LAB_CLUSTER}' exists" "kind get clusters"

  if kubectl --context "${LAB_KUBECONTEXT}" cluster-info >/dev/null 2>&1; then
    log_pass "API server responds" "kubectl cluster-info"
  else
    log_fail "API server does not respond" "kubectl cluster-info"
    log_context "$(docker ps -a --filter "name=${LAB_CLUSTER}-control-plane" --format '{{.Status}}' 2>&1)"
    log_summary; return 1
  fi

  local expected actual
  expected=$(( 1 + KIND_WORKER_COUNT ))
  actual="$(kubectl --context "${LAB_KUBECONTEXT}" get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  if [[ "$actual" == "$expected" ]]; then
    log_pass "${actual} nodes registered" "1 control-plane + ${KIND_WORKER_COUNT} workers"
  else
    log_fail "expected ${expected} nodes registered, found ${actual}"
    log_context "$(kubectl --context "${LAB_KUBECONTEXT}" get nodes 2>&1)"
  fi

  (( QUIET )) || log_info "NotReady here is correct: disableDefaultCNI means no pod network until Cilium."
  log_summary
}

# ---------------------------------------------------------------------------
# health — whether it works (FR-012)
# ---------------------------------------------------------------------------
cmd_health() {
  require_kind
  (( QUIET )) || log_suite "cluster health (whether it works)"

  if ! cluster_exists; then
    log_fail "cluster '${LAB_CLUSTER}' does not exist"
    log_summary; return 1
  fi

  # 1. The API answers.
  if kubectl --context "${LAB_KUBECONTEXT}" cluster-info >/dev/null 2>&1; then
    log_pass "API server responds" "kubectl cluster-info"
  else
    log_fail "API server does not respond" "kubectl cluster-info"
    log_context "$(docker ps -a --filter "name=${LAB_CLUSTER}-control-plane" --format '{{.Status}}' 2>&1)"
    log_summary; return 1
  fi

  # 2. Every declared node exists.
  local expected actual
  expected=$(( 1 + KIND_WORKER_COUNT ))
  actual="$(kubectl --context "${LAB_KUBECONTEXT}" get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  if [[ "$actual" == "$expected" ]]; then
    log_pass "${actual} nodes present" "1 control-plane + ${KIND_WORKER_COUNT} workers"
  else
    log_fail "expected ${expected} nodes, found ${actual}"
  fi

  # 3. Every node is Ready. This is the assertion FR-013 makes, and it can only
  #    pass once a CNI is running — which is correct: a cluster with no pod
  #    network is not healthy, it is half-built.
  local ready total
  ready="$(kubectl --context "${LAB_KUBECONTEXT}" get nodes --no-headers 2>/dev/null | awk '$2=="Ready"' | wc -l | tr -d ' ')"
  total="$actual"
  if [[ "$ready" == "$total" && "$total" != "0" ]]; then
    log_pass "all ${ready} nodes Ready" "kubectl get nodes"
  else
    log_fail "only ${ready}/${total} nodes Ready"
    log_context "$(kubectl --context "${LAB_KUBECONTEXT}" get nodes 2>&1)"
    log_context "If Cilium has not been installed yet this is expected — disableDefaultCNI means no pod network."
  fi

  # 4. Core control-plane components are actually running.
  local cp_not_running
  cp_not_running="$(kubectl --context "${LAB_KUBECONTEXT}" -n kube-system get pods --no-headers 2>/dev/null \
    | awk '$3 != "Running" && $3 != "Completed"' | wc -l | tr -d ' ')"
  if [[ "$cp_not_running" == "0" ]]; then
    log_pass "all kube-system pods Running" "kubectl -n kube-system get pods"
  else
    log_fail "${cp_not_running} kube-system pod(s) not Running"
    log_context "$(kubectl --context "${LAB_KUBECONTEXT}" -n kube-system get pods --no-headers 2>/dev/null | awk '$3 != "Running" && $3 != "Completed"')"
  fi

  # 5. The scheduler will actually place a pod. Nodes reporting Ready and the
  #    scheduler placing work are different claims, and the second is the one
  #    that matters — this is health, not status.
  local probe="lab-health-probe-$$"
  if kubectl --context "${LAB_KUBECONTEXT}" -n default run "$probe" \
       --image="${JAVA_RUNTIME_IMAGE}" --restart=Never --command -- /bin/true >/dev/null 2>&1; then
    if wait_for_output "scheduler places and completes a probe pod" 120 "Succeeded" \
         bash -c "kubectl --context '${LAB_KUBECONTEXT}' -n default get pod '${probe}' -o jsonpath='{.status.phase}' 2>/dev/null"; then
      log_pass "scheduler places and runs a pod" "probe pod reached Succeeded"
    else
      log_fail "scheduler could not run a probe pod"
      log_context "$(kubectl --context "${LAB_KUBECONTEXT}" -n default describe pod "$probe" 2>&1 | tail -20)"
    fi
    # FR-074: no lab workload is left in `default`. The probe is removed
    # whatever happened to it.
    kubectl --context "${LAB_KUBECONTEXT}" -n default delete pod "$probe" --force --grace-period=0 >/dev/null 2>&1 || true
  else
    log_fail "could not create a probe pod" "kubectl run"
  fi

  log_summary
}

case "${1:-status}" in
  create)   cmd_create ;;
  delete)   cmd_delete ;;
  recreate) cmd_recreate ;;
  status)   cmd_status ;;
  health)     cmd_health ;;
  registered) cmd_registered ;;
  *) log_error "usage: cluster.sh {create|delete|recreate|status|registered|health}"; exit 2 ;;
esac
