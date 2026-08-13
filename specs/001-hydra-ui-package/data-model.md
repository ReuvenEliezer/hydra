# Phase 1 Data Model: Hydra UI Package

Entities as they appear in this package's TypeScript types (`src/types/`). Field names/shapes mirror the actual backend DTOs/records confirmed in source, not guesses.

## Session

Client-side-only concept; not a backend-persisted record from the UI's point of view (the backend's Redis-backed refresh-token record is out of scope for the UI to model).

| Field | Type | Notes |
|---|---|---|
| `accessToken` | `string \| null` | RS256 JWT. Held in memory only (`session-manager.ts` module state) — never persisted, never exposed via any exported hook return value's serializable form beyond passing it into the `Authorization` header. |
| `userId` | `string (UUID) \| null` | From JWT `sub` claim / `AuthResponse.userId`. |
| `tenantId` | `string (UUID) \| null` | From JWT `tenantId` claim (`JwtClaimNames.TENANT_ID`). |
| `roles` | `("ROLE_USER" \| "ROLE_ADMIN" \| "ROLE_SUPER_ADMIN")[]` | From JWT `roles` claim. |
| `status` | `"anonymous" \| "authenticating" \| "authenticated" \| "refreshing" \| "expired"` | Drives `useSession()`'s public state machine; `"refreshing"` is the state other requests key off of to decide whether to coalesce. |

**Transitions**: On `HydraProvider` mount: `anonymous → authenticating` (silent `restoreSession()` refresh attempt) → `authenticated` (valid refresh cookie present, FR-003) or `anonymous` (no/invalid cookie) — this is what makes the session survive a page reload, since the access token itself is never persisted. Then: `anonymous → authenticating` (login submitted) → `authenticated` (login/refresh success) or `anonymous` (login failure). `authenticated → refreshing` (access token expired, 401 received) → `authenticated` (refresh success, new token swapped in) or `anonymous`/`expired` (refresh failed → forced sign-out, FR-008). `authenticated → anonymous` (explicit logout, FR-007, cancels any pending refresh).

## Account

Maps to `RegisterRequest`/backend `User` as exposed through `AuthResponse` and JWT claims — the UI never receives a full user list endpoint (none exists), only the identity of the current session and the identity created by registration calls.

| Field | Type | Notes |
|---|---|---|
| `id` | `string (UUID)` | |
| `username` | `string` | 3-50 chars (`LoginRequest`/`RegisterRequest` validation, mirrored client-side per FR-019). |
| `tenantId` | `string (UUID)` | Organization the account belongs to. |
| `role` | `"ROLE_USER" \| "ROLE_ADMIN" \| "ROLE_SUPER_ADMIN"` | Single primary role per the backend's `Role` model. |

## Order

Directly mirrors `OrderResponse` (`order-service/.../dto/OrderResponse.java`).

| Field | Type | Notes |
|---|---|---|
| `id` | `string (UUID)` | |
| `tenantId` | `string (UUID)` | |
| `orderNumber` | `string` | Required, non-blank (`CreateOrderRequest`). |
| `totalAmount` | `string` (decimal-safe) | Serialized as string to avoid float precision loss on `BigDecimal`; `> 0` enforced client-side (FR-011) mirroring `@DecimalMin("0.01")`. |
| `status` | `"PENDING" \| "SHIPPED" \| "DELIVERED" \| "CANCELLED"` | Matches `OrderStatus` enum exactly. |
| `createdBy` | `string (UUID)` | |
| `createdAt` | `string (ISO 8601)` | |
| `updatedAt` | `string (ISO 8601)` | |

**Validation rules** (client-side, mirroring server-side): `orderNumber` non-blank; `totalAmount` numeric and `> 0`; `status` update must be one of the four enum values.

## ErrorResponse — three wire shapes, one normalized type

**The backend does not return a single error shape.** Verified against source, four distinct producers exist, and the machine-readable code lives in a *different field* depending on which one responded. The package MUST normalize all of them into one internal `ApiError` before any hook or component sees it.

### Wire shape A — `ErrorResponse` from `GlobalExceptionHandler`

Handles domain exceptions in both services. Body: `{status, error, message, path, timestamp}`.

Critically, `error` here is the **HTTP reason phrase** (`"Unauthorized"`, `"Not Found"`) and the **machine code lives in `message`** — e.g. `message: "invalid_refresh_token"`, `message: "refresh_token_reuse_detected"`. Validation failures put the joined field messages in `message` instead.

### Wire shape B — `ErrorResponse` from `RateLimitExceptionHandler` (429)

Same record, **opposite convention**: `error` holds the machine code `"rate_limit_exceeded"` and `message` holds human text. Accompanied by a `Retry-After` header (seconds).

### Wire shape C — Spring Security entry points (`res.sendError`)

**This is the most common error path and it is not shape A.** An expired or invalid JWT is rejected inside the filter chain, which forwards to Boot's `/error` and returns Boot's default attributes `{timestamp, status, error, path}` — with **no `message` field at all** (`server.error.include-message` is not enabled) and no machine code. This is what a 401-triggering-refresh actually looks like. Same for filter-level 403s.

### Wire shape D — `AuthResponse` from `AuthController.refresh` with no cookie

Returns HTTP 401 with an `AuthResponse` body, which after `@JsonInclude(NON_NULL)` serializes to just `{"message": "invalid_refresh_token"}` — no `status`, no `path`, no `timestamp`.

### Normalized `ApiError` (what the package exposes)

| Field | Type | Derivation |
|---|---|---|
| `status` | `number` | HTTP status from the response object, never trusted from the body (shapes C/D may omit or disagree). |
| `code` | `ApiErrorCode` | Resolved by checking, in order: `body.error` against known codes (shape B), then `body.message` against known codes (shapes A/D), then falling back to a status-derived code (shape C). |
| `message` | `string` | Human-readable text for display; falls back to a code-specific default string when the body carries none (shape C always). |
| `path` | `string \| undefined` | Absent in shape D. |
| `retryAfterSeconds` | `number \| undefined` | Parsed from the `Retry-After` **header**, not the body. Requires the server to send `Access-Control-Expose-Headers: Retry-After` cross-origin. |

`ApiErrorCode` union: `"invalid_credentials"`, `"invalid_refresh_token"`, `"refresh_token_reuse_detected"`, `"rate_limit_exceeded"`, `"validation_error"`, `"business_rule_violation"`, `"permission_denied"`, `"not_found"`, `"network_error"`, `"server_error"`.
