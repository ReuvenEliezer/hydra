# Contract: Public Hooks API

This is the primary interface `@hydra/ui` exposes to consuming applications (spec FR-022: reusable building blocks, not a fixed page flow). Each hook wraps exactly one backend capability; none combine multiple endpoints.

## `HydraProvider`

```ts
function HydraProvider(props: {
  apiBaseUrl: string;       // e.g. "https://api.hydra.example.com" — no default, must be supplied (Constraints)
  tenantId: string;         // REQUIRED: login sends it as X-Tenant-ID; omitting it makes every login fail with 400
  children: React.ReactNode;
}): JSX.Element;
```
Wraps the app once; hosts the session-manager instance every other hook reads from (per-provider, not a module singleton). Required — all hooks below throw if used outside a `HydraProvider`.

`tenantId` is **required**, not optional: `AuthController.login` declares `@RequestHeader(Headers.TENANT_ID)` without a default, so a missing header is rejected with `400 Missing header: X-Tenant-ID` before credentials are ever checked. How the consuming app *obtains* the tenant remains its own concern (spec Assumptions); supplying it is not.

On mount the provider performs one silent `restoreSession()` refresh so a page reload does not sign the user out (FR-003).

## `useSession()`

```ts
function useSession(): {
  status: "anonymous" | "authenticating" | "authenticated" | "refreshing" | "expired";
  user: { id: string; tenantId: string; roles: Role[] } | null;
  hasRole: (role: Role) => boolean; // true if user's role grants at least this level (ROLE_ADMIN implies ROLE_USER, etc.)
};
```
Read-only view of session state (Session entity, data-model.md). Re-renders on every session transition, including transparent refreshes (FR-003, FR-004).

## `useLogin()`

```ts
function useLogin(): {
  login: (username: string, password: string) => Promise<void>; // resolves on success, throws typed AuthError on failure
  isPending: boolean;
  error: AuthError | null; // { code: "invalid_credentials" | "validation_error" | "rate_limited" | "network_error"; message: string; retryAfterSeconds?: number }
};
```
Wraps `POST /api/v1/auth/login`. Never exposes raw credentials or the set refresh cookie to the caller (FR-001, FR-002).

## `useLogout()`

```ts
function useLogout(): {
  logout: () => Promise<void>; // always resolves; clears local session state even if the network call fails
};
```
Wraps `POST /api/v1/auth/logout`; cancels any in-flight/coalesced refresh (FR-007).

## `useOrders(filters?)`

```ts
function useOrders(filters?: { status?: OrderStatus }): {
  orders: Order[];
  page: { number: number; size: number; totalElements: number; totalPages: number };
  isLoading: boolean;
  error: ApiError | null;
  loadPage: (pageNumber: number) => void;
};
```
Wraps `GET /api/orders` (optional `status` filter per FR-010). Requires `hasRole("ROLE_USER")` or above; the hook itself does not enforce this (the backend does) but callers should gate rendering with `useSession().hasRole`.

**Must send `sort=createdAt,desc` explicitly.** The backend's `@PageableDefault(sort = "createdAt")` is *ascending*, so relying on the default would show oldest-first and silently violate FR-009.

## `useOrder(orderId)`

```ts
function useOrder(orderId: string): {
  order: Order | null;
  isLoading: boolean;
  error: ApiError | null; // includes a distinct "not_found" case
};
```
Wraps `GET /api/orders/{id}` (FR-012).

## `useCreateOrder()`

```ts
function useCreateOrder(): {
  createOrder: (input: { orderNumber: string; totalAmount: string }) => Promise<Order>;
  isPending: boolean;
  error: ValidationError | ApiError | null;
};
```
Wraps `POST /api/orders`. Client-side validates `orderNumber` non-blank and `totalAmount > 0` before submission (FR-011). A duplicate order number within the tenant returns a `BusinessRuleError` (422) — surfaced as its own message, not folded into generic validation (FR-023).

## `useUpdateOrderStatus()`

```ts
function useUpdateOrderStatus(): {
  updateStatus: (orderId: string, status: OrderStatus) => Promise<Order>;
  isPending: boolean;
  error: PermissionError | BusinessRuleError | ApiError | null;
};

// Exported helper — the single source of truth for which transitions the backend accepts.
// Mirrors OrderService.validateStatusTransition exactly.
function allowedTransitions(current: OrderStatus): OrderStatus[];
```
Wraps `PATCH /api/orders/{id}/status` (FR-013, FR-015). Callers should drive their control from `allowedTransitions(order.status)` so an invalid transition is never offered; an attempt anyway returns a `BusinessRuleError` (HTTP 422), not a validation or permission error.

## `useCancelOrder()`

```ts
function useCancelOrder(): {
  cancelOrder: (orderId: string) => Promise<void>; // resolves void — 204, no body
  isPending: boolean;
  error: PermissionError | BusinessRuleError | ApiError | null;
};
```
Wraps `DELETE /api/orders/{id}` (FR-014, FR-015). Despite the verb this is a **soft cancel**: the order's status becomes `CANCELLED` and the record is retained. The response is `204` with no body, so callers must refetch to display the updated order. Cancelling a `DELIVERED` or already-`CANCELLED` order returns a `BusinessRuleError` (422).

## `useRegisterUser()`

```ts
function useRegisterUser(): {
  registerUser: (input: { username: string; password: string }) => Promise<Account>;
  isPending: boolean;
  error: ValidationError | PermissionError | ApiError | null;
};
```
Wraps `POST /api/v1/admin/register-user`. Requires `ROLE_ADMIN`+ (FR-016).

## `useRegisterAdmin()`

```ts
function useRegisterAdmin(): {
  registerAdmin: (tenantId: string, input: { username: string; password: string }) => Promise<Account>;
  isPending: boolean;
  error: ValidationError | PermissionError | ApiError | null;
};
```
Wraps `POST /api/v1/admin/{tenantId}/register-admin`. Requires `ROLE_SUPER_ADMIN` (FR-017, FR-018).

---

### Shared error shape

All `error` fields above are discriminated unions over the normalized `ApiError` contract in [data-model.md](../data-model.md), always including at minimum `{ code, message }`, with `retryAfterSeconds` present only for rate-limit errors (FR-020, FR-021).

Normalization is mandatory, not cosmetic: the backend returns **three different body layouts** and puts the machine-readable code in `error` for rate limiting but in `message` for auth failures, while the single most common error (an expired access token, rejected inside the security filter chain) carries no code at all. Hooks never see raw bodies.

### Session-renewal failure semantics

The session manager distinguishes two outcomes when `POST /api/v1/auth/refresh` does not succeed:

- **`401`** (invalid, expired, reused, or missing renewal credential) → the session is genuinely dead: clear state, force sign-out, no retry (FR-008).
- **`429`** (rate limited — the refresh endpoint is throttled per-IP and per-token-hash) → the session is **still valid**: keep the user signed in, wait `retryAfterSeconds`, retry once. Treating this as a dead session would sign users out under load and lose their work (FR-021).

Any other failure (network, 5xx) surfaces as a retryable error without destroying the session.
