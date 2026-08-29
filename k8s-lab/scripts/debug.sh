#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# debug.sh — `make debug` (FR-089).
#
# The guided diagnosis entry point. `make dump` prints everything; this asks the
# questions in the order that actually narrows a fault, and stops at the first
# one that answers.
#
# The order is deliberate: each check is a prerequisite of the next, so the
# FIRST failure is the one worth fixing. Reporting all of them at once is what
# `make dump` is for, and it is the wrong tool when you want to know where to
# start.
# ---------------------------------------------------------------------------
set -uo pipefail

LAB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${LAB_ROOT}/scripts/lib/versions.sh"
source "${LAB_ROOT}/scripts/lib/log.sh"

K="kubectl --context ${LAB_KUBECONTEXT}"

verdict() {   # verdict <symptom> <what to do>
  printf '\n'
  printf '  ┌─────────────────────────────────────────────────────────────┐\n'
  printf '  │ FIRST THING TO FIX                                          │\n'
  printf '  └─────────────────────────────────────────────────────────────┘\n'
  printf '  %s\n\n' "$1"
  shift
  local step
  for step in "$@"; do printf '    %s\n' "$step"; done
  printf '\n'
  exit 1
}

printf 'Guided diagnosis. Stops at the first thing that is actually wrong.\n'

# --- 1. Does the cluster exist and answer? --------------------------------
log_step "1/8  cluster API"
if ! command -v kind >/dev/null 2>&1; then
  verdict "kind is not installed." "make doctor"
fi
if ! kind get clusters 2>/dev/null | grep -qx "${LAB_CLUSTER}"; then
  verdict "The cluster '${LAB_CLUSTER}' does not exist." "make setup"
fi
if ! $K cluster-info >/dev/null 2>&1; then
  verdict "The cluster exists but its API does not answer." \
    "docker ps --filter name=${LAB_CLUSTER}" \
    "The container runtime may be stopped, or the control-plane container may have died." \
    "make cluster-status"
fi
log_pass "cluster API answers" "kubectl cluster-info"

# --- 2. Is there a CNI? ----------------------------------------------------
log_step "2/8  networking"
not_ready="$($K get nodes --no-headers 2>/dev/null | grep -c 'NotReady' || true)"
if [[ "${not_ready:-0}" != "0" ]]; then
  verdict "${not_ready} node(s) are NotReady." \
    "With disableDefaultCNI, nodes stay NotReady until Cilium runs. That is expected between" \
    "'cluster-create' and the 'cilium' checkpoint — and a fault at any other time." \
    "kubectl -n kube-system get pods -l k8s-app=cilium" \
    "make net-status"
fi
envoy_ready="$($K -n kube-system get ds cilium-envoy -o jsonpath='{.status.numberReady}' 2>/dev/null || echo 0)"
if [[ "${envoy_ready:-0}" == "0" ]]; then
  verdict "Cilium's Envoy is not running on any node." \
    "The Gateway cannot serve a single request without it, whatever the Gateway's status says." \
    "kubectl -n kube-system logs -l k8s-app=cilium-envoy --tail=40" \
    "A malformed bootstrap config shows up here as: no such field: 'Error'"
fi
log_pass "CNI and Envoy running" "${envoy_ready} Envoy pod(s) Ready"

# --- 3. Datastores ---------------------------------------------------------
log_step "3/8  datastores"
for sts in postgres redis; do
  ready="$($K -n "${NS_DATA}" get statefulset "$sts" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)"
  if [[ "${ready:-0}" != "1" ]]; then
    verdict "${sts} is not Ready." \
      "kubectl -n ${NS_DATA} describe statefulset ${sts}" \
      "kubectl -n ${NS_DATA} logs statefulset/${sts} --tail=40" \
      "A Pending pod here is usually the PVC: kubectl -n ${NS_DATA} get pvc"
  fi
done
log_pass "postgres and redis Ready" "kubectl get statefulset"

# --- 4. Migration and fixture ---------------------------------------------
log_step "4/8  schema and fixture"
for job in hydra-migrate-auth hydra-migrate-order hydra-fixture; do
  if $K -n "${NS_APP}" get job "$job" >/dev/null 2>&1; then
    complete="$($K -n "${NS_APP}" get job "$job" \
      -o jsonpath='{.status.conditions[?(@.type=="Complete")].status}' 2>/dev/null)"
    if [[ "$complete" != "True" ]]; then
      verdict "Job ${job} has not completed." \
        "kubectl -n ${NS_APP} logs job/${job} --tail=60" \
        "No replica should be serving traffic until it has (FR-052)." \
        "If it is the fixture: a seed that applies and cannot sign in is a FAILED seed (D7)."
    fi
  fi
done
log_pass "migration and fixture Jobs complete" "kubectl get jobs"

# --- 5. Application pods ---------------------------------------------------
log_step "5/8  application pods"
for d in auth-service order-service; do
  desired="$($K -n "${NS_APP}" get deploy "$d" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 0)"
  ready="$($K -n "${NS_APP}" get deploy "$d" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)"
  if [[ "${ready:-0}" != "${desired:-0}" ]]; then
    printf '\n%s\n' "$($K -n "${NS_APP}" get pods -l "app.kubernetes.io/name=${d}" -o wide 2>&1)"
    printf '\n%s\n' "$($K -n "${NS_APP}" describe pods -l "app.kubernetes.io/name=${d}" 2>&1 | grep -E 'Unhealthy|Killing|Failed|Back-off' | tail -8)"
    verdict "${d}: ${ready:-0}/${desired:-0} replicas Ready." \
      "kubectl -n ${NS_APP} logs deploy/${d} --tail=60" \
      "Exit 143 means a probe killed it, not that it crashed." \
      "A 401 on a probe means the endpoint is behind the security chain — see docs/known-gaps.md."
  fi
done
log_pass "all application replicas Ready" "kubectl get deploy"

# --- 6. Gateway ------------------------------------------------------------
log_step "6/8  gateway"
programmed="$($K -n "${NS_APP}" get gateway hydra-gateway \
  -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null)"
if [[ "$programmed" != "True" ]]; then
  printf '\n%s\n' "$($K -n "${NS_APP}" get gateway hydra-gateway -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.reason}: {.message}{"\n"}{end}' 2>&1)"
  verdict "The Gateway is not Programmed." \
    "'Waiting for controller' means Cilium's operator has Gateway API support DISABLED." \
    "It probes for the CRDs once, at startup, and does not retry:" \
    "  kubectl -n kube-system logs -l io.cilium/app=operator | grep -i gateway" \
    "The fix is to install the Gateway API CRDs and restart the operator."
fi
nodeport="$($K -n "${NS_APP}" get svc cilium-gateway-hydra-gateway \
  -o jsonpath='{.spec.ports[?(@.port==443)].nodePort}' 2>/dev/null)"
if [[ "$nodeport" != "${GATEWAY_NODEPORT_HTTPS}" ]]; then
  verdict "The Gateway Service is on NodePort ${nodeport:-<none>}, not ${GATEWAY_NODEPORT_HTTPS}." \
    "kind maps host 443 to ${GATEWAY_NODEPORT_HTTPS}. A different port means nothing reaches the gateway." \
    "make platform-status"
fi
log_pass "Gateway Programmed on the declared NodePort" "${nodeport}"

# --- 7. The request path ---------------------------------------------------
log_step "7/8  end-to-end request"
code="$(curl -s -o /dev/null -w '%{http_code}' --cacert "${LAB_CA_CERT}" \
  --max-time 15 "${LAB_BASE_URL}/api/v1/tenant" 2>/dev/null || echo 000)"
case "$code" in
  200) log_pass "the gateway serves application traffic" "GET /api/v1/tenant -> 200" ;;
  000) verdict "No response at all from ${LAB_BASE_URL}." \
        "If TLS failed: the certificate may not cover this hostname." \
        "  openssl x509 -in ${LAB_CA_CERT%/*}/wildcard.crt -noout -text | grep -A1 'Subject Alternative Name'" \
        "Note a *.localhost wildcard is REJECTED by mainstream clients — the SAN must name each tenant." \
        "make gw-test" ;;
  503) verdict "The gateway returned 503 — it could not reach a backend." \
        "This is almost always the NetworkPolicy. Cilium's proxy carries the reserved:ingress" \
        "identity, which a standard NetworkPolicy cannot name; the rule must be a" \
        "CiliumNetworkPolicy with fromEntities: [ingress]." \
        "  kubectl -n ${NS_APP} get ciliumnetworkpolicy" ;;
  404) verdict "The gateway returned 404 — no route matched." \
        "kubectl -n ${NS_APP} get httproute -o wide" \
        "Check the path prefixes: order-service is /api/orders, NOT /api/v1/orders." ;;
  *)   verdict "The gateway returned ${code} for /api/v1/tenant." \
        "kubectl -n ${NS_APP} logs deploy/auth-service --tail=40" ;;
esac

# --- 8. Tenant resolution --------------------------------------------------
log_step "8/8  tenant resolution"
status="$(curl -s --cacert "${LAB_CA_CERT}" --max-time 15 "${LAB_BASE_URL}/api/v1/tenant" 2>/dev/null \
  | jq -r '.status // "unparseable"' 2>/dev/null)"
if [[ "$status" != "recognized" ]]; then
  verdict "The tenant resolved as '${status}' rather than 'recognized'." \
    "'unknown' means the Host header did not arrive intact, or the tenant is not seeded." \
    "  kubectl -n ${NS_DATA} exec statefulset/postgres -- psql -U \$POSTGRES_USER -d auth_db -c 'SELECT url_identifier, status FROM tenants'" \
    "A gateway that rewrites Host takes EVERY tenant offline at once — that is what" \
    "hostile-edge/host-rewrite.yaml exists to prove the suite can detect."
fi
log_pass "tenant resolves from the address" "status=recognized"

printf '\n'
printf 'Nothing is broken that this can find.\n'
printf '\n  If something is still wrong, in order:\n'
printf '    make test         run the suites and let an assertion name it\n'
printf '    make dump         everything, for any of the nine seeded fault classes\n'
printf '    make logs WORKLOAD=auth-service\n\n'
exit 0
