# @hydra/ui

React components and hooks for HYDRA's `auth-service` and `order-service` — sign-in,
session renewal, order management, and account provisioning — packaged as a library that
any HYDRA front-end can install and compose.

It is not an application. There are no routes, no pages, and no opinions about how your
app is laid out; the hooks are the primary interface and every component is a thin,
restyleable wrapper over one of them.

## What makes this worth a package

The session layer reproduces the backend's actual production refresh-token contract
rather than approximating it:

- The **refresh token is never touched by JavaScript**. It lives in the `refresh_token`
  httpOnly / `SameSite=Strict` cookie scoped to `/api/v1/auth`, and the browser attaches
  it automatically because every auth request is sent with `credentials: "include"`.
- The **access token is held in memory only** — never `localStorage`, never
  `sessionStorage`, never a readable cookie.
- A page reload therefore has nothing to restore from except the cookie, so
  `HydraProvider` performs exactly **one silent refresh at mount** to re-establish the
  session.
- When the access token expires, **N concurrent requests produce exactly one**
  `POST /api/v1/auth/refresh`; they all wait on it and retry once it lands.
- A refresh that returns **401 forces a clean sign-out** (no retry loop). A refresh that
  returns **429 does not** — the session is still valid, so the client waits out
  `Retry-After` and tries again instead of dropping the user under load.

## Install

```bash
npm install @hydra/ui
```

React 19 and `react-dom` 19 are peer dependencies.

## Setup

```tsx
import { HydraProvider, SessionGate, LoginForm, OrderList } from "@hydra/ui";
import "@hydra/ui/styles.css";

export function App() {
  return (
    <HydraProvider
      apiBaseUrl="https://acme.hydra.example.com"
      ordersBaseUrl="https://orders.hydra.example.com"
    >
      <SessionGate fallback={<LoginForm />} pending={<p>Restoring your session…</p>}>
        <OrderList />
      </SessionGate>
    </HydraProvider>
  );
}
```

### `apiBaseUrl` must be on the tenant's own host

This is the one way to break the package silently, so it is worth a paragraph.

The tenant is resolved from the `Host` of the **API request**, not of the page. The browser
sets that from the URL you are calling. So a page served at `https://acme.hydra.example.com`
must call `https://acme.hydra.example.com` (or, behind a path-routing edge, simply its own
origin) — pointing `apiBaseUrl` at a hostless origin like `https://auth.hydra.example.com`
sends a host with no tenant label, and **every lookup returns `unknown` and every login fails
closed while the UI looks entirely correct**.

In development that means `http://acme.localhost:5173` → `http://acme.localhost:8083`. Derive
it rather than hardcoding it:

```tsx
const apiBaseUrl = `${window.location.protocol}//${window.location.hostname}:8083`;
```

Every component between the browser and auth-service must also forward the original `Host`
unmodified. A proxy that rewrites it to an upstream service name makes every address resolve
to `unknown` — the system fails closed, correctly but universally.

Nothing tenant-related is ever sent by this package. There is no `tenantId` prop, no
`X-Tenant-ID` header, and no per-call override: the server derives the tenant from the address
on login and from the JWT `tenantId` claim on every other call.

### `useTenant()`

The provider performs exactly one `GET /api/v1/tenant` on mount and publishes the result:

```tsx
const { status, displayName, error } = useTenant();
```

| `status` | Meaning | What `LoginForm` renders |
|---|---|---|
| `resolving` | The mount-time lookup is in flight | A neutral loading state — never the form, never an error |
| `recognized` | An active organization lives at this address | The form, headed with `displayName` |
| `inactive` | The organization exists here but is suspended | Its own message — no form |
| `unknown` | This address maps to no organization | "This address isn't recognized" — no form |
| `error` | The lookup itself failed (network, 5xx, 429) | A retryable-problem message — **never** the `unknown` copy |

The three failure states render **no form at all**, not a disabled button: a form that can be
filled in is a submission path, and a submission from an address that resolves to nothing is
exactly what must not be possible. `error` is deliberately not folded into `unknown` — telling
someone their address is wrong because the API blinked sends them to fix something that is not
broken.

`displayName` is populated only on `recognized`, and the response has no field that could carry
a tenant id, in any state.

## Backend prerequisites

Both services must allow your app's origin:

```yaml
hydra:
  cors:
    # PATTERNS, not literal origins - every tenant is its own origin, so a fixed list would
    # need an entry per tenant. A pattern is not "*": Spring echoes back the one matched
    # origin, which is what keeps allowCredentials(true) legal.
    allowed-origin-patterns: http://*.localhost:5173
```

auth-service additionally needs the base domain its addresses sit under, or nothing resolves:

```yaml
hydra:
  tenant:
    base-domains: localhost
```

`allowCredentials(true)` and `Access-Control-Expose-Headers: Retry-After` are already
configured in each service's `CorsConfig`. Both matter: without the first the browser
will not attach the refresh cookie, and without the second `Retry-After` reads as `null`
cross-origin and rate-limit countdowns silently disappear.

For local development over plain HTTP, set `REFRESH_COOKIE_SECURE=false` on
`auth-service` — browsers drop `Secure` cookies over HTTP, which would break the refresh
flow in a way that looks like "the session just dies".

## Hooks

| Hook | Endpoint |
|---|---|
| `useSession()` | — (client state; `status`, `user`, `hasRole`) |
| `useLogin()` | `POST /api/v1/auth/login` |
| `useLogout()` | `POST /api/v1/auth/logout` |
| `useOrders(filters?)` | `GET /api/orders` |
| `useOrder(id)` | `GET /api/orders/{id}` |
| `useCreateOrder()` | `POST /api/orders` |
| `useUpdateOrderStatus()` | `PATCH /api/orders/{id}/status` |
| `useCancelOrder()` | `DELETE /api/orders/{id}` (soft cancel, 204) |
| `useRegisterUser()` | `POST /api/v1/admin/register-user` |
| `useRegisterAdmin()` | `POST /api/v1/admin/{tenantId}/register-admin` |

## Components

`LoginForm`, `SessionGate`, `RequireRole`, `OrderList`, `OrderDetail`, `CreateOrderForm`,
`OrderStatusControl`, `CancelOrderButton`, `RegisterUserForm`, `RegisterAdminForm`, plus
the primitives (`Button`, `Input`, `Card`, `Dialog`, `Select`, `Table`) they are built
from. Every one accepts `className`, merged with `tailwind-merge`, so you can restyle
without forking.

## Roles are a UI hint, not authorization

`useSession().hasRole` and `RequireRole` decode the access token's payload client-side —
**without verifying its signature** — because the login response body carries no roles at
all. This exists so the UI does not offer buttons that would 403. Every real
authorization decision remains the backend's `@PreAuthorize`, and a tampered token buys
nothing but a control that fails.

## Order status transitions

`allowedTransitions(status)` mirrors `OrderService.validateStatusTransition` exactly:

```
PENDING   → SHIPPED | CANCELLED
SHIPPED   → DELIVERED | CANCELLED
DELIVERED → (terminal)
CANCELLED → (terminal)
```

Drive any status control from it rather than from the full `OrderStatus` enum, so an
invalid transition is never offered in the first place.

## Errors

Every failure arrives as one normalized `ApiError` with a `code`, a display `message`,
the HTTP `status`, and `retryAfterSeconds` on rate limits. That normalization is not
cosmetic — the backend has four error producers across three body layouts, and the
machine-readable code lives in `error` for rate limits but in `message` for auth
failures, while the most common error of all (an expired access token, rejected inside
the security filter chain) carries no code at all.

## Development

```bash
npm install
npm run test        # Vitest + React Testing Library + MSW
npm run storybook   # component workbench, pointed at locally running services
npm run build       # library build (ESM + type declarations)
npm run contrast    # WCAG AA check over the design tokens, both themes
```

> **Node is not on the default `PATH` on this machine.** It is a JetBrains-managed install;
> export it before running any of the above:
>
> ```bash
> export PATH="$HOME/Library/Application Support/JetBrains/IntelliJIdea2026.2/node/versions/24.19.0/bin:$PATH"
> ```

`npm run contrast` parses the tokens straight out of `src/styles/index.css`, converts the
authored `oklch()` values to linear sRGB, and fails the run if any text or control pair drops
below WCAG AA in either theme. It has no dependencies — this package adds none at runtime, and
the conversion is short enough not to warrant one.

Storybook stories deliberately talk to real local services rather than mocks — watching
the cookie and the refresh call in a browser's network tab is the point. See
[quickstart.md](../specs/001-hydra-ui-package/quickstart.md) for the full end-to-end
validation script, including sign-in, reload, silent renewal, sign-out, role gating, and
the rate-limit and network-failure paths.
