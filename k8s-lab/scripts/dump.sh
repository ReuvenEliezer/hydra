#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# dump.sh — `make dump` (FR-090, SC-018).
#
# The obligation is specific and higher than "print some kubectl output": for
# any of the nine seeded fault classes — scheduling, image, readiness, routing,
# DNS, network policy, autoscaling, datastore, cache — a reader must be able to
# name the failing component from this output *alone*, without running a second
# command. Every section below exists because one of those classes is invisible
# without it, and the section headers say which.
#
# It never fails: a diagnostic that refuses to run when something is broken is
# useless exactly when it is needed. Sections that cannot be collected say so
# and the dump continues.
# ---------------------------------------------------------------------------
set -uo pipefail

LAB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${LAB_ROOT}/scripts/lib/versions.sh"

OUT_FILE=""
[[ "${1:-}" == "--to-file" ]] && {
  mkdir -p "${LAB_RESULTS_DIR}/dumps"
  OUT_FILE="${LAB_RESULTS_DIR}/dumps/dump-$(date +%Y%m%dT%H%M%S).txt"
  exec > >(tee "$OUT_FILE") 2>&1
}

section() { printf '\n\n========== %s ==========\n' "$*"; }
run()     { printf '\n$ %s\n' "$*"; "$@" 2>&1 || printf '(command failed — recorded and continuing)\n'; }

printf 'k8s-lab diagnostic dump — %s\n' "$(date)"
printf 'cluster: %s   context: %s\n' "$LAB_CLUSTER" "$LAB_KUBECONTEXT"

section "0. Reachability — is there an API server at all?"
if ! kubectl cluster-info >/dev/null 2>&1; then
  cat <<'NOAPI'

The cluster API is not reachable. Everything below would be empty, so it is
skipped. In order of likelihood:

  1. The cluster does not exist       -> make cluster-create
  2. The container runtime is down    -> make doctor
  3. The kubeconfig context is wrong  -> kubectl config get-contexts

NOAPI
  run docker ps --filter "name=${LAB_CLUSTER}" --format 'table {{.Names}}\t{{.Status}}'
  run kubectl config current-context
  exit 0
fi

section "1. Nodes — scheduling faults, node-stop drill"
run kubectl get nodes -o wide
run kubectl describe nodes
printf '\n-- allocatable vs requested (why a pod may be Pending) --\n'
kubectl describe nodes 2>/dev/null | grep -A 8 'Allocated resources' || true

section "2. Pods, cluster-wide — image, readiness, scheduling faults"
run kubectl get pods -A -o wide
printf '\n-- pods that are not Running (this is usually the answer) --\n'
run kubectl get pods -A --field-selector=status.phase!=Running -o wide
printf '\n-- containers not ready, with their reason --\n'
kubectl get pods -A -o json 2>/dev/null | jq -r '
  .items[]
  | . as $p
  | ($p.status.containerStatuses // [])[]
  | select(.ready == false)
  | "\($p.metadata.namespace)/\($p.metadata.name)  container=\(.name)  ready=false  restarts=\(.restartCount)  state=\(.state | keys[0])  reason=\((.state | to_entries[0].value.reason) // "-")  message=\((.state | to_entries[0].value.message) // "-")"
' || printf '(jq unavailable or no such containers)\n'

section "3. Deployments, StatefulSets, Jobs — rollout and migration faults"
run kubectl get deploy,statefulset,daemonset,job -A -o wide
printf '\n-- deployments whose available replicas are below desired --\n'
kubectl get deploy -A -o json 2>/dev/null | jq -r '
  .items[] | select((.status.availableReplicas // 0) < (.spec.replicas // 1))
  | "\(.metadata.namespace)/\(.metadata.name): \(.status.availableReplicas // 0)/\(.spec.replicas) available"' || true

section "4. Services and endpoints — routing and DNS faults"
run kubectl get svc -A -o wide
printf '\n-- Services with NO endpoints (a Service with no backends looks healthy and serves nothing) --\n'
kubectl get endpointslice -A -o json 2>/dev/null | jq -r '
  .items[] | select((.endpoints // []) | length == 0)
  | "\(.metadata.namespace)/\(.metadata.labels["kubernetes.io/service-name"] // .metadata.name): 0 endpoints"' || true
run kubectl -n kube-system get pods -l k8s-app=kube-dns -o wide

section "5. Gateway API — routing faults"
run kubectl get gatewayclass -o wide
run kubectl get gateway -A -o wide
run kubectl get httproute -A -o wide
printf '\n-- Gateway conditions (Programmed / Accepted / ResolvedRefs) --\n'
kubectl get gateway -A -o json 2>/dev/null | jq -r '
  .items[] | "\(.metadata.namespace)/\(.metadata.name):",
  ((.status.conditions // [])[] | "    \(.type)=\(.status)  \(.reason)  \(.message)")' || true
printf '\n-- HTTPRoute parent statuses (an unaccepted route routes nothing) --\n'
kubectl get httproute -A -o json 2>/dev/null | jq -r '
  .items[] | "\(.metadata.namespace)/\(.metadata.name):",
  ((.status.parents // [])[] | "    parent=\(.parentRef.name) controller=\(.controllerName)",
    ((.conditions // [])[] | "      \(.type)=\(.status)  \(.reason)  \(.message)"))' || true
printf '\n-- zero Ingress objects is the expected state (FR-026) --\n'
run kubectl get ingress -A

section "6. Network policy — denied-traffic faults"
run kubectl get networkpolicy -A
run kubectl get ciliumnetworkpolicy,ciliumclusterwidenetworkpolicy -A

section "7. Cilium — CNI, kube-proxy replacement, L7 datapath"
run kubectl -n kube-system get pods -l k8s-app=cilium -o wide
run kubectl -n kube-system get pods -l k8s-app=cilium-envoy -o wide
run kubectl -n kube-system get daemonset -o wide
cilium_pod="$(kubectl -n kube-system get pods -l k8s-app=cilium -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
if [[ -n "$cilium_pod" ]]; then
  run kubectl -n kube-system exec "$cilium_pod" -c cilium-agent -- cilium-dbg status --brief
  run kubectl -n kube-system exec "$cilium_pod" -c cilium-agent -- cilium-dbg status
  printf '\n-- kube-proxy replacement and service backends --\n'
  run kubectl -n kube-system exec "$cilium_pod" -c cilium-agent -- cilium-dbg service list
  printf '\n-- endpoint policy enforcement state --\n'
  run kubectl -n kube-system exec "$cilium_pod" -c cilium-agent -- cilium-dbg endpoint list
else
  printf '\nNo Cilium agent pod found. With disableDefaultCNI:true that means the nodes have no\n'
  printf 'CNI at all, which is why everything else is Pending. Start here.\n'
fi

section "8. Autoscaling — scaling faults"
run kubectl get hpa -A -o wide
run kubectl get pdb -A
printf '\n-- HPA conditions (ScalingActive=False usually means no metrics, not no load) --\n'
kubectl get hpa -A -o json 2>/dev/null | jq -r '
  .items[] | "\(.metadata.namespace)/\(.metadata.name):",
  ((.status.conditions // [])[] | "    \(.type)=\(.status)  \(.reason)  \(.message)")' || true

section "9. Datastore and cache — Postgres and Redis faults"
run kubectl -n "${NS_DATA}" get pods,svc,pvc,statefulset -o wide
run kubectl get pv
printf '\n-- Postgres readiness (pg_isready is the probe, so run the probe) --\n'
kubectl -n "${NS_DATA}" exec statefulset/postgres -- pg_isready -U postgres 2>&1 || printf '(postgres not reachable)\n'
printf '\n-- Redis readiness --\n'
kubectl -n "${NS_DATA}" exec statefulset/redis -- redis-cli ping 2>&1 || printf '(redis not reachable)\n'

section "10. Observability plane"
run kubectl -n "${NS_OBS}" get pods,svc -o wide

section "11. Delivery plane — Argo CD sync/health"
run kubectl -n "${NS_DELIVERY}" get pods,svc -o wide
run kubectl -n "${NS_DELIVERY}" get applications.argoproj.io -o wide
kubectl -n "${NS_DELIVERY}" get applications.argoproj.io -o json 2>/dev/null | jq -r '
  .items[] | "\(.metadata.name): sync=\(.status.sync.status // "?") health=\(.status.health.status // "?") revision=\(.status.sync.revision // "?" | .[0:8])"' || true

section "12. Events — the chronological account"
run kubectl get events -A --sort-by=.lastTimestamp
printf '\n-- warnings only, most recent last --\n'
kubectl get events -A --field-selector type=Warning --sort-by=.lastTimestamp 2>/dev/null | tail -40 || true

section "13. Recent logs from application workloads"
for wl in auth-service order-service; do
  printf '\n--- %s (last 40 lines, previous container if it restarted) ---\n' "$wl"
  kubectl -n "${NS_APP}" logs "deploy/${wl}" --tail=40 --all-containers 2>&1 | tail -40 || true
  kubectl -n "${NS_APP}" logs "deploy/${wl}" --tail=20 --previous 2>/dev/null | tail -20 || true
done

section "14. Lab-side state"
run docker ps --filter "name=${LAB_CLUSTER}" --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
run docker ps --filter "name=${REGISTRY_NAME}" --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
printf '\n-- images published to the lab registry --\n'
curl -s "http://${LAB_REGISTRY_HOST_ADDR}/v2/_catalog" 2>/dev/null || printf '(registry not reachable from the workstation)\n'
printf '\n-- TLS material --\n'
if [[ -f "$LAB_CA_CERT" ]]; then
  printf 'CA:   %s\n' "$LAB_CA_CERT"
  openssl x509 -in "$LAB_CA_CERT" -noout -subject -dates 2>&1 || true
  [[ -f "${LAB_CERT_DIR}/wildcard.crt" ]] && openssl x509 -in "${LAB_CERT_DIR}/wildcard.crt" -noout -subject -dates 2>&1
else
  printf '(no TLS material generated yet — run make setup)\n'
fi

printf '\n\n========== end of dump ==========\n'
[[ -n "$OUT_FILE" ]] && printf 'written to %s\n' "$OUT_FILE"
exit 0
