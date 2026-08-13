# Phase 0 Research: Hydra UI Package

All items below were resolvable from the feature spec, the requested technical stack, and the actual auth-service/order-service source — no unresolved `NEEDS CLARIFICATION` markers remain.

## 1. Refresh-token session strategy

- **Decision**: Access token lives only in a module-scoped in-memory variable inside `lib/session-manager.ts`. Refresh token is never read, written, or referenced by name from application code — the browser attaches the `refresh_token` cookie automatically because every request to `/api/v1/auth/*` is issued with `credentials: "include"`. A single shared in-flight `Promise<void>` in the session manager coalesces concurrent refresh needs: the first 401 triggers `POST /api/v1/auth/refresh`; any other request that hits a 401 while that promise is pending awaits the same promise instead of issuing its own refresh call, then retries once the promise resolves.
- **Rationale**: This exactly mirrors what `AuthController.refresh` and `CookieUtil` already implement server-side (httpOnly/Secure/SameSite=Strict cookie, scoped path, rotation on every use) — the spec's "production behavior" requirement (FR-004, FR-005, FR-006, SC-003, SC-005) is satisfied by not re-implementing token storage, only by respecting the contract the backend already enforces.
- **Alternatives considered**: Storing the access token in `localStorage`/`sessionStorage` — rejected, XSS-exposes the token and contradicts FR-006's intent even though FR-006 technically only names the refresh token. Using a third-party auth client (e.g. a generic OIDC library) — rejected, this is a proprietary cookie/JWT contract, not OIDC, and pulling in a generic library would add abstraction the actual contract doesn't need.

## 2. HTTP client shape

- **Decision**: A small `fetch`-based wrapper (`lib/http-client.ts`) rather than axios or a generated OpenAPI client. It injects `X-Tenant-ID` on login only (per `Headers.TENANT_ID` on `AuthController.login`), injects `Authorization: Bearer <token>` from the session manager on every other authenticated call, retries exactly once after a successful coalesced refresh on a 401, and maps the shared `ErrorResponse` shape (`status, error, message, path, timestamp`) into typed error objects the hooks expose.
- **Rationale**: Keeps the package dependency-light (per stated "modern, best-practice" goal) and `fetch` with `credentials: "include"` is sufficient for httpOnly-cookie handling — no library needed for that. No OpenAPI spec exists in this repo for either service, so hand-written types mirroring the actual DTOs (already inspected in source) are more accurate than a generated client would be today.
- **Alternatives considered**: axios — rejected, adds a dependency for interceptor sugar `fetch` can do natively. Auto-generated client from an OpenAPI/Swagger spec — rejected for now (no spec file present in `auth-service`/`order-service`; introducing one is out of scope for this feature).

## 3. Build tooling: Vite 6 library mode vs. Next.js 15

- **Decision**: Vite 6 in library mode (`vite.config.ts` with `build.lib`), emitting ESM + type declarations via `vite-plugin-dts`.
- **Rationale**: The deliverable is a component/hook library other apps import, not a deployed, routable application — SSR page rendering (Next.js's differentiator) is irrelevant to a package with no routes of its own. Vite library mode is the standard, minimal-friction path to a tree-shakeable published package.
- **Alternatives considered**: Next.js 15 — rejected per spec Assumptions (this is a library, not a standalone app); would force consuming apps into Next's routing/runtime assumptions they may not share.

## 4. Styling: Tailwind v4 + Radix + Shadcn pattern

- **Decision**: Tailwind v4 via `@import "tailwindcss";` in `src/styles/index.css` (no `tailwind.config.js`), Radix UI primitives wrapped in Shadcn-style unstyled-then-styled components under `components/ui/`, composed via `clsx` + `tailwind-merge`'s `cn` helper.
- **Rationale**: Directly requested; Radix gives accessible primitives (focus trapping, ARIA) for free on interactive components like the login dialog and confirmation modals for cancel-order, which the spec's edge cases (permission errors, validation errors) need surfaced accessibly.
- **Alternatives considered**: Headless UI — rejected, Radix has broader primitive coverage (needed for Select/Dialog/Toast across the order and admin flows). CSS Modules/vanilla CSS — rejected, contradicts the explicit Tailwind v4 requirement.

## 5. Testing approach for the refresh flow

- **Decision**: MSW (Mock Service Worker) intercepts `fetch` calls in Vitest, allowing tests to script exact sequences (e.g., "protected call → 401 → refresh succeeds → retried call → 200", or "refresh call → 401 → session cleared") without a live backend.
- **Rationale**: The hardest-to-test requirement is concurrency coalescing (FR-005/SC-005) and clean failure handling (FR-008) — both need precise control over response timing/ordering that a real backend integration test can't easily guarantee run after run.
- **Alternatives considered**: Hitting a real running auth-service/order-service in tests — rejected for the package's own unit/component suite (belongs in a future consuming-app's integration tests instead, per the "library, not app" scope decision); mocking `fetch` by hand — rejected, MSW's request-level interception is closer to production behavior and reusable across many test files.

## 6. Rate-limit and error surfacing

- **Decision**: The HTTP client recognizes `status === 429` specifically and exposes `retryAfterSeconds` (parsed from the `Retry-After` header) alongside the generic error, and recognizes the `invalid_refresh_token` / `refresh_token_reuse_detected` `error` codes to distinguish "session expired, please sign in again" from other failures.
- **Rationale**: Confirmed from `RateLimitExceptionHandler` and `AuthErrorCodes` in source — these are real, already-shipped error codes the UI must handle specifically per FR-020/FR-021, not speculative ones.
- **Alternatives considered**: Treating all 4xx/5xx as one generic "something went wrong" — rejected, spec FR-020 explicitly requires a distinct message per known error condition.
