# Contract: auth-service HTTP API changes

**Feature**: `003-tenant-url-resolution` | **Plan**: [../plan.md](../plan.md) | **Shapes**: [../data-model.md](../data-model.md)

Only endpoints this feature adds or changes are listed. Everything else in auth-service and all of order-service is unchanged (FR-007).

**Common to every endpoint below**: the tenant is resolved from the request's own `Host` header (`getHeader("Host")`, falling back to `getServerName()`), port-insensitively and case-insensitively, against `hydra.tenant.base-domains`. No request may carry a tenant identifier in a header, body, query parameter, or path — that is the property this feature exists to establish, and the removal of `X-Tenant-ID` from the CORS allowed-header list is what makes an attempt fail at the preflight.

Error bodies use auth-service's existing `ErrorResponse` shape from `GlobalExceptionHandler`:

```json
{ "status": 400, "error": "Bad Request", "message": "unknown_tenant_address", "path": "/api/v1/auth/login" }
```

---

## 1. `GET /api/v1/tenant` — public tenant resolution lookup (NEW)

Called once by the sign-in page on load (FR-014). Unauthenticated; must be added to `SecurityCommons.authRules()` as `permitAll`.

**Request**: no body, no parameters, no authentication. Resolution comes from `Host` alone.

**Rate limit** (FR-016): `@RateLimited(limit = "tenant-resolve-ip", key = ClientIpResolver)`; config `rate-limit.limits.tenant-resolve-ip` (default capacity 30 / `PT1M`). Exceeding it returns the rate limiter's existing `429` shape with `Retry-After` — already exposed cross-origin by `CorsConfig`.

**Responses**

| Case | Status | Body |
|---|---|---|
| Host resolves to an `ACTIVE` tenant | `200` | `{"status":"recognized","displayName":"Acme Corp"}` |
| Host resolves to a non-`ACTIVE` tenant | `200` | `{"status":"inactive"}` |
| Host resolves to no tenant (bad label, unknown label, bare base domain, multi-label, unconfigured base domain) | `200` | `{"status":"unknown"}` |
| Rate limit exceeded | `429` | rate-limiter body + `Retry-After` |

**Invariants**

- Always `200` for all three resolution outcomes — the status is the payload, not the HTTP code. A `404` for `unknown` would collide with `ResourceNotFoundException`'s meaning and would push clients into distinguishing "no tenant here" from "endpoint missing".
- **No tenant UUID in any state**, and no field beyond `status` / `displayName` (SC-006). `displayName` appears only on `recognized`.
- Responses are not cacheable across hosts; no `Cache-Control` beyond the service default, and the value is per-`Host` by construction.

---

## 2. `POST /api/v1/auth/login` — MODIFIED

**Removed**: `X-Tenant-ID` request header. It is no longer read, no longer allowed through CORS, and `Headers.TENANT_ID` is deleted from `infra-shared`.

**Request** (unchanged body):

```json
{ "username": "alice", "password": "…" }
```

**Order of operations**: existing rate-limit dimensions (`login-ip`, `login-username`) → **tenant resolution** → credential lookup. Resolution precedes credentials so no login can be attributed to a guessed or default tenant (FR-006).

**Responses**

| Case | Status | `message` code | Notes |
|---|---|---|---|
| Success | `200` | — | Unchanged: `{userId, token}` + rotated `refresh_token` cookie. |
| Host resolves to no tenant | `400` | `unknown_tenant_address` | Distinct from invalid credentials (FR-004). |
| Host resolves to an inactive tenant | `403` | `tenant_inactive` | Distinct from both other cases (FR-005). |
| Wrong username or password, or inactive **user** | `401` | `Invalid credentials` | Unchanged, and still collapsed across unknown-user / wrong-password / inactive-user to prevent username enumeration. |
| Rate limit exceeded | `429` | — | Unchanged. |

New codes are added to `AuthErrorCodes` and raised as `UnknownTenantAddressException` / `InactiveTenantException`, each with its own `GlobalExceptionHandler` handler.

**Unchanged**: `POST /api/v1/auth/refresh` and `POST /api/v1/auth/logout` never resolve a tenant — the refresh cookie carries its own session state, tenant included. They are untouched by this feature.

---

## 3. `POST /api/v1/admin/tenants` — tenant provisioning (NEW)

Authenticated, `SUPER_ADMIN` only (`@PreAuthorize(Roles.SUPER_ADMIN_ONLY)`, plus an explicit rule in `SecurityCommons.authRules()` consistent with the existing admin paths). This endpoint does not exist today — tenants are currently created only by the `local`-profile `BootstrapService`.

**Request**:

```json
{ "name": "Acme Corp", "urlIdentifier": "acme" }
```

**Response** `201 Created`:

```json
{ "id": "…uuid…", "name": "Acme Corp", "urlIdentifier": "acme" }
```

**Rejections**

| Case | Status | `message` |
|---|---|---|
| `urlIdentifier` fails the format/length rules, or `name` blank/too long | `400` | Bean-validation detail (existing `MethodArgumentNotValidException` handler) |
| `urlIdentifier` is in `hydra.tenant.reserved-identifiers` | `422` | reserved-identifier violation (FR-013) |
| `urlIdentifier` is already claimed — by a live tenant **or** by a historical reservation | `422` | already-claimed violation (FR-012) |
| Caller is not `SUPER_ADMIN` | `403` | existing access-denied body |

**Atomicity**: creating the tenant and inserting its `reserved_tenant_identifiers` row happen in one `@Transactional` unit. Two concurrent requests for the same identifier resolve at the database — the loser's insert violates the primary key and its whole transaction rolls back, so a tenant is never created without its reservation, and a reservation never exists for a tenant that failed to create.

**Post-condition (SC-004)**: on `201`, `GET /api/v1/tenant` at `https://<urlIdentifier>.<base-domain>` returns `recognized` immediately, with no further configuration step.

---

## 4. Bootstrap (`local` profile) — MODIFIED

`BootstrapService` creates the System Tenant with `urlIdentifier: "system"` and its matching reservation row, so the super-admin signs in at `http://system.localhost:5173` like any other account (FR-010, spec Assumptions). `system` is claimed via the ledger rather than being carved out of the reserved-word list, so the seeded platform words remain purely "operators may not choose these".

---

## 5. CORS — MODIFIED (both services)

| Change | Reason |
|---|---|
| `setAllowedOrigins(...)` → `setAllowedOriginPatterns(...)`, configured per environment (`http://*.localhost:5173`, `https://*.hydra.example.com`) | Every tenant is now its own origin; a fixed list would need an entry per tenant, breaking SC-004. Patterns keep `allowCredentials(true)` legal by echoing the specific matched origin. |
| Drop `X-Tenant-ID` from auth-service's allowed request headers | The header no longer exists in the contract; leaving it allowed advertises a parameter the server ignores. |
| Empty pattern list still fails closed, with the existing startup warning | Unchanged posture from `CorsProperties`. |
| order-service gets the same pattern change | The app now runs on per-tenant origins and calls order-service from them. order-service still never reads a tenant header — it derives tenant from the JWT claim. |

**Ownership**: whether the services or an edge gateway ultimately emit these headers is `002-cors-edge-hardening`'s open decision. This change keeps the current emitter and does not preempt it.

---

## 6. Edge-layer requirement (FR-011)

Not code in this repository, stated here because the contract above depends on it: **every component between the browser and auth-service must forward the original `Host` unmodified.** A proxy that rewrites it to an upstream service name makes every address resolve to `unknown` — the system fails closed (correct) but universally (an outage). Any edge configuration added under `002-cors-edge-hardening` must preserve `Host`, and that is a test case for that feature, not an assumption of this one.
