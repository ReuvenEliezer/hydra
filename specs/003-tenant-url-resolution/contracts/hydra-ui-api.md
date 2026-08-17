# Contract: `@hydra/ui` public API changes

**Feature**: `003-tenant-url-resolution` | **Plan**: [../plan.md](../plan.md) | **Backend**: [auth-service-api.md](./auth-service-api.md)

This is a **breaking change** to the package's public surface: `tenantId` disappears from the provider, the login hook, and the login form. Every removal below is required by FR-002 (no manual tenant control) and the spec's Assumption that the temporary plumbing is removed rather than kept as a fallback.

---

## 1. `HydraProvider` — MODIFIED

**Removed prop**: `tenantId` (was required).

```diff
 export interface HydraProviderProps {
   apiBaseUrl: string;
-  tenantId: string;
   ordersBaseUrl?: string;
   children: ReactNode;
 }
```

**`apiBaseUrl` gains a hard requirement**: it must point at the *same tenant host the page is served from* — `http://acme.localhost:8083` for a page on `acme.localhost:5173`, or the page's own origin behind a path-routing edge. Pointing it at a hostless origin such as `http://localhost:8083` makes every login resolve to `unknown`, because the `Host` of the API request is what identifies the tenant, not the `Host` of the page (research.md R1). This belongs in the prop's doc comment and the package README, since it is the one way a consumer can silently break the feature.

**Removed context field**: `HydraContextValue.tenantId`.

**Added context fields**: the resolution result, populated by exactly one `GET /api/v1/tenant` call on mount, guarded against StrictMode double-invocation with the same `useRef` idiom as the existing `restoreSession()` call, and issued in parallel with it.

```ts
interface HydraContextValue {
  sessionManager: SessionManager;
  httpClient: HttpClient;
  ordersBaseUrl: string;
  tenant: TenantState;      // NEW
}
```

---

## 2. `useTenant()` — NEW hook

```ts
export type TenantStatus = "resolving" | "recognized" | "inactive" | "unknown" | "error";

export interface TenantState {
  status: TenantStatus;
  /** Present only when status === "recognized". */
  displayName: string | null;
  /** Present only when status === "error" — the lookup itself failed. */
  error: ApiError | null;
}

export function useTenant(): TenantState;
```

| Status | Meaning | Sign-in page renders |
|---|---|---|
| `resolving` | The mount-time lookup is in flight | A neutral loading state — never the form, never an error |
| `recognized` | Active tenant at this address | The form, headed with `displayName` (FR-017, SC-006) |
| `inactive` | Tenant exists here but is suspended | A message distinct from both other failure states (FR-005) — no form |
| `unknown` | This address maps to no tenant | "This address isn't recognized" (FR-004, SC-003) — no form |
| `error` | The lookup failed: network, 5xx, or 429 | A retryable-problem message — **never** the `unknown` copy |

`error` is deliberately not folded into `unknown`: reporting an address as unrecognized because the API was briefly unreachable sends the user chasing a problem that does not exist. `resolving` is likewise never rendered as a failure.

The hook is read-only and never returns a tenant UUID — the response has no field to carry one.

---

## 3. `useLogin()` — MODIFIED

```diff
 export interface UseLoginResult {
-  login: (username: string, password: string, tenantId?: string) => Promise<void>;
+  login: (username: string, password: string) => Promise<void>;
   isPending: boolean;
   error: AuthError | null;
   reset: () => void;
 }
```

The per-call tenant override is gone; nothing tenant-related leaves the browser. The request becomes a plain `POST /api/v1/auth/login` with `{username, password}` and no `X-Tenant-ID`.

`AuthError`'s code union gains `unknown_tenant_address` and `tenant_inactive`, so a login attempted against an address that stopped resolving between page load and submit still surfaces a correct, distinct message rather than "incorrect username or password".

---

## 4. `LoginForm` — MODIFIED

**Removed**: the Tenant ID `<Input>` and the `defaultTenantId` prop.

```diff
 export interface LoginFormProps {
   className?: string;
   title?: string;
   description?: string;
   onSuccess?: () => void;
-  defaultTenantId?: string;
 }
```

**Behavior by tenant status**:

- `recognized` — renders username/password. The default heading incorporates the organization name (e.g. `Sign in to Acme Corp`); an explicit `title` prop still overrides it.
- `unknown` / `inactive` / `error` — renders the corresponding message and **no form at all**. Not a disabled button: FR-006 and Story 3 require that no submission path exists which could be misattributed.
- `resolving` — renders a loading state.

The existing error-copy rule is untouched: wrong username and wrong password both remain "Incorrect username or password", because the backend deliberately collapses them.

**Test assertions this contract implies** (SC-001, Story 1 scenario 2): no input named `tenantId` and no UUID-shaped string appears anywhere in the rendered output in any state.

---

## 5. `http-client` — MODIFIED (internal, but exported types change)

```diff
 export interface HttpClientOptions {
   apiBaseUrl: string;
-  tenantId: string;
   sessionManager: SessionManager;
   fetchImpl?: typeof fetch;
 }

 export interface RequestOptions {
   method?: "GET" | "POST" | "PATCH" | "DELETE";
   body?: unknown;
   query?: Record<string, string | number | undefined>;
   authenticated?: boolean;
-  sendTenantHeader?: boolean;
-  tenantId?: string;
   signal?: AbortSignal;
 }
```

No code path can set `X-Tenant-ID` afterwards. `useOrdersClient`'s `tenantId: ""` workaround disappears with the field it worked around.

---

## 6. `types/errors` — MODIFIED

```diff
 export type ApiErrorCode =
   | "invalid_credentials"
+  | "unknown_tenant_address"
+  | "tenant_inactive"
   | "invalid_refresh_token"
   …
```

Both codes arrive in `message` of the standard `ErrorResponse` body and are mapped in `normalize-error.ts` alongside the existing `GlobalExceptionHandler` codes. `AuthError`'s union grows by the same two.

---

## 7. Package exports — MODIFIED

```diff
+export { useTenant } from "./hooks/useTenant";
+export type { TenantState, TenantStatus } from "./hooks/useTenant";
```

Removed types: none as *names* — `HydraProviderProps` and `LoginFormProps` keep their names with fields removed, and `UseLoginResult`'s `login` signature narrows.

---

## 8. Consumers inside this repo that must be updated

| Location | Change |
|---|---|
| `demo/App.tsx`, `.env.local` | Derive `apiBaseUrl`/`ordersBaseUrl` from `window.location.hostname`; drop `VITE_HYDRA_TENANT_ID` |
| `vite.demo.config.ts` | Allow `*.localhost` hosts so `acme.localhost:5173` reaches the dev server (research.md R3) |
| `stories/hydra-decorator.tsx`, `stories/Provisioning.stories.tsx` | Drop `STORY_TENANT_ID` from the provider; MSW-style mock for the lookup so stories render all five states |
| `tests/test-utils.tsx`, `tests/mocks/handlers.ts` | Provider without `tenantId`; new `GET /api/v1/tenant` handler; delete the "missing `X-Tenant-ID` → 400" handler branch |
| `tests/unit/useLogin.test.tsx` | Replace the "sends `X-Tenant-ID`" test with its inverse: the login request carries **no** tenant header |
| `tests/component/LoginForm.test.tsx` | Add coverage for all five statuses and the no-tenant-input assertion |

`RegisterAdminForm`'s `defaultTenantId` is **not** touched — it is an authenticated admin form that names a target tenant by UUID, which the spec's Assumptions place explicitly out of scope.
