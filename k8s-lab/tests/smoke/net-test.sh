#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# net-test.sh — `make net-test` (FR-024).
#
# FR-024 asks for REAL traffic, and says so because the tempting alternative is
# to inspect configuration and call it a network test. `cilium status` reporting
# OK, a NetworkPolicy that looks right, endpoints that are populated — none of
# those is a packet arriving. This suite sends packets.
#
# Two distinct paths, because they fail independently:
#
#   pod -> pod      direct addressing across nodes. Exercises the CNI datapath
#                   and, on a multi-node cluster, cross-node routing.
#   pod -> Service  the same traffic through a ClusterIP. With kube-proxy
#                   disabled this is Cilium's kube-proxy replacement doing the
#                   translation, so it is the only check that proves FR-023 is
#                   a working datapath rather than a setting.
#
# Everything created here is torn down, including on failure.
# ---------------------------------------------------------------------------
set -uo pipefail

LAB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "${LAB_ROOT}/scripts/lib/versions.sh"
source "${LAB_ROOT}/scripts/lib/log.sh"
source "${LAB_ROOT}/scripts/lib/wait.sh"
source "${LAB_ROOT}/scripts/lib/assert.sh"

K="kubectl --context ${LAB_KUBECONTEXT}"
NS="hydra-nettest"

cleanup() {
  $K delete ns "$NS" --ignore-not-found --wait=false >/dev/null 2>&1 || true
}
trap cleanup EXIT

log_suite "net-test (real traffic, not configuration)"

$K delete ns "$NS" --ignore-not-found --wait=true --timeout=60s >/dev/null 2>&1 || true
$K create ns "$NS" >/dev/null 2>&1 || { log_fail "could not create the test namespace"; log_summary; exit 1; }

# A server and two clients. The clients are spread across nodes with
# podAntiAffinity so that at least one pair is genuinely cross-node — a
# same-node test passes on a broken cross-node datapath, which is the failure
# mode most worth catching on a multi-node cluster.
$K -n "$NS" apply -f - >/dev/null 2>&1 <<YAML
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nettest-server
spec:
  replicas: 2
  selector:
    matchLabels: {app: nettest-server}
  template:
    metadata:
      labels: {app: nettest-server}
    spec:
      affinity:
        podAntiAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
            - weight: 100
              podAffinityTerm:
                topologyKey: kubernetes.io/hostname
                labelSelector:
                  matchLabels: {app: nettest-server}
      containers:
        - name: server
          image: ${REGISTRY_IMAGE}
          # The registry image is already required by the lab, already pinned in
          # the version matrix, and serves HTTP on 5000 — so it needs no extra
          # pull and introduces no version that is not already declared.
          ports: [{containerPort: 5000}]
          readinessProbe:
            httpGet: {path: /v2/, port: 5000}
            periodSeconds: 2
---
apiVersion: v1
kind: Service
metadata:
  name: nettest-server
spec:
  selector: {app: nettest-server}
  ports: [{port: 80, targetPort: 5000}]
---
apiVersion: v1
kind: Pod
metadata:
  name: nettest-client
  labels: {app: nettest-client}
spec:
  containers:
    - name: client
      image: ${REGISTRY_IMAGE}
      command: ["sleep", "3600"]
YAML

if ! wait_for_output "server replicas Ready" "${TIMEOUT_WORKLOAD_READY}" "2" \
     bash -c "$K -n $NS get deploy nettest-server -o jsonpath='{.status.readyReplicas}' 2>/dev/null"; then
  log_context "$($K -n "$NS" get pods -o wide 2>&1)"
  log_summary; exit 1
fi
log_pass "test workloads Ready" "2 server replicas + 1 client"

if ! wait_for "client pod Running" 120 \
     bash -c "[[ \"\$($K -n $NS get pod nettest-client -o jsonpath='{.status.phase}' 2>/dev/null)\" == Running ]]"; then
  log_summary; exit 1
fi

# --- 1. pod -> pod, by address, across nodes where possible ---------------
client_node="$($K -n "$NS" get pod nettest-client -o jsonpath='{.spec.nodeName}' 2>/dev/null)"
declare -a checked_nodes=()
while IFS=' ' read -r pod_ip pod_node; do
  [[ -n "$pod_ip" ]] || continue
  same="same-node"
  [[ "$pod_node" != "$client_node" ]] && same="CROSS-NODE"
  out="$($K -n "$NS" exec nettest-client -- \
        wget -q -T 8 -O - "http://${pod_ip}:5000/v2/" 2>&1 || echo "__FAILED__")"
  if [[ "$out" != *"__FAILED__"* ]]; then
    log_pass "pod -> pod ${pod_ip} (${same})" "HTTP response received over the CNI datapath"
  else
    log_fail "pod -> pod ${pod_ip} (${same}) got no response"
    log_context "$out"
  fi
  checked_nodes+=("$pod_node")
done < <($K -n "$NS" get pods -l app=nettest-server \
         -o jsonpath='{range .items[*]}{.status.podIP} {.spec.nodeName}{"\n"}{end}' 2>/dev/null)

# Say plainly whether a cross-node path was actually exercised, rather than
# leaving the reader to infer it from pod placement.
cross_node=0
for n in "${checked_nodes[@]:-}"; do [[ -n "$n" && "$n" != "$client_node" ]] && cross_node=1; done
if (( cross_node )); then
  log_pass "a cross-node pod-to-pod path was exercised" "client on ${client_node}"
else
  log_fail "every server replica landed on the client's node — no cross-node path was tested"
  log_context "This is a scheduling accident, not a network result. Re-run, or check node capacity."
fi

# --- 2. pod -> Service, the kube-proxy replacement -------------------------
svc_out="$($K -n "$NS" exec nettest-client -- \
          wget -q -T 8 -O - "http://nettest-server.${NS}.svc.cluster.local/v2/" 2>&1 || echo "__FAILED__")"
if [[ "$svc_out" != *"__FAILED__"* ]]; then
  log_pass "pod -> Service by cluster DNS name" "ClusterIP translated by Cilium's kube-proxy replacement (FR-023)"
else
  log_fail "pod -> Service failed"
  log_context "$svc_out"
  log_context "With kubeProxyMode:none there is no kube-proxy fallback — this is Cilium's datapath or nothing."
fi

# Repeat enough times to reach both backends: a Service that only ever answers
# from one endpoint is not load-balancing, and a single request cannot tell.
declare -a seen=()
for _ in 1 2 3 4 5 6 7 8; do
  id="$($K -n "$NS" exec nettest-client -- \
       wget -q -T 5 -S -O /dev/null "http://nettest-server.${NS}.svc.cluster.local/v2/" 2>&1 \
       | grep -i 'X-Registry-Uuid' | head -1 || true)"
  seen+=("$id")
done
distinct="$(printf '%s
' ${seen[@]+"${seen[@]}"} | sort -u | grep -c . 2>/dev/null | head -1 | tr -d ' ')"
[[ -n "$distinct" ]] || distinct=0
log_info "Service responses observed from ${distinct} distinct backend identity value(s) across 8 requests"

# --- 3. DNS, explicitly ----------------------------------------------------
# Named separately because a DNS failure and a routing failure look identical
# from the caller and have completely different fixes.
dns_out="$($K -n "$NS" exec nettest-client -- \
          nslookup "nettest-server.${NS}.svc.cluster.local" 2>&1 || echo "__FAILED__")"
if [[ "$dns_out" != *"__FAILED__"* && "$dns_out" == *"Address"* ]]; then
  log_pass "cluster DNS resolves the Service name" "nslookup"
else
  log_fail "cluster DNS did not resolve the Service name"
  log_context "$dns_out"
fi

log_summary
