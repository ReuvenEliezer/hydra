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
      apiBaseUrl="https://auth.hydra.example.com"
      ordersBaseUrl="https://orders.hydra.example.com"
      tenantId={tenantId}
    >
      <SessionGate fallback={<LoginForm />} pending={<p>Restoring your session…</p>}>
        <OrderList />
      </SessionGate>
    </HydraProvider>
  );
}
```

`tenantId` is **required**. `AuthController.login` declares `X-Tenant-ID` with no
default, so a login without it is rejected with `400 Missing header: X-Tenant-ID` before
the credentials are even checked. How your app resolves the tenant (subdomain, config,
a picker) is your call; supplying it is not optional.

It is only sent on the login request. Every other call derives the tenant server-side
from the JWT `tenantId` claim, and `order-service` does not even allow the header
through CORS.

## Backend prerequisites

Both services must allow your app's origin:

```yaml
hydra:
  cors:
    allowed-origins: http://localhost:5173
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
```

Storybook stories deliberately talk to real local services rather than mocks — watching
the cookie and the refresh call in a browser's network tab is the point. See
[quickstart.md](../specs/001-hydra-ui-package/quickstart.md) for the full end-to-end
validation script, including sign-in, reload, silent renewal, sign-out, role gating, and
the rate-limit and network-failure paths.
