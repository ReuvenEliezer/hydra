# Contract: the transparent edge

**Feature**: `002-cors-edge-hardening` | **Date**: 2026-08-17

This is the contract levied on **any** component placed between a browser and the Hydra services — load balancer, ingress, gateway, reverse proxy, service mesh sidecar. It is not code in this repository. It is stated as testable clauses because [the conformance suite](../quickstart.md) executes it.

The contract is deliberately defined by what the edge must **not** do. That is what makes it independent of edge technology, and therefore what lets the Kubernetes-versus-docker-compose decision stay open (spec Out of Scope).

---

## Clause 1 — Preserve `Host`

The edge MUST forward the original `Host` header unmodified, end to end.

Since `003-tenant-url-resolution`, `Host` is the **sole** signal identifying the tenant. No header, body field, query parameter, or path segment carries a tenant identifier, by design. An edge that rewrites `Host` to an upstream service name makes every address resolve to `unknown`: the system fails closed, which is correct, but it fails closed *universally* — a total outage, not a degraded path.

- No rewriting to an upstream or internal service name.
- No stripping.
- No substitution from `X-Forwarded-Host`. 003 explicitly rejected forwarded-header semantics; `X-Forwarded-Host` is not a trusted signal, and the burden is on the edge to preserve `Host` itself.
- Terminating TLS does not license replacing `Host` with the internal routing address.

Case and port normalization are non-breaking, because tenant resolution is case- and port-insensitive. The edge still MUST NOT rely on that as licence to rewrite.

*Satisfies*: FR-011, FR-012.

---

## Clause 2 — Emit no cross-origin headers

The edge MUST NOT add, rewrite, or strip any cross-origin response header. The services are the sole emitter, in every deployment.

Most gateway products ship CORS handling and many enable something by default. If both the edge and the service emit, the browser receives duplicated headers and rejects the response outright — a failure that appears only in the deployed environment and never in local development, which is exactly why this clause is stated rather than assumed.

There is no migration window in which both legitimately emit. Any overlap is a misconfiguration.

*Satisfies*: FR-003, FR-015.

---

## Clause 3 — Pass preflight through unauthenticated

The edge MUST forward `OPTIONS` preflight requests to the service without requiring authentication and without answering them itself.

Preflight carries no credentials by design. An edge that demands authentication turns every cross-origin call into a failure at the `OPTIONS` that precedes it. The services already carry an explicit permit-all backstop for this, with a comment recording that it protects against filter-order changes.

*Satisfies*: FR-005.

---

## Clause 4 — Do not disturb the credential

The edge MUST NOT modify `Set-Cookie` on responses or `Cookie` on requests.

The renewal credential is issued `SameSite=Strict`, `httpOnly`, host-only (no `Domain` attribute), scoped to path `/api/v1/auth`. Each attribute is load-bearing:

- Broadening the scope with a `Domain` attribute spanning tenant subdomains would transmit one tenant's credential to another tenant's host — a cross-tenant leak dressed as a cookie-scope tweak.
- Relaxing `SameSite` would require cross-site request forgery protection on the credential-bearing endpoints in the same change, which today have none.

*Satisfies*: FR-014, and FR-007 as a guard.

---

## Clause 5 — Require no per-tenant configuration

Provisioning a new tenant MUST require no edge configuration change and no deployment.

Tenants are subdomains of a controlled base domain, and the edge routes by path, not by tenant. An edge needing a per-tenant route or certificate entry turns provisioning into a deployment.

*Satisfies*: FR-013, SC-007.

---

## Verification

The suite asserts all five clauses against a base URL, and knows nothing about what serves it. Per research R5 it is run against **two** stand-in configurations:

| Stand-in | Expected result |
|---|---|
| Transparent: preserves `Host`, adds no headers | Suite **passes** |
| Hostile: rewrites `Host`, injects its own cross-origin headers | Suite **fails**, naming each violated clause |

The second is not redundant. A suite that only ever meets a correct edge cannot distinguish "the edge is transparent" from "the assertions no longer work," and would keep passing after a refactor silently broke it. Requiring a failure against a known-bad edge is what makes SC-009 and SC-010 mean anything.

Pointing the suite at a real candidate edge is setting `edge.base-url`. No test code changes — that is SC-010.
