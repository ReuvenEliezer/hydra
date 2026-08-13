# Implementation Plan: Hydra UI Package

**Branch**: `001-hydra-ui-package` | **Date**: 2026-08-13 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/001-hydra-ui-package/spec.md`

## Summary

Build `@hydra/ui`, a standalone, publishable React component/hook package that gives any HYDRA front-end a ready-made sign-in, session, order-management, and account-provisioning surface backed by auth-service and order-service. The centerpiece is a session layer that reproduces the backend's actual production refresh-token contract exactly: the refresh token lives only in the `refresh_token` httpOnly/Secure/SameSite=Strict cookie scoped to `/api/v1/auth` (never touched by JS), the short-lived access token is held in memory only, expired-access-token requests trigger a single coalesced `/api/v1/auth/refresh` call that any number of concurrent requests wait on and retry after, and a failed refresh (401, missing cookie) forces a clean sign-out. Built as a Vite 6 library-mode package (TypeScript strict, React 19, Tailwind v4, Radix primitives, Vitest, Storybook 8) that other apps install and compose.

## Technical Context

**Language/Version**: TypeScript 5.6+ (strict mode), Node.js 22 LTS for tooling.

**Primary Dependencies**: React 19, Vite 6 (library mode) + `vite-plugin-dts`, Tailwind CSS v4 (`@import "tailwindcss"`, no `tailwind.config.js`), `clsx` + `tailwind-merge` (`cn` helper), Radix UI primitives, Lucide React, native `fetch` for the API client (no axios — keeps the package dependency-light and lets `credentials: "include"` handle the httpOnly cookie natively).

**Storage**: N/A for persistent storage. Client-side runtime state only: access token held in a **per-`HydraProvider` instance** (not a module-level singleton — a singleton leaks session state across tests and breaks any app mounting more than one provider), never in `localStorage`/`sessionStorage`/a JS-readable cookie; refresh token lives exclusively in the backend-set httpOnly cookie, which the package never reads or writes directly — the browser attaches it automatically to `/api/v1/auth/*` requests.

**Roles/claims**: the login response body carries only `{userId, token}` — it contains **no roles**. `useSession().hasRole` therefore decodes the access token's payload client-side to read the `roles` and `tenantId` claims. This decode is a **UI-affordance hint only and is never authorization**: it is unverified (no signature check) and exists solely to hide controls the user cannot use. Every actual authorization decision remains the backend's `@PreAuthorize`.

**Testing**: Vitest + React Testing Library + `@testing-library/user-event` for components/hooks; MSW (Mock Service Worker) to simulate auth-service/order-service responses (including 401-then-refresh sequences and rate-limit 429s) without a running backend, since it is the standard, framework-agnostic way to test fetch-based session/refresh flows and is already implied by "production behavior" testing needs.

**Target Platform**: Modern evergreen browsers (last 2 versions of Chrome/Edge/Firefox/Safari) consuming the package inside HYDRA's React 19 front-end applications; server-side rendering is out of scope (per spec Assumptions — this is a components/hooks library, not an app).

**Project Type**: Frontend library (single package, not a full web app) — closest to the "Single project" structure option, adapted for a publishable UI library layout.

**Performance Goals**: Session-refresh coalescing must add no perceptible delay beyond one network round trip regardless of how many requests expire simultaneously (spec SC-005); component bundle must tree-shake per-component so consuming apps only pay for what they import.

**Constraints**: Refresh token MUST NOT be readable by application JavaScript at any point (spec FR-006, SC-003); the `X-Tenant-ID` header is required ONLY on the login request — every other authenticated call MUST carry only the bearer access token, with the tenant derived server-side from the JWT `tenantId` claim (confirmed from `OrderController`/`AdminController` source; see Constitution Check below); the package MUST NOT hardcode API base URLs (consuming app supplies them) or tenant resolution (spec Assumptions).

**Scale/Scope**: One versioned npm package; covers exactly the 10 existing endpoints across auth-service (`login`, `refresh`, `logout`, `register-user`, `register-admin`) and order-service (`list`, `create`, `get`, `update-status`, `cancel`) — no speculative extra endpoints.

**Backend prerequisites (resolved 2026-08-13)**: browser access required CORS on both services, which did not exist. Now configured via `hydra.cors.allowed-origins` (explicit origins — the `*` wildcard is illegal alongside the credentialed requests the refresh cookie needs), `allowCredentials(true)`, `OPTIONS` preflight permitted in the authorization rules, and `Access-Control-Expose-Headers: Retry-After` so FR-021's countdown is readable cross-origin. See `auth-service/.../config/CorsConfig.java` and `order-service/.../config/CorsConfig.java`. Two related items remain open and are tracked outside this feature: extracting the duplicated CORS config into a dedicated module (constitution Principle II), and the same-site cookie topology constraint (spec Assumptions).

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

The Hydra constitution's Principles I–IV (framework-free `infra-shared`, dedicated modules for cross-cutting concerns, load-path-authoritative classpath resources, atomic Redis mutations via Lua) govern the **Java/Spring backend modules** specifically and have no analog in a TypeScript UI package — **N/A, not violated**.

Principle V (Audit Before Building) **does** apply and has been satisfied for this plan: rather than assuming the refresh-token contract, this plan was written after reading the actual source —
`AuthController` (`auth-service/src/main/java/com/reuven/auth/controller/AuthController.java`), `AdminController` (same package), `OrderController` (`order-service/.../controller/OrderController.java`), `CookieUtil`, `JwtProvider`, `Headers`, `ErrorResponse`, and `RateLimitExceptionHandler`. Concretely confirmed rather than assumed:
- Cookie name `refresh_token`, `httpOnly`, `Secure` (configurable, must be true in prod), `SameSite=Strict`, path scoped to `/api/v1/auth`, default TTL `P30D`.
- Access token is a signed RS256 JWT, default validity `PT1H` (1 hour), returned only in the JSON response body, never as a cookie.
- Tenant is supplied via required `X-Tenant-ID` header on login (order-service and other admin calls derive tenant from the JWT `tenantId` claim instead — the UI never sends tenant on those).
- Roles are `ROLE_USER`, `ROLE_ADMIN`, `ROLE_SUPER_ADMIN`, hierarchical (`ADMIN` implies `USER`-level order access; only `SUPER_ADMIN` can register admins).
- **There are four error producers with three different body shapes**, and the machine-readable code moves between fields: `GlobalExceptionHandler` puts it in `message` (with `error` holding the HTTP reason phrase), `RateLimitExceptionHandler` puts it in `error`, Spring Security's `sendError` entry points return Boot's default `/error` body with **no message field at all** (this is the 401 that triggers refresh — the most common error path), and `AuthController.refresh` with no cookie returns a bare `{"message": "..."}`. The client normalizes all four into one `ApiError`; see [data-model.md](./data-model.md).
- Order list default sort is `createdAt` **ascending** (`@PageableDefault(size = 20, sort = "createdAt")`), so FR-009's newest-first requires explicitly requesting `sort=createdAt,desc`.
- Orders enforce a status state machine (`validateStatusTransition`) and uniqueness of order number per tenant; violations return `422 UNPROCESSABLE_CONTENT` via `BusinessRuleException`, a class of error the UI must handle distinctly (FR-023).
- Cancel is a soft status change to `CANCELLED` returning `204` with no body — not a delete, and not a source of updated order data.

**Result: PASS.** No unjustified violations; no complexity to track.

## Project Structure

### Documentation (this feature)

```text
specs/001-hydra-ui-package/
├── plan.md              # This file (/speckit-plan command output)
├── research.md          # Phase 0 output (/speckit-plan command)
├── data-model.md         # Phase 1 output (/speckit-plan command)
├── quickstart.md         # Phase 1 output (/speckit-plan command)
├── contracts/             # Phase 1 output (/speckit-plan command)
└── tasks.md              # Phase 2 output (/speckit-tasks command - NOT created by /speckit-plan)
```

### Source Code (repository root)

```text
hydra-ui/                          # new standalone package, sibling to auth-service/order-service
├── .storybook/                    # Storybook 8 config (main.ts, preview.tsx)
├── src/
│   ├── components/
│   │   ├── ui/                    # Primitive components (Button, Input, Card, Dialog, Table, Select — Radix + Tailwind v4)
│   │   └── hydra/                 # Domain components: LoginForm, OrderList, OrderDetail, CreateOrderForm,
│   │                              #   UpdateOrderStatusControl, CancelOrderButton, RegisterUserForm, RegisterAdminForm
│   ├── hooks/                     # useSession, useLogin, useLogout, useOrders, useOrder, useCreateOrder,
│   │                              #   useUpdateOrderStatus, useCancelOrder, useRegisterUser, useRegisterAdmin
│   ├── lib/
│   │   ├── cn.ts                  # clsx + tailwind-merge helper
│   │   ├── http-client.ts         # fetch wrapper: base URL/tenant injection, bearer header, error mapping
│   │   └── session-manager.ts     # in-memory access token, mount-time session restore, refresh coalescing/queuing
│   ├── styles/                    # Tailwind v4 entry (`@import "tailwindcss";`), design tokens
│   ├── types/                     # Session, Account, Order, ErrorResponse, request/response DTOs (mirrors backend records)
│   └── index.ts                   # Public package exports
├── tests/                         # Vitest + RTL suites (unit + component), MSW handlers for auth/order endpoints
├── stories/                       # Storybook stories per component/hook (demo/example usage only — not a shipped app)
├── public/
├── eslint.config.js                # ESLint 9 flat config
├── tsconfig.json
├── vite.config.ts                 # Vite library-mode build (ESM + types via vite-plugin-dts)
├── package.json
└── README.md
```

**Structure Decision**: Single new package `hydra-ui/` at the repo root, sibling to `auth-service/` and `order-service/` (consistent with this repo's existing flat multi-module layout, e.g. `rate-limit-starter/`, `infra-shared/`). It is a self-contained frontend library, not folded into either backend service and not a `frontend/` + `backend/` split, since there is no HYDRA web app in this repo yet for it to pair with — this package is designed to be consumed by one when it exists.

## Complexity Tracking

*No Constitution Check violations — table intentionally omitted.*
