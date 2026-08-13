# Quickstart: Validating the Hydra UI Package

Validates the package end-to-end against a real auth-service + order-service, proving the production refresh-token behavior actually works (not just unit-tested against mocks).

## Prerequisites

- Node.js 22 LTS, npm (or pnpm) installed.
- `hydra-ui/` package built (`npm install && npm run build` inside `hydra-ui/`).
- auth-service and order-service running locally (see repo root `docker-compose.yml` / each service's own run instructions) and reachable, with at least one tenant and one seeded `ROLE_ADMIN` or `ROLE_SUPER_ADMIN` account.

## 1. Component-level checks (no backend needed)

```bash
cd hydra-ui
npm run test        # Vitest + RTL + MSW — validates hook/component contracts in isolation
npm run storybook    # visually exercise every component in contracts/components.md
```
Expected: all Vitest suites pass, including the refresh-coalescing scenario (`session-manager.test.ts`: N concurrent 401s → exactly 1 refresh call, all N requests eventually resolve — SC-005) and the forced-sign-out-on-bad-refresh scenario (FR-008).

## 2. Live sign-in and silent renewal (User Story 1)

1. Launch Storybook's `LoginForm` story (or the demo app under `stories/`) pointed at a running auth-service via `HydraProvider apiBaseUrl`.
2. Sign in with a seeded account's username/password.
3. Confirm in devtools → Application → Cookies: a `refresh_token` cookie exists, `HttpOnly` ✓, `Secure` ✓ (if served over HTTPS), `SameSite=Strict`, path `/api/v1/auth` — and is **not** visible to `document.cookie` in the console.
4. Reload the page. Expected: still signed in, no login prompt (FR-003).
5. Wait past the access token's `PT1H` validity (or lower `jwt.expiration-duration` locally for faster testing), then trigger any protected action (e.g. load the order list). Expected: the action succeeds with no visible interruption, and exactly one `POST /api/v1/auth/refresh` call appears in the network tab (FR-004, SC-001).

## 3. Sign-out (User Story 2)

1. While signed in, click sign out.
2. Expected: immediate return to the sign-in screen; the `refresh_token` cookie is cleared (`Max-Age=0`); any subsequent protected call fails with a clean "not signed in" state rather than attempting a stale refresh (FR-007).

## 4. Order management (User Story 3)

1. Signed in as a `ROLE_USER`: open `OrderList`, filter by status, create an order with a valid order number/amount (expect success), attempt one with a blank number or zero amount (expect inline validation error, no request sent — FR-011).
2. Confirm `OrderStatusControl`/`CancelOrderButton` are not rendered for this `ROLE_USER` account (FR-015).
3. Signed in as a `ROLE_ADMIN`: open the same order, change its status, then cancel a different order. Expect both to succeed and the list to reflect the change (FR-013, FR-014).

## 5. Account provisioning (User Story 4)

1. Signed in as `ROLE_ADMIN`: use `RegisterUserForm` to create a new standard user; confirm `RegisterAdminForm` is not rendered for this account (FR-018).
2. Sign in as the newly created user to confirm the account works.
3. Signed in as `ROLE_SUPER_ADMIN`: use `RegisterAdminForm` to create a new admin for a tenant; confirm success (FR-017).

## 6. Failure/edge paths

- Trigger several rapid failed logins to hit the `login-username`/`login-ip` rate limits (see `RateLimited` annotations on `AuthController.login`); expect a rate-limit-specific message with a retry countdown, not a generic error (FR-021).
- Stop auth-service mid-session and trigger a protected action; expect a clear network-error message, not a false "signed out" state (Edge Cases).
- Manually delete the `refresh_token` cookie via devtools, then trigger a protected action after the access token expires; expect a clean forced sign-out (FR-008).
