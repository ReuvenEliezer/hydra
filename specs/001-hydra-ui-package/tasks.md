---

description: "Task list for Hydra UI Package implementation"

---

# Tasks: Hydra UI Package

**Input**: Design documents from `/specs/001-hydra-ui-package/`

**Prerequisites**: [plan.md](./plan.md), [spec.md](./spec.md), [research.md](./research.md), [data-model.md](./data-model.md), [contracts/](./contracts/), [quickstart.md](./quickstart.md)

**Tests**: Included, but scoped to the highest-risk logic only (refresh-token coalescing/forced sign-out, client-side validation, role-gating) rather than full TDD-per-endpoint — Vitest/RTL/MSW is an explicit part of the requested tech stack (plan.md Technical Context) and the refresh-coalescing behavior (FR-005, SC-005) is exactly the kind of concurrency logic that needs a deterministic test, not just manual verification.

**Organization**: Tasks are grouped by user story from spec.md (US1–US4, in priority order) to enable independent implementation and testing of each story.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies on incomplete tasks)
- **[Story]**: Maps to spec.md user stories (US1 = Sign in & stay signed in, US2 = Sign out, US3 = Manage orders, US4 = Provision accounts)
- All file paths are relative to the new `hydra-ui/` package at the repo root (see plan.md Project Structure)

## Path Conventions

Single new package, per plan.md: `hydra-ui/src/`, `hydra-ui/tests/`, `hydra-ui/stories/`, `hydra-ui/.storybook/`.

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Scaffold the package and its tooling before any feature code exists

- [X] T001 Create the `hydra-ui/` directory tree exactly per plan.md's Project Structure (`src/components/{ui,hydra}`, `src/hooks`, `src/lib`, `src/styles`, `src/types`, `tests`, `stories`, `.storybook`, `public`)
- [X] T002 Initialize `hydra-ui/package.json` with name `@hydra/ui`, React 19 / TypeScript 5.6+ / Vite 6 / Tailwind v4 / Radix UI / Lucide React / clsx / tailwind-merge as dependencies, and Vitest / React Testing Library / `@testing-library/user-event` / MSW / Storybook 8 as devDependencies
- [X] T003 [P] Configure `hydra-ui/tsconfig.json` in strict mode targeting ES2022, with path aliases matching `src/` subfolders
- [X] T004 [P] Configure `hydra-ui/vite.config.ts` for library-mode build (ESM output) with `vite-plugin-dts` for type declarations
- [X] T005 [P] Configure `hydra-ui/eslint.config.js` (ESLint 9 flat config) and `hydra-ui/.prettierrc`
- [X] T006 [P] Create `hydra-ui/src/styles/index.css` with `@import "tailwindcss";` (no `tailwind.config.js`) and base design tokens
- [X] T007 [P] Initialize `hydra-ui/.storybook/main.ts` and `hydra-ui/.storybook/preview.tsx` for Storybook 8
- [X] T008 [P] Configure `hydra-ui/vitest.config.ts` and `hydra-ui/tests/setup.ts` bootstrapping the MSW server (per research.md §5)

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Shared types, HTTP plumbing, and UI primitives every user story's components/hooks build on

**⚠️ CRITICAL**: No user story work can begin until this phase is complete

- [X] T009 [P] Define `ApiError`, `ApiErrorCode`, `ValidationError`, `PermissionError`, `BusinessRuleError` discriminated-union types (per data-model.md's normalized `ApiError`, including `retryAfterSeconds`) in `hydra-ui/src/types/errors.ts`
- [X] T009a Implement `normalizeError` in `hydra-ui/src/lib/normalize-error.ts` handling all **four** backend error producers per data-model.md: code in `body.error` (rate limit), code in `body.message` (auth/domain), Boot's default `/error` body with no message (security filter 401/403 — the most common path), and the bare `{message}` from a cookieless refresh; always takes `status` from the response object, never the body (depends on T009)
- [X] T009b [P] Unit test: `normalizeError` maps one representative fixture of each of the four wire shapes to the correct `ApiErrorCode`, in `hydra-ui/tests/unit/normalize-error.test.ts` (per FR-020)
- [X] T010 [P] Define `Session`, `Role` ("ROLE_USER"|"ROLE_ADMIN"|"ROLE_SUPER_ADMIN"), and session `status` union types (per data-model.md's Session entity) in `hydra-ui/src/types/session.ts`
- [X] T010a [P] Implement `decodeAccessTokenClaims` in `hydra-ui/src/lib/decode-claims.ts` — base64url-decodes the JWT payload to read `sub`, `tenantId`, and `roles`, since the login response body carries no roles; documented and named as a UI-affordance hint only, never authorization (depends on T010)
- [X] T011 [P] Implement the `cn` helper (`clsx` + `tailwind-merge`) in `hydra-ui/src/lib/cn.ts`
- [X] T012 Implement the base HTTP client in `hydra-ui/src/lib/http-client.ts`: injects `X-Tenant-ID` on the login request **only** (other calls derive tenant server-side from the JWT claim), injects `Authorization: Bearer` from session state on other requests, sends `credentials: "include"` and an explicit `Accept: application/json` (the security-filter error path can otherwise return HTML), routes every failure through `normalizeError`, and parses the `Retry-After` header into `retryAfterSeconds` (depends on T009, T009a)
- [X] T013 [P] Implement `Button` primitive in `hydra-ui/src/components/ui/Button.tsx`
- [X] T014 [P] Implement `Input` primitive in `hydra-ui/src/components/ui/Input.tsx`
- [X] T015 [P] Implement `Card` primitive in `hydra-ui/src/components/ui/Card.tsx`
- [X] T016 [P] Implement `Dialog` primitive (Radix Dialog) in `hydra-ui/src/components/ui/Dialog.tsx`
- [X] T017 [P] Implement `Select` primitive (Radix Select) in `hydra-ui/src/components/ui/Select.tsx`
- [X] T018 [P] Implement `Table` primitive in `hydra-ui/src/components/ui/Table.tsx`
- [X] T019 Set up MSW request handlers for the auth-service and order-service endpoints (login, refresh, logout, register-user, register-admin, orders CRUD) in `hydra-ui/tests/mocks/handlers.ts` (depends on T012)

**Checkpoint**: Foundation ready — user story implementation can now begin in priority order

---

## Phase 3: User Story 1 - Sign in and stay signed in (Priority: P1) 🎯 MVP

**Goal**: A user signs in once and stays authenticated across reloads, with expired access tokens silently and safely renewed via the httpOnly refresh cookie.

**Independent Test**: Sign in with valid credentials, reload the page, confirm still authenticated; let the access token expire and confirm a protected call still succeeds via one transparent refresh.

**Note on session persistence**: the access token is deliberately never persisted (FR-006). Surviving a page reload (FR-003) therefore depends entirely on `HydraProvider`'s mount-time silent refresh (T025) rehydrating it from the httpOnly cookie — not on any storage mechanism.

### Tests for User Story 1 ⚠️

- [X] T020 [P] [US1] Unit test: `session-manager` coalesces N concurrent post-expiry requests into exactly one `/api/v1/auth/refresh` call, all N requests eventually resolve, in `hydra-ui/tests/unit/session-manager.test.ts` (per SC-005)
- [X] T020a [P] [US1] Integration test: mounting `HydraProvider` with a valid refresh cookie but no in-memory access token restores the session to an authenticated state without any user interaction, in `hydra-ui/tests/integration/session-restore.test.tsx` (per FR-003, US1 Acceptance Scenario 4)
- [X] T020b [P] [US1] Unit test: a `/api/v1/auth/refresh` call that returns 401 causes `session-manager` to perform a clean forced sign-out — state cleared, no infinite retry loop, no repeated refresh attempts — in `hydra-ui/tests/unit/session-manager-refresh-failure.test.ts` (per FR-008)
- [X] T021 [P] [US1] Unit test: `useLogin` success/failure states (invalid credentials, validation error, network error) in `hydra-ui/tests/unit/useLogin.test.tsx`
- [X] T022 [P] [US1] Component test: `LoginForm` renders a distinct error per `AuthError.code` and never surfaces which of username/password was wrong, in `hydra-ui/tests/component/LoginForm.test.tsx`

### Implementation for User Story 1

- [X] T023 [US1] Implement `session-manager` in `hydra-ui/src/lib/session-manager.ts` as a **per-provider instance factory, not a module singleton** (a singleton leaks state across tests and breaks multi-provider apps): in-memory-only access token, session `status` state machine (data-model.md Session transitions), single shared in-flight refresh promise, roles/tenant populated via `decodeAccessTokenClaims`, plus a `restoreSession()` entry point that performs one silent `POST /api/v1/auth/refresh` and resolves to authenticated-or-anonymous without throwing (depends on T010, T010a, T020, T020b)
- [X] T023a [US1] Implement refresh-failure branching in `hydra-ui/src/lib/session-manager.ts`: a `401` forces clean sign-out (FR-008), while a `429` keeps the session alive and retries once after `retryAfterSeconds` rather than signing the user out (depends on T023)
- [X] T023b [P] [US1] Unit test: a `429` on `/api/v1/auth/refresh` leaves the session authenticated and retries after the indicated delay, in `hydra-ui/tests/unit/session-manager-rate-limited.test.ts` (per FR-021)
- [X] T024 [US1] Wire the HTTP client's 401 handling to call the session-manager's refresh-and-retry-once logic, and its forced-sign-out path when the refresh itself fails, in `hydra-ui/src/lib/http-client.ts` (depends on T012, T023)
- [X] T025 [US1] Implement `HydraProvider` (hosts a per-provider session-manager instance; accepts `apiBaseUrl` and a **required** `tenantId` — login sends it as `X-Tenant-ID` and a missing header is rejected with 400 before credentials are checked) in `hydra-ui/src/components/HydraProvider.tsx`: on initial mount it calls `restoreSession()` exactly once to re-establish the in-memory access token and session state from the httpOnly refresh cookie after a page reload, holding session `status` at `"authenticating"` until it settles so consumers never flash a signed-out state (depends on T023, T020a)
- [X] T026 [P] [US1] Implement `useSession` hook (`status`, `user`, `hasRole`) in `hydra-ui/src/hooks/useSession.ts` (depends on T025)
- [X] T027 [P] [US1] Implement `useLogin` hook wrapping `POST /api/v1/auth/login` in `hydra-ui/src/hooks/useLogin.ts` (depends on T024)
- [X] T028 [US1] Implement `LoginForm` component with client-side username (3-50 chars) / password (8+ chars) validation per FR-019 in `hydra-ui/src/components/hydra/LoginForm.tsx` (depends on T027, T013, T014)
- [X] T029 [US1] Implement `SessionGate` component (renders children when authenticated or transparently refreshing, `fallback` otherwise, no flicker per SC-001) in `hydra-ui/src/components/hydra/SessionGate.tsx` (depends on T026)
- [X] T030 [P] [US1] Add Storybook story exercising sign-in + reload + silent-refresh scenarios in `hydra-ui/stories/LoginForm.stories.tsx` (depends on T028, T029)

**Checkpoint**: User Story 1 is fully functional and independently testable (quickstart.md §2)

---

## Phase 4: User Story 2 - Sign out securely (Priority: P1)

**Goal**: A signed-in user ends their session on demand with a hard guarantee that no further requests happen on their behalf afterward.

**Independent Test**: Sign in, trigger sign-out, confirm subsequent protected actions require signing in again and no stray refresh call fires.

### Tests for User Story 2 ⚠️

- [X] T031 [P] [US2] Unit test: logout clears session state immediately and aborts/ignores any in-flight or scheduled refresh promise in `hydra-ui/tests/unit/useLogout.test.ts`

### Implementation for User Story 2

- [X] T032 [US2] Add logout/cancellation support to `session-manager` (clear token, invalidate/ignore the in-flight refresh promise) in `hydra-ui/src/lib/session-manager.ts` (depends on T023, T031)
- [X] T033 [US2] Implement `useLogout` hook wrapping `POST /api/v1/auth/logout`, always resolving and clearing local state even on network failure, in `hydra-ui/src/hooks/useLogout.ts` (depends on T032)
- [X] T034 [US2] Wire a sign-out control into the `SessionGate` example usage in `hydra-ui/stories/SessionGate.stories.tsx` (depends on T033, T029)

**Checkpoint**: User Stories 1 and 2 both work independently (quickstart.md §3)

---

## Phase 5: User Story 3 - Manage orders (Priority: P2)

**Goal**: A signed-in user lists/filters/creates/views orders; an elevated user updates status or cancels; non-elevated users cannot.

**Independent Test**: As a standard user, list/filter/create/view orders; as an admin, update status and cancel; confirm status/cancel controls are absent for the standard user.

### Tests for User Story 3 ⚠️

- [X] T035 [P] [US3] Unit test: `useCreateOrder` rejects a blank `orderNumber` or non-positive `totalAmount` before any request is sent, in `hydra-ui/tests/unit/useCreateOrder.test.ts` (per FR-011)
- [X] T036 [P] [US3] Component test: `RequireRole` hides `OrderStatusControl` and `CancelOrderButton` for a `ROLE_USER` session and shows them for `ROLE_ADMIN`, in `hydra-ui/tests/component/RequireRole.test.tsx` (per FR-015)

### Implementation for User Story 3

- [X] T037 [P] [US3] Define `Order` and `OrderStatus` types (per data-model.md's Order entity, matching `OrderResponse` field-for-field) in `hydra-ui/src/types/order.ts`
- [X] T037a [P] [US3] Implement and export `allowedTransitions(current: OrderStatus): OrderStatus[]` mirroring `OrderService.validateStatusTransition` exactly (PENDING→SHIPPED|CANCELLED, SHIPPED→DELIVERED|CANCELLED, DELIVERED/CANCELLED→none) in `hydra-ui/src/lib/order-transitions.ts` (depends on T037)
- [X] T037b [P] [US3] Unit test: `allowedTransitions` returns exactly the backend-permitted set for all four statuses, including empty for terminal ones, in `hydra-ui/tests/unit/order-transitions.test.ts` (per SC-007)
- [ ] T037c [US3] Verify the actual paginated JSON shape returned by `GET /api/orders` against a running order-service (Spring `Page` serialization — confirm the `content` key and page-metadata field names under Boot 4) and record the confirmed shape in `hydra-ui/src/types/page.ts` before `useOrders` is written
  - **Partially done — the live check is still outstanding.** No Node.js/npm runtime and no running services were available on this machine, so the shape was determined by source and jar inspection instead: `OrderController.getOrders` returns `Page<OrderResponse>` directly, and `GeneralConfig` supplies a hand-built `JsonMapper` bean, so Spring Data's `PageModule` (spring-data-commons 4.1.0, which would emit the nested `PagedModel` layout) never applies to it. That means the DIRECT `PageImpl` layout with top-level page metadata. `src/types/page.ts` records that and `normalizePage` **also** accepts the nested `{content, page:{…}}` layout, so a future switch to `VIA_DTO` cannot silently empty every list. Confirm against a running service before release.
- [X] T038 [P] [US3] Implement `RequireRole` component (renders children only if `useSession().hasRole(role)`) in `hydra-ui/src/components/hydra/RequireRole.tsx` (depends on T026)
- [X] T039 [P] [US3] Implement `useOrders` hook wrapping `GET /api/orders`, sending `sort=createdAt,desc` **explicitly** (the backend's `@PageableDefault` sorts ascending, so omitting this silently shows oldest-first and violates FR-009) plus the optional status filter, in `hydra-ui/src/hooks/useOrders.ts` (depends on T037, T037c, T024)
- [X] T040 [P] [US3] Implement `useOrder` hook wrapping `GET /api/orders/{id}` (with a distinct not-found error) in `hydra-ui/src/hooks/useOrder.ts` (depends on T037, T024)
- [X] T041 [US3] Implement `useCreateOrder` hook with client-side validation wrapping `POST /api/orders` in `hydra-ui/src/hooks/useCreateOrder.ts` (depends on T037, T024, T035)
- [X] T042 [US3] Implement `useUpdateOrderStatus` hook wrapping `PATCH /api/orders/{id}/status` in `hydra-ui/src/hooks/useUpdateOrderStatus.ts` (depends on T037, T024)
- [X] T043 [US3] Implement `useCancelOrder` hook wrapping `DELETE /api/orders/{id}` in `hydra-ui/src/hooks/useCancelOrder.ts` (depends on T037, T024)
- [X] T044 [P] [US3] Implement `OrderList` component (table + status filter, per FR-009/FR-010) in `hydra-ui/src/components/hydra/OrderList.tsx` (depends on T039, T018, T017)
- [X] T045 [P] [US3] Implement `OrderDetail` component in `hydra-ui/src/components/hydra/OrderDetail.tsx` (depends on T040, T015)
- [X] T046 [P] [US3] Implement `CreateOrderForm` component in `hydra-ui/src/components/hydra/CreateOrderForm.tsx` (depends on T041, T013, T014)
- [X] T047 [US3] Implement `OrderStatusControl` component, wrapped in `RequireRole("ROLE_ADMIN")`, populating its options from `allowedTransitions(order.status)` rather than the full enum and rendering no actionable control for terminal statuses, in `hydra-ui/src/components/hydra/OrderStatusControl.tsx` (depends on T042, T037a, T038, T017)
- [X] T048 [US3] Implement `CancelOrderButton` component with a confirm dialog, wrapped in `RequireRole("ROLE_ADMIN")`, disabled for already-Delivered/Cancelled orders and refetching after success (the 204 response carries no order data), in `hydra-ui/src/components/hydra/CancelOrderButton.tsx` (depends on T043, T037a, T038, T016)
- [X] T048a [P] [US3] Component test: `OrderStatusControl` offers only backend-valid transitions for a PENDING and a SHIPPED order and nothing actionable for DELIVERED/CANCELLED, in `hydra-ui/tests/component/OrderStatusControl.test.tsx` (per SC-007)
- [X] T049 [P] [US3] Add Storybook stories for `OrderList`, `OrderDetail`, `CreateOrderForm`, `OrderStatusControl`, `CancelOrderButton` in `hydra-ui/stories/Orders.stories.tsx` (depends on T044-T048)

**Checkpoint**: User Stories 1-3 all work independently (quickstart.md §4)

---

## Phase 6: User Story 4 - Provision new accounts (Priority: P3)

**Goal**: Admins register new standard users; super admins register new admins for a tenant; both actions are hidden/blocked for unauthorized roles.

**Independent Test**: As an admin, register a user and sign in as them; as a super admin, register an admin for a tenant; confirm both forms are absent for unauthorized roles.

### Tests for User Story 4 ⚠️

- [X] T050 [P] [US4] Component test: `RegisterAdminForm` is not rendered for a `ROLE_ADMIN` (non-super) session and its submission is never attempted, in `hydra-ui/tests/component/RegisterAdminForm.test.tsx` (per FR-018)

### Implementation for User Story 4

- [X] T051 [P] [US4] Define `Account` type (per data-model.md's Account entity) in `hydra-ui/src/types/account.ts`
- [X] T052 [P] [US4] Implement `useRegisterUser` hook wrapping `POST /api/v1/admin/register-user` in `hydra-ui/src/hooks/useRegisterUser.ts` (depends on T051, T024)
- [X] T053 [P] [US4] Implement `useRegisterAdmin` hook wrapping `POST /api/v1/admin/{tenantId}/register-admin` in `hydra-ui/src/hooks/useRegisterAdmin.ts` (depends on T051, T024)
- [X] T054 [US4] Implement `RegisterUserForm` component, wrapped in `RequireRole("ROLE_ADMIN")`, including the same client-side username/password validation as `LoginForm` (per FR-019), in `hydra-ui/src/components/hydra/RegisterUserForm.tsx` (depends on T052, T038, T013, T014)
- [X] T055 [US4] Implement `RegisterAdminForm` component, wrapped in `RequireRole("ROLE_SUPER_ADMIN")`, including the same client-side username/password validation as `LoginForm` (per FR-019), in `hydra-ui/src/components/hydra/RegisterAdminForm.tsx` (depends on T053, T038, T013, T014, T050)
- [X] T056 [P] [US4] Add Storybook stories for `RegisterUserForm` and `RegisterAdminForm` in `hydra-ui/stories/Provisioning.stories.tsx` (depends on T054, T055)

**Checkpoint**: All four user stories are independently functional (quickstart.md §5)

---

## Phase 7: Polish & Cross-Cutting Concerns

**Purpose**: Package-level finishing work that spans every user story

- [X] T057 [P] Create the public export barrel `hydra-ui/src/index.ts` (all hooks, components, and types intended for consumers)
- [X] T058 [P] Write `hydra-ui/README.md` covering install, `HydraProvider` setup, and a link to quickstart.md's validation scenarios
- [X] T059 [P] Unit test: rate-limit (429 + `Retry-After`), known auth error codes (`invalid_refresh_token`, `refresh_token_reuse_detected`), and business-rule 422s (duplicate order number, invalid transition, cancelling a delivered order) each surface a distinct message across hooks, in `hydra-ui/tests/unit/error-mapping.test.ts` (per FR-020, FR-021, FR-023)
- [X] T059a [P] Verify client-side credential validation mirrors the backend bounds exactly — username 3-50 chars, password 8-100 chars (the 100-char maximum is enforced server-side and must not be omitted) — across `LoginForm`, `RegisterUserForm`, and `RegisterAdminForm`, in `hydra-ui/tests/component/credential-validation.test.tsx` (per FR-019)
- [ ] T059b Confirm both services are reachable from the dev origin end-to-end: preflight `OPTIONS` succeeds, the refresh cookie is attached to `/api/v1/auth/refresh`, and `Retry-After` is readable from a 429 response (requires `hydra.cors.allowed-origins` to include the dev origin)
  - **Blocked: needs both services running and a browser.** Static check done — both `CorsConfig` beans set `allowCredentials(true)`, expose `Retry-After`, and default `hydra.cors.allowed-origins` to `http://localhost:5173`, and both security configs `permitAll()` `OPTIONS /**`. Note for whoever runs this: auth-service allows `X-Tenant-ID` through CORS and order-service deliberately does not, and `REFRESH_COOKIE_SECURE=false` is required over plain HTTP or the browser drops the cookie.
- [X] T060 [P] Verify `hydra-ui/package.json` `exports`/`sideEffects` fields support per-component tree-shaking (per plan.md Performance Goals) — `sideEffects` narrowed to `**/*.css`, `exports` maps `.` (types + import) and `./styles.css`, and the Vite build uses `preserveModules` so a consumer importing one hook does not pull in the order components. Config verified by reading; the build itself was not executed (no Node runtime available), so the emitted `dist/` paths are unconfirmed.
- [X] T061 Security check: grep the package source for any `document.cookie` or storage access referencing the refresh token and confirm none exists (per FR-006, SC-003) — **PASS**: zero occurrences of `document.cookie`, `localStorage`, `sessionStorage` or `indexedDB` anywhere in `hydra-ui/src/`. The only textual matches are the `invalid_refresh_token`/`refresh_token_reuse_detected` error-code literals and a comment. An ESLint rule (`no-restricted-globals` / `no-restricted-properties` in `eslint.config.js`) now fails the build if any of them is introduced.
- [ ] T062 Run quickstart.md end-to-end against local auth-service/order-service (all 6 sections) and record results
  - **Blocked: no Node.js/npm on this machine**, so `npm install`, `npm run test`, `npm run storybook` and `npm run build` could not be executed. Every test file called for by Phase 3–7 exists and is written against MSW, but none has been run — treat the suite as unverified until `npm run test` passes.

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies — start immediately
- **Foundational (Phase 2)**: Depends on Setup — BLOCKS all user stories
- **User Story 1 (Phase 3)**: Depends on Foundational only
- **User Story 2 (Phase 4)**: Depends on Foundational + US1's `session-manager` (T023) — logout is meaningless without login/session state existing first
- **User Story 3 (Phase 5)**: Depends on Foundational + the HTTP client's authenticated-request path (T024 from US1) — order calls need a bearer token to attach, but US3 is otherwise independent of US2
- **User Story 4 (Phase 6)**: Depends on Foundational + T024 (US1), same reasoning as US3; independent of US2 and US3
- **Polish (Phase 7)**: Depends on all desired user stories being complete

### Parallel Opportunities

- All `[P]` Setup tasks (T003-T008) run in parallel after T001-T002
- All `[P]` Foundational tasks (T009-T011, T013-T018) run in parallel after T008; T012 and T019 are sequential within Phase 2
- Once Foundational (Phase 2) completes, US1 can start; US2 needs US1's T023, but US3 and US4 only need US1's T024, so **US3 and US4 can be built in parallel with US2** by different developers
- Within each story, all `[P]`-marked tests and hooks/types that touch different files run in parallel

---

## Parallel Example: User Story 1

```bash
# Tests for User Story 1, in parallel:
Task: "Unit test: session-manager coalesces concurrent refreshes in hydra-ui/tests/unit/session-manager.test.ts"
Task: "Unit test: useLogin success/failure states in hydra-ui/tests/unit/useLogin.test.tsx"
Task: "Component test: LoginForm error states in hydra-ui/tests/component/LoginForm.test.tsx"

# Hooks for User Story 1, in parallel (after their shared dependencies land):
Task: "Implement useSession hook in hydra-ui/src/hooks/useSession.ts"
Task: "Implement useLogin hook in hydra-ui/src/hooks/useLogin.ts"
```

---

## Implementation Strategy

### MVP First (User Story 1 Only)

1. Complete Phase 1: Setup
2. Complete Phase 2: Foundational (blocks everything)
3. Complete Phase 3: User Story 1
4. **STOP and VALIDATE**: run quickstart.md §2 against a real auth-service
5. Demo the sign-in + silent-renewal flow

### Incremental Delivery

1. Setup + Foundational → foundation ready
2. Add US1 (sign in + stay signed in) → validate → MVP demo
3. Add US2 (sign out) → validate → demo
4. Add US3 (order management) → validate → demo
5. Add US4 (account provisioning) → validate → demo
6. Polish phase → package is publish-ready

### Parallel Team Strategy

Once Foundational + US1's T024 land: Developer A takes US2, Developer B takes US3, Developer C takes US4 — all three are independent of each other at that point.

---

## Notes

- `[P]` tasks touch different files and have no incomplete-task dependency
- `[Story]` label maps every user-story-phase task to its spec.md story for traceability
- Tests are included only where the risk (session concurrency, validation, role-gating) justifies them — not a full contract-test-per-endpoint suite, per the project's stated "tests are optional" default
- Commit after each task or logical group
- Stop at any checkpoint to validate a story independently before continuing
