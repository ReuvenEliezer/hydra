#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# smoke/run.sh — `make test-smoke` (FR-094, plus T074a's two additions).
#
# Every FR-094 check, each backed by an executed command. The rule this suite
# exists to honour: no component is reported healthy without something having
# been run against it (FR-098). "The Deployment exists" is not "the service
# works", and several checks below deliberately do the harder thing.
# ---------------------------------------------------------------------------
set -uo pipefail

LAB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "${LAB_ROOT}/scripts/lib/versions.sh"
source "${LAB_ROOT}/scripts/lib/log.sh"
source "${LAB_ROOT}/scripts/lib/wait.sh"
source "${LAB_ROOT}/scripts/lib/assert.sh"

K="kubectl --context ${LAB_KUBECONTEXT}"
REDUCED="${LAB_REDUCED:-0}"

log_suite "smoke"

# --- 1. Cluster API --------------------------------------------------------
log_section "cluster"
assert_cmd "cluster API responds" $K cluster-info

expected_nodes=$(( 1 + KIND_WORKER_COUNT ))
ready_nodes="$($K get nodes --no-headers 2>/dev/null | awk '$2=="Ready"' | wc -l | tr -d ' ')"
assert_eq "all ${expected_nodes} nodes Ready" "$expected_nodes" "$ready_nodes"

# --- 2. Cilium -------------------------------------------------------------
log_section "networking"
agent_pod="$($K -n kube-system get pods -l k8s-app=cilium -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
if [[ -n "$agent_pod" ]]; then
  brief="$($K -n kube-system exec "$agent_pod" -c cilium-agent -- cilium-dbg status --brief 2>/dev/null | tr -d '\r')"
  assert_eq "cilium datapath healthy" "OK" "$brief"
else
  log_fail "no cilium agent pod found"
fi

envoy_ready="$($K -n kube-system get ds cilium-envoy -o jsonpath='{.status.numberReady}' 2>/dev/null || echo 0)"
envoy_want="$($K -n kube-system get ds cilium-envoy -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null || echo 0)"
assert_eq "Cilium's Envoy Ready on every node" "$envoy_want" "$envoy_ready"

# --- 3. Gateway API --------------------------------------------------------
log_section "gateway"
assert_cmd "Gateway API CRDs installed" $K get crd gateways.gateway.networking.k8s.io
assert_cmd "GatewayClass exists" $K get gatewayclass cilium

programmed="$($K -n "${NS_APP}" get gateway hydra-gateway \
  -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null)"
assert_eq "Gateway Programmed" "True" "$programmed"

routes_total="$($K -n "${NS_APP}" get httproute --no-headers 2>/dev/null | grep -c . 2>/dev/null | head -1 | tr -d ' ')"
[[ -n "$routes_total" ]] || routes_total=0
unaccepted="$($K -n "${NS_APP}" get httproute -o json 2>/dev/null | jq -r '
  .items[] | select([ (.status.parents // [])[] | (.conditions // [])[]
  | select(.type=="Accepted") | .status ] | index("True") | not) | .metadata.name' 2>/dev/null || true)"
if [[ -z "$unaccepted" && "$routes_total" != "0" ]]; then
  log_pass "all ${routes_total} HTTPRoute(s) Accepted" "status.parents[].conditions"
else
  log_fail "HTTPRoutes not Accepted: ${unaccepted:-<none found>} (${routes_total} total)"
fi

# --- T074a (b): the Gateway API is the PRIMARY model, not merely preferred --
# FR-026 says the legacy Ingress must not be the primary configuration model.
# The strongest available reading is that none exists at all.
ingress_count="$($K get ingress -A --no-headers 2>/dev/null | grep -c . 2>/dev/null | head -1 | tr -d ' ')"
[[ -n "$ingress_count" ]] || ingress_count=0
assert_eq "zero Ingress objects cluster-wide (FR-026)" "0" "$ingress_count"

# --- 4. Gateway reachability ----------------------------------------------
log_section "gateway reachability"
assert_http_status "gateway answers over TLS" "200" "${LAB_BASE_URL}/api/v1/tenant"

headers="$(curl_headers "${LAB_BASE_URL}/api/v1/tenant")"
assert_contains "the response came from the in-cluster Envoy" "$headers" "server: envoy"

# --- 5. Backing services ---------------------------------------------------
log_section "datastores"
# The probe commands themselves, not the kubelet's report of them.
if $K -n "${NS_DATA}" exec statefulset/postgres -- \
     sh -c 'pg_isready -U "$POSTGRES_USER" -d postgres -h 127.0.0.1' >/dev/null 2>&1; then
  log_pass "postgres accepts connections" "pg_isready, executed"
else
  log_fail "postgres does not accept connections"
fi

if $K -n "${NS_DATA}" exec statefulset/redis -- \
     sh -c 'redis-cli -a "$REDIS_PASSWORD" --no-auth-warning ping' 2>/dev/null | grep -q PONG; then
  log_pass "redis answers an authenticated PING" "redis-cli, executed"
else
  log_fail "redis does not answer an authenticated PING"
fi

# --- 6. Application readiness ---------------------------------------------
log_section "applications"
for d in auth-service order-service; do
  desired="$($K -n "${NS_APP}" get deploy "$d" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 0)"
  ready="$($K -n "${NS_APP}" get deploy "$d" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)"
  assert_eq "${d}: all replicas Ready" "$desired" "${ready:-0}"
done

# --- 7. Services exist and have endpoints ---------------------------------
# A Service with no endpoints looks perfectly healthy and serves nothing, which
# is why the endpoint count is the check rather than the Service's existence.
for svc in auth-service order-service; do
  if $K -n "${NS_APP}" get svc "$svc" >/dev/null 2>&1; then
    eps="$($K -n "${NS_APP}" get endpointslice -l "kubernetes.io/service-name=${svc}" \
      -o jsonpath='{range .items[*]}{range .endpoints[*]}{.addresses[0]}{"\n"}{end}{end}' 2>/dev/null | grep -c . || echo 0)"
    if [[ "${eps:-0}" -gt 0 ]]; then
      log_pass "Service ${svc} has ${eps} endpoint(s)" "kubectl get endpointslice"
    else
      log_fail "Service ${svc} has NO endpoints"
    fi
  else
    log_fail "Service ${svc} does not exist"
  fi
done

# --- 8. HTTP routing to both backends -------------------------------------
log_section "routing"
assert_http_status "path routes to auth-service" "200" "${LAB_BASE_URL}/api/v1/tenant"
# /api/orders without a token must be 401 — which proves the route REACHED
# order-service. A 404 would mean it never got there, and both are "not 200".
orders_code="$(curl_status "${LAB_BASE_URL}/api/orders")"
if [[ "$orders_code" == "401" || "$orders_code" == "403" ]]; then
  log_pass "path routes to order-service" "GET /api/orders -> ${orders_code} (reached the service, rejected the caller)"
else
  log_fail "GET /api/orders returned ${orders_code}" "404 would mean the route never reached order-service"
fi

route_marker="$(curl_headers "${LAB_BASE_URL}/api/v1/tenant" | grep -i '^x-hydra-lab-route:' || true)"
assert_contains "gateway route filters are executing (FR-028)" "$route_marker" "auth-service"

# --- T074a (a): both tenant hostnames, resolving to THEMSELVES -------------
log_section "tenants (FR-033)"
hosts_before="$(md5 -q /etc/hosts 2>/dev/null || md5sum /etc/hosts 2>/dev/null | awk '{print $1}')"
for t in "${LAB_PRIMARY_TENANT}" "${LAB_SECOND_TENANT}"; do
  body="$(curl_body "https://${t}.${LAB_BASE_DOMAIN}/api/v1/tenant")"
  status="$(printf '%s' "$body" | jq -r '.status // "unparseable"' 2>/dev/null)"
  if [[ "$status" == "recognized" ]]; then
    log_pass "${t}.${LAB_BASE_DOMAIN} resolves to its own tenant" "$(printf '%s' "$body" | jq -c '.' 2>/dev/null)"
  else
    log_fail "${t}.${LAB_BASE_DOMAIN} resolved as '${status}', not 'recognized'"
    log_context "$body"
    log_context "'unknown' here means the Host header was rewritten somewhere on the path (FR-036)."
  fi
done
hosts_after="$(md5 -q /etc/hosts 2>/dev/null || md5sum /etc/hosts 2>/dev/null | awk '{print $1}')"
assert_eq "no host resolution file was modified (FR-033)" "$hosts_before" "$hosts_after"
if [[ "$(id -u)" != "0" ]]; then
  log_pass "no privilege was elevated" "running as uid $(id -u)"
else
  log_fail "this suite is running as root; FR-033 requires no elevated privilege"
fi

# --- 9. Service-to-service ------------------------------------------------
log_section "service-to-service"
# order-service validating a token IS the JWKS fetch: it cannot verify a
# signature without having retrieved the key set from auth-service over cluster
# DNS. So a successful authenticated call is the executed proof of FR-045.
token="$(curl_body "${LAB_BASE_URL}/api/v1/auth/login" \
  -X POST -H 'Content-Type: application/json' \
  -d "{\"username\":\"labuser\",\"password\":\"lab-password-not-a-secret\"}" \
  | jq -r '.token // .accessToken // empty' 2>/dev/null)"
if [[ -n "$token" ]]; then
  log_pass "sign-in through the gateway issues a token" "POST /api/v1/auth/login"
  code="$(curl_status "${LAB_BASE_URL}/api/orders" -H "Authorization: Bearer ${token}")"
  if [[ "$code" == "200" ]]; then
    log_pass "order-service validated an auth-service token" \
             "the JWKS fetch over cluster DNS by service name succeeded (FR-045)"
  else
    log_fail "authenticated GET /api/orders returned ${code}"
    log_context "order-service could not verify the token — check AUTH_SERVICE_URL and the JWKS fetch."
  fi
else
  log_fail "sign-in through the gateway did not return a token"
fi

# --- 10. Observability and delivery planes --------------------------------
log_section "platform components"
for spec in "${NS_OBS}:deploy:prometheus-server:Prometheus" \
            "${NS_OBS}:deploy:grafana:Grafana" \
            "${NS_OBS}:deploy:otel-collector-opentelemetry-collector:OTel Collector"; do
  ns="${spec%%:*}"; rest="${spec#*:}"; kind="${rest%%:*}"; rest="${rest#*:}"
  name="${rest%%:*}"; label="${rest#*:}"
  ready="$($K -n "$ns" get "$kind" "$name" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)"
  if [[ "${ready:-0}" -ge 1 ]]; then
    log_pass "${label} available" "${kind}/${name} in ${ns}"
  else
    log_fail "${label} not available" "${kind}/${name} in ${ns}"
  fi
done

if (( REDUCED )); then
  log_skip "Tempo" "reduced mode disables the trace store, so SC-012 is unavailable (D18)"
else
  if $K -n "${NS_OBS}" get statefulset tempo >/dev/null 2>&1 || $K -n "${NS_OBS}" get deploy tempo >/dev/null 2>&1; then
    log_pass "Tempo available" "the only trace store (FR-080a)"
  else
    log_fail "Tempo not found"
  fi
fi

# Argo CD is checked through argocd-status rather than pod readiness: a running
# Argo CD that reports every Application OutOfSync is not a working delivery
# plane, and pod readiness cannot tell the difference (T134a).
if "${LAB_ROOT}/scripts/consoles.sh" argocd-status --quiet >/dev/null 2>&1; then
  log_pass "Argo CD available and its Applications are Synced/Healthy" "consoles.sh argocd-status"
else
  log_fail "Argo CD is not available, or an Application is OutOfSync or not Healthy"
  log_context "$("${LAB_ROOT}/scripts/consoles.sh" argocd-status 2>&1 | tail -12)"
fi

# --- 11. Namespace hygiene ------------------------------------------------
log_section "namespace hygiene (FR-074)"
stray="$($K -n default get pods,deploy,statefulset --no-headers 2>/dev/null | grep -vc '^No resources' 2>/dev/null | head -1 | tr -d ' ')"
[[ -n "$stray" ]] || stray=0
assert_eq "no workload in the default namespace" "0" "$stray"

# --- 12. T077: not reachable except through the gateway -------------------
log_section "exposure (US2 independent test)"
# Any NodePort or LoadBalancer Service for the application workloads would be a
# second way in, which FR-030 forbids — there is exactly one exposure mechanism.
extra_exposed="$($K -n "${NS_APP}" get svc -o json 2>/dev/null | jq -r '
  .items[] | select(.spec.type=="NodePort" or .spec.type=="LoadBalancer")
  | select(.metadata.name != "cilium-gateway-hydra-gateway") | .metadata.name' 2>/dev/null || true)"
if [[ -z "$extra_exposed" ]]; then
  log_pass "no application Service is exposed outside the cluster" "only the Gateway's own Service is NodePort (FR-030)"
else
  log_fail "these Services are exposed outside the gateway: ${extra_exposed}"
fi

# --- 13. T136: no secret material in the tracked gitops tree --------------
log_section "secrets (FR-085)"
leaked="$(grep -rlEi 'BEGIN [A-Z ]*PRIVATE KEY|password:[[:space:]]*[^"$ {]' "${LAB_ROOT}/gitops" 2>/dev/null || true)"
if [[ -z "$leaked" ]]; then
  log_pass "no secret material in the tracked gitops tree" "grep over gitops/"
else
  log_fail "possible secret material in gitops/: ${leaked}"
fi

# --- 14. T147: documentation is English ------------------------------------
log_section "documentation (FR-114)"
non_english="$(grep -rlP '[\x{0590}-\x{05FF}\x{0600}-\x{06FF}\x{4E00}-\x{9FFF}]' \
  "${LAB_ROOT}/docs" "${LAB_ROOT}/README.md" 2>/dev/null || true)"
if [[ -z "$non_english" ]]; then
  log_pass "all lab documentation is in English" "FR-114"
else
  log_fail "non-English text found in: ${non_english}"
fi

log_summary
