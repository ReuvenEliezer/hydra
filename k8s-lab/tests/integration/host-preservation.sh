#!/usr/bin/env bash
# host-preservation.sh — Clause 1, from the workstation, over TLS, end to end
# (FR-036 addendum).
#
# The existing conformance suite proves Host preservation through a stand-in
# proxy. This proves it through the REAL path: TLS termination, host-based
# listener matching, and a routing decision — none of which a transparent
# pass-through exercises.
set -uo pipefail
LAB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "${LAB_ROOT}/scripts/lib/versions.sh"
source "${LAB_ROOT}/scripts/lib/log.sh"
source "${LAB_ROOT}/scripts/lib/assert.sh"

log_suite "Host preservation over TLS (FR-036)"

for t in "${LAB_PRIMARY_TENANT}" "${LAB_SECOND_TENANT}"; do
  host="${t}.${LAB_BASE_DOMAIN}"
  body="$(curl_body "https://${host}/api/v1/tenant")"
  status="$(printf '%s' "$body" | jq -r '.status // "unparseable"' 2>/dev/null)"
  name="$(printf '%s' "$body" | jq -r '.displayName // ""' 2>/dev/null)"

  if [[ "$status" == "recognized" ]]; then
    log_pass "${host} -> '${name}'" "Host survived TLS termination and host-based routing"
  else
    log_fail "${host} resolved as '${status}'"
    log_context "$body"
    log_context "'unknown' means Host was rewritten. For Hydra that is not a degradation —
tenant identity comes solely from Host, so EVERY tenant is offline at once."
  fi
done

# The two tenants must resolve to DIFFERENT tenants. A gateway that pinned every
# request to one backend hostname would still return 'recognized' for both.
acme_name="$(curl_body "https://${LAB_PRIMARY_HOST}/api/v1/tenant" | jq -r '.displayName // ""' 2>/dev/null)"
beta_name="$(curl_body "https://${LAB_SECOND_HOST}/api/v1/tenant" | jq -r '.displayName // ""' 2>/dev/null)"
assert_ne "the two tenant addresses resolve to DIFFERENT tenants" "$acme_name" "$beta_name"
log_info "acme -> '${acme_name}'   beta -> '${beta_name}'"

# X-Forwarded-Host must never be honoured as a substitute for Host (Clause 1
# addendum): a caller must not be able to name a tenant with a header.
forged="$(curl_body "https://${LAB_PRIMARY_HOST}/api/v1/tenant" -H "X-Forwarded-Host: ${LAB_SECOND_HOST}")"
forged_name="$(printf '%s' "$forged" | jq -r '.displayName // ""' 2>/dev/null)"
assert_eq "X-Forwarded-Host does not override Host" "$acme_name" "$forged_name"
log_info "Tenant identity comes from the ADDRESS and from nothing a caller can set."

log_summary
