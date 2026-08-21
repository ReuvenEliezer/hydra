#!/usr/bin/env bash
# node-stop drill (FR-097, FR-112).
#
# Expected observable: the scheduling and availability behaviour when a worker
# node disappears — REPORTED, together with an explicit statement of how this
# differs from a real cloud node failure.
#
# That second half is the requirement (FR-112). Stopping a kind node container
# is NOT a cloud node failure, and a drill that implies it is teaches something
# false. The differences are stated below and in the output.
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/lib" && pwd)/drill.sh"

drill_begin "node-stop" \
  "scheduling and availability behaviour is reported, with the cloud difference stated" || { log_summary; exit 1; }

worker="$($K get nodes -l '!node-role.kubernetes.io/control-plane' \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
[[ -n "$worker" ]] || { log_fail "no worker node found"; log_summary; exit 1; }

before_ready="$($K -n "${NS_APP}" get deploy auth-service -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)"
on_node="$($K -n "${NS_APP}" get pods -o wide --no-headers 2>/dev/null | awk -v n="$worker" '$7==n' | wc -l | tr -d ' ')"
log_info "stopping ${worker}, which currently hosts ${on_node} application pod(s)"

load_out="$(mktemp)"
"${LAB_ROOT}/tests/failure/lib/client-load.sh" 90 4 > "$load_out" &
load_pid=$!

docker stop "$worker" >/dev/null 2>&1
log_pass "trigger: worker node container stopped" "docker stop ${worker}"

if wait_for "the node is observed NotReady" 300 \
     bash -c "$K get node $worker --no-headers 2>/dev/null | grep -q NotReady"; then
  log_pass "the control plane observed the node as NotReady" "kubectl get nodes"
else
  log_fail "the node was never marked NotReady within 300s"
fi

# What is REPORTED rather than asserted: this is an observation drill. Asserting
# a recovery time would be asserting a property of kind's networking, not of the
# workload.
printf '\n--- observed behaviour ---\n'
$K get nodes 2>&1 | sed 's/^/  /'
printf '\n'
$K -n "${NS_APP}" get pods -o wide 2>&1 | sed 's/^/  /'
printf '\n'

wait "$load_pid" 2>/dev/null || true
result="$(cat "$load_out")"; rm -f "$load_out"
log_info "client during the outage: ${result}"
rate="$(printf '%s' "$result" | sed -n 's/.*rate=\([0-9.]*\).*/\1/p')"
log_info "Observed success rate is REPORTED, not asserted: how much a client loses depends on"
log_info "how many replicas were on that node, which is a scheduling accident, not a property."

cat <<'DIFFERENCES'

  ─── HOW THIS DIFFERS FROM A REAL CLOUD NODE FAILURE (FR-112) ────────────

  Do not read this drill as a simulation of an instance dying. It is not.

  1. NO NODE REPLACEMENT. A managed node group notices an unhealthy instance
     and provisions a new one. Nothing does that here, so capacity is
     permanently reduced until the container is started again. That single
     difference changes the entire recovery story.

  2. STORAGE FOLLOWS THE NODE. kind's default StorageClass is a hostPath
     provisioner: a PVC bound on this node is simply gone while it is down. A
     cloud volume detaches and re-attaches elsewhere. Any stateful workload
     scheduled here would behave completely differently in production.

  3. THE FAILURE IS CLEAN. `docker stop` is an orderly shutdown of a container
     on the same kernel. Real node failures are messier — a hung kubelet, a
     partitioned network, an instance that answers ARP and nothing else — and
     those take longer to detect and produce different symptoms.

  4. NO ZONE, NO RACK, NO BLAST RADIUS. There is one physical machine. Nothing
     here can demonstrate zone-level failure, correlated failure, or the
     topology constraints that exist to survive them.

  5. DETECTION TIMING IS NOT PRODUCTION TIMING. Node-monitor grace periods and
     eviction timeouts are tuned for real networks. Whatever this drill
     measures is a property of a laptop, not a number to plan against.

  ─────────────────────────────────────────────────────────────────────────

DIFFERENCES

drill_restore "start the worker node again" docker start "$worker"

# Node Ready is a stronger condition than the container running, so it is
# waited on explicitly.
wait_for "the node returns to Ready" 300 \
  bash -c "$K get node $worker --no-headers 2>/dev/null | awk '{print \$2}' | grep -qx Ready" \
  && log_pass "the node returned to Ready" "kubectl get nodes" \
  || log_fail "the node did not return to Ready"

drill_end
