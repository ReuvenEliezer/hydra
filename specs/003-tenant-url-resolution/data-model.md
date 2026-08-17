# Phase 1 Data Model: Tenant Resolution from URL

**Feature**: `003-tenant-url-resolution` | **Date**: 2026-08-13 | **Plan**: [plan.md](./plan.md)

Covers the persistent schema, the in-process value types resolution produces, and the wire shapes. Rationale for the storage choices is in [research.md](./research.md) R5.

---

## 1. Persistent entities

### 1.1 `Tenant` (MODIFIED — table `tenants`)

| Field | Column | Type | Constraints | Notes |
|---|---|---|---|---|
| `id` | `id` | `uuid` | PK, generated | Unchanged. Remains the internal identifier used in JWT claims, FK relationships, and every server-side call (spec Assumptions). |
| `name` | `name` | `varchar(100)` | not null | Unchanged. Doubles as the **Tenant Display Name** shown on the sign-in page (FR-017) — no second column, because the spec's display name *is* the organization name already stored. |
| `status` | `status` | `varchar(30)` | not null | Unchanged `EntityStatus` enum. `ACTIVE` → `recognized`; anything else → `inactive`. |
| `createdAt` | `created_at` | `timestamp` | not null, immutable | Unchanged. |
| **`urlIdentifier`** | **`url_identifier`** | **`varchar(63)`** | **not null, unique** | **NEW.** The Tenant URL Identifier. Unique index is what FR-003 ("at most one tenant per URL") rests on. |

**Validation on `urlIdentifier`** (enforced at provisioning, per FR-009):

- Pattern `^[a-z0-9]([a-z0-9-]*[a-z0-9])?$` — lowercase letters, digits, hyphens; no leading or trailing hyphen (RFC 1123 DNS label).
- Length 1–63 characters.
- Not present in the configured reserved-word list (FR-013).
- Not present in `reserved_tenant_identifiers` (FR-012).

**Constructor change**: `Tenant(String name, EntityStatus status)` becomes `Tenant(String name, String urlIdentifier, EntityStatus status)`. The identifier is mandatory from construction — there is no setter and no nullable interim state, so "a tenant without an identifier" is unrepresentable rather than merely rejected (FR-009).

**Mutability**: `name` and `status` keep their setters. `urlIdentifier` has no setter in this feature — renaming is out of scope, and the spec's rename semantics (old address stops resolving, no alias) are a consequence of changing the column, not a flow this feature builds.

### 1.2 `ReservedTenantIdentifier` (NEW — table `reserved_tenant_identifiers`)

The permanent allocation ledger that makes FR-012 survive tenant deletion and renaming.

| Field | Column | Type | Constraints | Notes |
|---|---|---|---|---|
| `identifier` | `identifier` | `varchar(63)` | **PK** | The claimed value. Primary key, so a concurrent double-claim is rejected by the database rather than by a check-then-write. |
| `tenantId` | `tenant_id` | `uuid` | nullable | The tenant it was claimed for. Nullable *by design*: the row outlives the tenant. No FK constraint — a FK would either block tenant deletion or cascade the reservation away, and both defeat the point. |
| `reservedAt` | `reserved_at` | `timestamp` | not null | Claim time. |

**Lifecycle**: insert-only. Rows are never updated or deleted, including when the referenced tenant is deactivated, deleted, or renamed off the identifier.

**Not stored here**: the platform reserved-word list (`www`, `api`, `admin`, `app`, `auth`, `mail`, …). Those come from configuration (`hydra.tenant.reserved-identifiers`) so they can differ per environment and change without a data migration. Both checks run at provisioning; only one of them is persistent state.

---

## 2. Configuration (`TenantResolutionProperties`, prefix `hydra.tenant`)

| Property | Type | Example | Purpose |
|---|---|---|---|
| `base-domains` | `List<String>` | `localhost` (local/test), `hydra.example.com` (prod) | FR-015's allowed base-domain list. Empty list ⇒ every host resolves to `unknown` (fails closed), logged as a warning at startup, mirroring `CorsProperties`' existing posture. |
| `reserved-identifiers` | `List<String>` | `www, api, admin, app, auth, mail, static, cdn, status, support, docs` | FR-013's reserved-word list, rejected at provisioning. |

Values are normalized to lowercase on binding so configuration casing can never cause a resolution miss.

---

## 3. Resolution value types (in-process, auth-service)

### 3.1 `TenantHostParser` (pure function, no Spring dependencies)

```text
Optional<String> extractIdentifier(String hostHeader)
```

Normalization and matching order (FR-015):

1. Null/blank → empty.
2. Trim, lowercase (`Locale.ROOT`), strip one trailing dot (`acme.localhost.`).
3. Strip the port, including the bracketed IPv6 form (`[::1]:8083`). A bracketed literal or a bare IP address → empty.
4. Find the first configured base domain the host *ends with*, on a label boundary (`notacme.localhost` must not match base domain `acme.localhost`).
5. Take what precedes it. Exactly one label ⇒ that label. Zero labels (bare base domain) or two or more ⇒ empty.
6. The label must satisfy the identifier pattern; otherwise empty.

Empty at any step means `unknown` — never a default or guessed tenant (FR-006).

**Reference cases** (base domains `localhost`, `hydra.example.com`):

| Host | Result |
|---|---|
| `acme.localhost` | `acme` |
| `ACME.LocalHost:5173` | `acme` |
| `acme.localhost.` | `acme` |
| `acme.hydra.example.com` | `acme` |
| `localhost` / `hydra.example.com` | empty (bare base domain) |
| `a.b.hydra.example.com` | empty (two labels) |
| `notacme.localhost`* | `notacme` (single label — legitimately a different tenant) |
| `acme.evil.com` | empty (no configured base domain) |
| `127.0.0.1:8083`, `[::1]:8083` | empty |
| `-acme.localhost`, `acme-.localhost` | empty (invalid label) |

\* included to make the boundary explicit: label-boundary matching rejects `xacme.example.com` against base domain `acme.example.com`, but any single label in front of a *configured* base domain is a candidate identifier.

### 3.2 `TenantResolution` (internal record)

```text
TenantResolution(Status status, UUID tenantId, String displayName)
Status ∈ { RECOGNIZED, INACTIVE, UNKNOWN }
```

- `RECOGNIZED` — identifier extracted, tenant found, `status == ACTIVE`. Carries `tenantId` and `displayName`.
- `INACTIVE` — tenant found, status not `ACTIVE`. Carries `tenantId` internally; **`displayName` is not surfaced publicly** in this state (FR-014 authorizes the name only on `recognized`).
- `UNKNOWN` — no identifier, or no tenant with it. Both null.

`tenantId` exists on this record because `AuthService.login` needs it; it is stripped at the web boundary for the public lookup (§4.1). That asymmetry — internal type carries the UUID, public DTO cannot — is the mechanism behind SC-006.

**State transitions**: none. Resolution is a stateless per-request derivation; a tenant's `status` changing is what moves an address between `recognized` and `inactive`, and that transition belongs to tenant lifecycle, not to this feature.

---

## 4. Wire shapes

### 4.1 `TenantResolutionResponse` — public lookup (FR-014)

```json
{ "status": "recognized", "displayName": "Acme Corp" }
{ "status": "inactive" }
{ "status": "unknown" }
```

- `status`: `recognized` | `inactive` | `unknown`. Always present, always exactly one.
- `displayName`: present **only** on `recognized`; omitted (not null, not empty string) otherwise.
- **No other fields, ever** — no tenant UUID, no logo, colors, or branding, and nothing the browser could resubmit as a tenant override. This is asserted directly in tests as "the serialized body contains no UUID in any state" (SC-006).

### 4.2 `CreateTenantRequest` — provisioning input (FR-009)

```json
{ "name": "Acme Corp", "urlIdentifier": "acme" }
```

Bean-validated: `name` not blank, ≤ 100 chars; `urlIdentifier` not blank, ≤ 63 chars, matching the pattern in §1.1. Format failures are a 400 through the existing `MethodArgumentNotValidException` handler; reserved-word and already-claimed failures are semantic and surface as 422 `BusinessRuleException` (see [contracts/auth-service-api.md](./contracts/auth-service-api.md)).

### 4.3 `TenantResponse` — provisioning output

```json
{ "id": "…uuid…", "name": "Acme Corp", "urlIdentifier": "acme" }
```

Carries the UUID deliberately: this endpoint is SUPER_ADMIN-only and its caller is the operator, who already works in terms of tenant UUIDs (`POST /api/v1/admin/{tenantId}/register-admin`). The UUID prohibition in FR-014 applies to the public lookup, not to authenticated admin surfaces.

---

## 5. Entities removed

**`infra-shared`'s `Headers` class** (`Headers.TENANT_ID = "X-Tenant-ID"`) is deleted, not merely unused. It is the class's only member, and deleting it makes the compiler enumerate every remaining sender — `AuthController`, auth-service's `CorsConfig`, four auth-service test classes, and `integration-tests` — rather than leaving a live constant that invites a caller to keep supplying a tenant the server no longer reads.
