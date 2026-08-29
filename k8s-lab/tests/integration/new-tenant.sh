#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# new-tenant.sh — a tenant added AFTER the gateway was programmed
# (FR-040, SC-007).
#
# Clause 5 of the transparent edge contract: no per-tenant configuration. This
# demonstrates it rather than asserting it — the tenant is inserted while the
# gateway is running, and the gateway objects are captured before and after and
# compared.
#
# ONE HONEST CAVEAT, and it is a real one. FR-040 holds for ROUTING: no Gateway,
# no HTTPRoute, no listener changes. It does NOT hold for TLS on `.localhost`,
# because mainstream TLS clients reject a `*.localhost` wildcard — `localhost`
# is a public suffix. The lab's certificate therefore enumerates tenant
# hostnames in its SAN. That is a property of the lab's ADDRESSING CHOICE, not
# of Kubernetes-as-edge: with a real base domain the wildcard matches and the
# property is whole. Measured, and recorded in docs/known-gaps.md.
# ---------------------------------------------------------------------------
set -uo pipefail

LAB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "${LAB_ROOT}/scripts/lib/versions.sh"
source "${LAB_ROOT}/scripts/lib/log.sh"
source "${LAB_ROOT}/scripts/lib/wait.sh"
source "${LAB_ROOT}/scripts/lib/assert.sh"

K="kubectl --context ${LAB_KUBECONTEXT}"
NEW="${LAB_LATE_TENANT}"
NEW_HOST="${NEW}.${LAB_BASE_DOMAIN}"

log_suite "new tenant after the gateway was programmed (SC-007)"

# It must NOT already exist, or the demonstration is vacuous.
existing="$($K -n "${NS_DATA}" exec statefulset/postgres -- \
  sh -c "psql -U \"\$POSTGRES_USER\" -d auth_db -Atc \"SELECT count(*) FROM tenants WHERE url_identifier='${NEW}'\"" 2>/dev/null | tr -d '\r ')"
if [[ "${existing:-0}" != "0" ]]; then
  log_fail "tenant '${NEW}' already exists" "SC-007 requires it to be added DURING this test"
  log_info "The fixture seeds acme and beta only, precisely so gamma can be added here."
  log_summary; exit 1
fi
log_pass "'${NEW}' does not exist yet" "the fixture deliberately seeds only acme and beta"

# Fingerprint every gateway object BEFORE.
before="$(mktemp)"
{
  $K get gatewayclass -o yaml 2>/dev/null
  $K -n "${NS_APP}" get gateway -o yaml 2>/dev/null
  $K -n "${NS_APP}" get httproute -o yaml 2>/dev/null
} | grep -vE 'resourceVersion|generation|lastTransitionTime|uid:|creationTimestamp|managedFields' > "$before"
log_pass "captured the gateway configuration before the change" "GatewayClass + Gateway + HTTPRoutes"

# THE CHANGE: a database insert. Nothing else.
$K -n "${NS_DATA}" exec statefulset/postgres -- sh -c "
  psql -U \"\$POSTGRES_USER\" -d auth_db -v ON_ERROR_STOP=1 -c \"
    INSERT INTO tenants (id, name, url_identifier, status, created_at)
    VALUES (gen_random_uuid(), 'Gamma Ltd', '${NEW}', 'ACTIVE', now())
    ON CONFLICT (url_identifier) DO NOTHING;\"" >/dev/null 2>&1 \
  && log_pass "tenant added by a database INSERT" "no kubectl apply, no helm upgrade, no restart" \
  || { log_fail "could not insert the tenant"; log_summary; exit 1; }

# It must work through the gateway, with no deploy step in between.
if wait_for "the new tenant resolves through the gateway" 120 \
     bash -c "curl -s --cacert '${LAB_CA_CERT}' --max-time 15 'https://${NEW_HOST}/api/v1/tenant' 2>/dev/null | grep -q recognized"; then
  body="$(curl_body "https://${NEW_HOST}/api/v1/tenant")"
  log_pass "https://${NEW_HOST} serves the new tenant" "$(printf '%s' "$body" | jq -c '.' 2>/dev/null)"
else
  log_fail "the new tenant does not resolve through the gateway"
  log_context "$(curl_body "https://${NEW_HOST}/api/v1/tenant")"
fi

# And nothing about the gateway changed. This is the assertion SC-007 is for.
after="$(mktemp)"
{
  $K get gatewayclass -o yaml 2>/dev/null
  $K -n "${NS_APP}" get gateway -o yaml 2>/dev/null
  $K -n "${NS_APP}" get httproute -o yaml 2>/dev/null
} | grep -vE 'resourceVersion|generation|lastTransitionTime|uid:|creationTimestamp|managedFields' > "$after"

if diff -q "$before" "$after" >/dev/null 2>&1; then
  log_pass "ZERO gateway objects changed" "GatewayClass, Gateway and HTTPRoutes are byte-identical (FR-040, SC-007)"
  log_info "Adding a tenant is a database insert. That is Clause 5 demonstrated, not asserted."
else
  log_fail "a gateway object changed when a tenant was added"
  log_context "$(diff "$before" "$after" | head -20)"
  log_info "Clause 5 of the transparent edge contract has been violated — the lab has found something."
fi
rm -f "$before" "$after"

# The honest caveat, stated in the output rather than only in a document.
log_section "what this does NOT establish"
log_info "TLS is the exception, and it is an addressing artifact rather than an architectural one:"
log_info "  mainstream TLS clients REJECT a *.localhost wildcard, because 'localhost' is a public"
log_info "  suffix. The lab's certificate therefore lists tenant hostnames explicitly, and a"
log_info "  genuinely new hostname would need a SAN. With a real base domain (*.hydra.example.com)"
log_info "  the wildcard matches and the property is whole. See docs/known-gaps.md."
sans="$(openssl x509 -in "${LAB_CERT_DIR}/wildcard.crt" -noout -text 2>/dev/null | grep -A1 'Subject Alternative Name' | tail -1 | tr -d ' ')"
log_info "current SAN: ${sans}"

log_summary
