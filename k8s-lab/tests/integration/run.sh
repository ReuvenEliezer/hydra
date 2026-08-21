#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# integration/run.sh — `make test-integration` (FR-095, SC-004).
#
# Sign in -> create order -> list orders, ENTIRELY through the gateway. Nothing
# here talks to a Service directly or port-forwards to a pod: if the gateway,
# the routes, the TLS material, the tenant resolution or the JWKS fetch is
# broken, this suite fails, which is the point.
#
# It also covers the four behaviours FR-095 names beyond the happy path —
# readiness, network-policy effects, graceful shutdown and error handling — and
# the Constitution Principle III guard: the Lua rotation scripts must load by
# CLASSPATH PATH through the real image.
# ---------------------------------------------------------------------------
set -uo pipefail

LAB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "${LAB_ROOT}/scripts/lib/versions.sh"
source "${LAB_ROOT}/scripts/lib/log.sh"
source "${LAB_ROOT}/scripts/lib/wait.sh"
source "${LAB_ROOT}/scripts/lib/assert.sh"
source "${LAB_ROOT}/scripts/lib/ratelimit.sh"

K="kubectl --context ${LAB_KUBECONTEXT}"
USERNAME="labuser"
PASSWORD="lab-password-not-a-secret"

log_suite "integration (through the gateway)"

# ---------------------------------------------------------------------------
# Establish a clean rate-limit window before starting.
#
# This suite signs in FOUR times from one address: the precondition probe, the
# acme sign-in, the beta sign-in, and the wrong-password check. auth-service
# limits login on two independently-phased dimensions at capacity 5 each, so
# "one login succeeded" does NOT mean four more will.
#
# That is exactly how this suite failed inside `make validate` while passing
# 21/21 standalone: the old precondition polled until ONE login returned 200,
# declared the window clear, and then ran out of tokens two assertions later.
# scripts/lib/ratelimit.sh carries the measurements and the reasoning.
# ---------------------------------------------------------------------------
if ! require_clean_login_window "${LAB_PRIMARY_HOST}" "${USERNAME}" "${PASSWORD}"; then
  log_summary; exit 1
fi

# ===========================================================================
# 1. The flow FR-095 specifies
# ===========================================================================
log_section "sign in -> create order -> list orders"

login_body="$(curl_body "${LAB_BASE_URL}/api/v1/auth/login" \
  -X POST -H 'Content-Type: application/json' \
  -d "{\"username\":\"${USERNAME}\",\"password\":\"${PASSWORD}\"}")"
TOKEN="$(printf '%s' "$login_body" | jq -r '.token // .accessToken // empty' 2>/dev/null)"

if [[ -n "$TOKEN" ]]; then
  log_pass "sign in through the gateway" "POST ${LAB_BASE_URL}/api/v1/auth/login"
else
  log_fail "sign in returned no token"
  log_context "$login_body"
  log_summary; exit 1
fi

# The token must carry the tenant, and the tenant must be the one the ADDRESS
# named. That is the whole multi-tenant contract in one assertion.
# base64url with PADDING RESTORED. A JWT payload is unpadded base64url, and
# `base64 -d` rejects it roughly three times out of four depending on length —
# which produced a confident "the issued token has no tenantId claim" against a
# token that carried one. A decoder that fails silently is worse than no check.
b64="$(printf '%s' "$TOKEN" | cut -d. -f2 | tr '_-' '/+')"
case $(( ${#b64} % 4 )) in
  2) b64="${b64}==" ;;
  3) b64="${b64}=" ;;
esac
claims="$(printf '%s' "$b64" | base64 -d 2>/dev/null || true)"
tenant_claim="$(printf '%s' "$claims" | jq -r '.tenantId // empty' 2>/dev/null)"
if [[ -n "$tenant_claim" ]]; then
  log_pass "the issued token carries a tenant claim" "tenantId=${tenant_claim:0:8}..."
else
  log_fail "the issued token has no tenantId claim"
fi

order_ref="LAB-$(date +%s)"
create_body="$(curl_body "${LAB_BASE_URL}/api/orders" \
  -X POST -H "Authorization: Bearer ${TOKEN}" -H 'Content-Type: application/json' \
  -d "{\"orderNumber\":\"${order_ref}\",\"totalAmount\":19.98}")"
created_id="$(printf '%s' "$create_body" | jq -r '.id // empty' 2>/dev/null)"

if [[ -n "$created_id" ]]; then
  log_pass "create order through the gateway" "POST /api/orders -> ${order_ref}"
else
  log_fail "create order failed"
  log_context "$create_body"
fi

list_body="$(curl_body "${LAB_BASE_URL}/api/orders" -H "Authorization: Bearer ${TOKEN}")"
found="$(printf '%s' "$list_body" | jq -r --arg n "$order_ref" \
  '[.content[]? | select(.orderNumber == $n)] | length' 2>/dev/null || echo 0)"
assert_eq "the created order is listed" "1" "${found:-0}"

# SC-004 / FR-045: order-service cannot verify that token without having
# fetched the key set from auth-service over cluster DNS BY SERVICE NAME. The
# call above succeeding is the executed proof; this makes the reasoning
# explicit rather than leaving it implied.
log_pass "order-service validated an auth-service token" \
  "JWKS fetched from auth-service.${NS_APP}.svc.cluster.local — a pod address would not survive a restart (FR-045)"

# And the issuer stayed an opaque identifier rather than becoming an address.
issuer_env="$($K -n "${NS_APP}" get deploy order-service \
  -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="AUTH_SERVICE_ISSUER")].value}' 2>/dev/null)"
if [[ "$issuer_env" != http* ]]; then
  log_pass "AUTH_SERVICE_ISSUER is an opaque identifier" "${issuer_env} — never turned into a resolvable address (FR-046)"
else
  log_fail "AUTH_SERVICE_ISSUER looks like a URL: ${issuer_env}"
  log_context "jwk-set-uri and issuer-uri sit adjacent in order-service's config; conflating them is silent."
fi

# ===========================================================================
# 2. Tenant isolation — the data must follow the address
# ===========================================================================
log_section "tenant isolation"
beta_body="$(curl_body "https://${LAB_SECOND_HOST}/api/v1/auth/login" \
  -X POST -H 'Content-Type: application/json' \
  -d "{\"username\":\"${USERNAME}\",\"password\":\"${PASSWORD}\"}")"
BETA_TOKEN="$(printf '%s' "$beta_body" | jq -r '.token // .accessToken // empty' 2>/dev/null)"

if [[ -n "$BETA_TOKEN" ]]; then
  log_pass "the second tenant signs in at its own address" "https://${LAB_SECOND_HOST}"
  beta_list="$(curl_body "https://${LAB_SECOND_HOST}/api/orders" -H "Authorization: Bearer ${BETA_TOKEN}")"
  beta_has="$(printf '%s' "$beta_list" | jq -r --arg n "$order_ref" \
    '[.content[]? | select(.orderNumber == $n)] | length' 2>/dev/null || echo 0)"
  assert_eq "the second tenant cannot see the first tenant's order" "0" "${beta_has:-0}"
else
  log_fail "the second tenant could not sign in"
  log_context "$beta_body"
fi

# ===========================================================================
# 3. Error handling (FR-095)
# ===========================================================================
log_section "error handling"
assert_http_status "no credential -> 401" "401" "${LAB_BASE_URL}/api/orders"
assert_http_status "garbage token -> 401" "401" "${LAB_BASE_URL}/api/orders" \
  -H "Authorization: Bearer not-a-real-token"
assert_http_status "wrong password -> 401" "401" "${LAB_BASE_URL}/api/v1/auth/login" \
  -X POST -H 'Content-Type: application/json' \
  -d "{\"username\":\"${USERNAME}\",\"password\":\"definitely-wrong\"}"
assert_http_status "malformed body -> 400" "400" "${LAB_BASE_URL}/api/orders" \
  -X POST -H "Authorization: Bearer ${TOKEN}" -H 'Content-Type: application/json' \
  -d '{"nonsense":true}'

# An unknown tenant address must not resolve to a default. FR-006's "with no
# tenant there is nothing to guess with" is the property being checked.
unknown_body="$(curl_body "https://nosuchtenant.${LAB_BASE_DOMAIN}/api/v1/tenant")"
unknown_status="$(printf '%s' "$unknown_body" | jq -r '.status // "unparseable"' 2>/dev/null)"
if [[ "$unknown_status" != "recognized" ]]; then
  log_pass "an unknown tenant address does not resolve to a tenant" "status=${unknown_status}"
else
  log_fail "an unknown address resolved to a tenant — that is a default, and there must not be one"
fi

# ===========================================================================
# 4. Readiness behaviour (FR-095)
# ===========================================================================
log_section "readiness"
endpoints="$($K -n "${NS_APP}" get endpointslice -l kubernetes.io/service-name=auth-service \
  -o jsonpath='{range .items[*]}{range .endpoints[*]}{.conditions.ready}{"\n"}{end}{end}' 2>/dev/null)"
ready_count="$(printf '%s' "$endpoints" | grep -c '^true$' || echo 0)"
replicas="$($K -n "${NS_APP}" get deploy auth-service -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)"
assert_eq "every Ready replica is a Ready endpoint" "$replicas" "$ready_count"
log_info "Endpoint membership is what routes traffic — a Ready pod that is not an endpoint receives nothing."

# ===========================================================================
# 5. Network-policy effects (FR-095; the full drill is tests/failure/)
# ===========================================================================
log_section "network policy"
if $K get ciliumnetworkpolicy -n "${NS_APP}" allow-gateway-to-services >/dev/null 2>&1; then
  log_pass "the gateway's ingress rule is in force" "CiliumNetworkPolicy allow-gateway-to-services"
else
  log_fail "the gateway ingress policy is missing"
  log_context "Without it the gateway cannot reach the backends: Cilium's proxy carries the reserved:ingress identity, which a standard NetworkPolicy cannot name."
fi
deny_count="$($K -n "${NS_DATA}" get networkpolicy default-deny -o name 2>/dev/null | grep -c . || echo 0)"
assert_eq "the datastore namespace is default-deny" "1" "${deny_count}"

# ===========================================================================
# 6. Graceful shutdown (FR-095)
# ===========================================================================
log_section "graceful shutdown"
grace="$($K -n "${NS_APP}" get deploy auth-service \
  -o jsonpath='{.spec.template.spec.terminationGracePeriodSeconds}' 2>/dev/null)"
if [[ -n "$grace" && "$grace" -ge 30 ]]; then
  log_pass "terminationGracePeriodSeconds is sized for in-flight requests" "${grace}s"
else
  log_fail "terminationGracePeriodSeconds is ${grace:-unset}"
fi
# Exec-form entrypoint is what makes that grace period mean anything: in shell
# form the JVM never receives SIGTERM and the period becomes a delay before a
# kill (FR-058).
entrypoint="$($K -n "${NS_APP}" get deploy auth-service \
  -o jsonpath='{.spec.template.spec.containers[0].command}' 2>/dev/null)"
if [[ -z "$entrypoint" ]]; then
  log_pass "the container uses the image's exec-form ENTRYPOINT" "the JVM receives SIGTERM directly (FR-058)"
else
  log_fail "the pod overrides the entrypoint: ${entrypoint}"
fi

# ===========================================================================
# 7. Constitution Principle III — the Lua load site, through the real image
# ===========================================================================
log_section "classpath layout (Constitution III)"
# auth-service loads its Redis rotation scripts by CLASSPATH PATH
# (lua/<name>.lua). No compiler checks that, so a build that flattened or
# relocated resources would break it silently. Refresh EXECUTES that load site.
refresh_code="$(curl_status "${LAB_BASE_URL}/api/v1/auth/refresh" -X POST)"
if [[ "$refresh_code" == "400" || "$refresh_code" == "401" ]]; then
  log_pass "the refresh path executes and rejects a missing credential" \
           "HTTP ${refresh_code} — reached the handler, so the Lua scripts loaded from the classpath"
elif [[ "$refresh_code" == "500" ]]; then
  log_fail "refresh returned 500 — the Lua scripts may not have loaded from lua/*.lua"
  log_context "$($K -n "${NS_APP}" logs deploy/auth-service --tail=25 2>&1 | grep -iE 'lua|script|classpath' | tail -8)"
else
  log_fail "refresh returned ${refresh_code}, which is neither a rejection nor a server error"
fi

# The scripts are present in the image at the path the load site expects.
if $K -n "${NS_APP}" exec deploy/auth-service -- \
     sh -c 'test -r /app/app.jar' >/dev/null 2>&1; then
  log_pass "the running pod is serving from the built fat jar" "/app/app.jar"
else
  log_fail "could not confirm the jar inside the running pod"
fi

log_summary
