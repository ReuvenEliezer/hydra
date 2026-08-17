---
description: "Task list for 003-tenant-url-resolution"
---

# Tasks: Tenant Resolution from URL

**Input**: Design documents from `/specs/003-tenant-url-resolution/`

**Prerequisites**: [plan.md](./plan.md), [spec.md](./spec.md), [research.md](./research.md), [data-model.md](./data-model.md), [contracts/auth-service-api.md](./contracts/auth-service-api.md), [contracts/hydra-ui-api.md](./contracts/hydra-ui-api.md), [quickstart.md](./quickstart.md)

**Tests**: INCLUDED. plan.md's Technical Context names the suites explicitly (`TenantHostParserTest`, `TenantResolutionIntegrationTest`, `TenantProvisioningIntegrationTest`, plus the modified existing suites) and quickstart.md Step 1 makes a green build the first validation gate. Contracts state assertions directly (SC-006 "no UUID in any state", "no input named `tenantId` in any state").

**Organization**: Grouped by user story. Story order follows spec.md priority (US1 P1 → US2 P2 → US3 P2 → US4 P3).

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (US1, US2, US3, US4)
- Every task names its exact file path

## Path Conventions

Existing multi-module Maven backend + sibling TypeScript package, per plan.md "Source Code (repository root)":

- Backend main: `auth-service/src/main/java/com/reuven/auth/`
- Backend test: `auth-service/src/test/java/com/reuven/auth/`
- Shared POJOs: `infra-shared/src/main/java/com/reuven/`
- Frontend: `hydra-ui/src/`, `hydra-ui/tests/`, `hydra-ui/stories/`, `hydra-ui/demo/`

**Build command** (`mvn` is not on PATH, there is no `./mvnw`):

```bash
export MVN=~/.m2/wrapper/dists/apache-maven-3.9.16-bin/5grr65jo27hi51sujmtcldfovl/apache-maven-3.9.16/bin/mvn
```

---

## Phase 1: Setup (Configuration Surface)

**Purpose**: Introduce the configuration this feature reads, before any code reads it. Nothing here changes behavior on its own.

- [X] T001 Create `TenantResolutionProperties` in `auth-service/src/main/java/com/reuven/auth/config/TenantResolutionProperties.java` — a `@ConfigurationProperties(prefix = "hydra.tenant")` record with `List<String> baseDomains` and `List<String> reservedIdentifiers`, whose compact constructor turns null into `List.of()` and lowercases every entry with `Locale.ROOT` (data-model.md §2); register it exactly the way `CorsProperties` is — an `@EnableConfigurationProperties(TenantResolutionProperties.class)` on the `@Configuration` class that consumes it, mirroring `auth-service/src/main/java/com/reuven/auth/config/CorsConfig.java:37` (there is no `@ConfigurationPropertiesScan` in this service, so an unregistered record binds to nothing and silently fails closed)
- [X] T002 Add `hydra.tenant.base-domains: ${TENANT_BASE_DOMAINS:}` and `hydra.tenant.reserved-identifiers: ${TENANT_RESERVED_IDENTIFIERS:www,api,admin,app,auth,mail,static,cdn,status,support,docs}` plus a `rate-limit.limits.tenant-resolve-ip` entry (`capacity: ${RATE_LIMIT_TENANT_RESOLVE_PER_IP_CAPACITY:30}`, `window: ${RATE_LIMIT_TENANT_RESOLVE_PER_IP_WINDOW:PT1M}`) to `auth-service/src/main/resources/application.yaml`, following the existing `login-ip` entry's comment style; **in the same file** also rename the base CORS key at lines 39–40 from `hydra.cors.allowed-origins: ${CORS_ALLOWED_ORIGINS:http://localhost:5173}` to `hydra.cors.allowed-origin-patterns: ${CORS_ALLOWED_ORIGIN_PATTERNS:http://*.localhost:5173}` and rewrite the comment block above it (lines 36–37) — the record component rename in T020 makes the old key bind to nothing, and an unbound list fails closed silently, which is the one way this change breaks without an error (research.md R4)
- [X] T003 [P] Set `hydra.tenant.base-domains: localhost` and switch `hydra.cors.allowed-origins` to `hydra.cors.allowed-origin-patterns: http://*.localhost:5173,http://*.localhost:6006` in `auth-service/src/main/resources/application-local.yml`
- [X] T004 [P] Set `hydra.tenant.base-domains: localhost` in `auth-service/src/main/resources/application-test.yml` so integration tests exercise the real matching rule (FR-008)
- [X] T005 Document the production values in `auth-service/src/main/resources/application-prod.yml` — note that this file carries **no** `hydra` block today (prod CORS already comes from `application.yaml`'s `${CORS_ALLOWED_ORIGINS}` placeholder), so the prod configuration is the two env vars `TENANT_BASE_DOMAINS=hydra.example.com` and `CORS_ALLOWED_ORIGIN_PATTERNS=https://*.hydra.example.com`; add a commented block naming both rather than a hardcoded `hydra:` section that would override the env placeholders (depends on T002)
- [X] T006 [P] Add `auth-service/src/main/resources/db/changelog/changes/002-tenant-url-identifier.yaml` (adds `tenants.url_identifier` NOT NULL UNIQUE and the `reserved_tenant_identifiers` table) and include it from `auth-service/src/main/resources/db/changelog/db.changelog-master.yaml`, with a header comment stating that Liquibase is not on the classpath and this file is parity documentation only (research.md R5)

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: The schema, the resolution engine, the error vocabulary, and the security/CORS posture that every user story depends on.

**⚠️ CRITICAL**: No user story work can begin until this phase is complete. This phase must end with a compiling, green build (`$MVN -q -pl infra-shared,rate-limit-starter,auth-service -am test`).

- [X] T007 [P] Add `urlIdentifier` to `auth-service/src/main/java/com/reuven/auth/entity/Tenant.java` — `@Column(name = "url_identifier", nullable = false, unique = true, length = 63)`, change the constructor to `Tenant(String name, String urlIdentifier, EntityStatus status)`, and deliberately add **no setter** (data-model.md §1.1)
- [X] T008 [P] Create `auth-service/src/main/java/com/reuven/auth/entity/ReservedTenantIdentifier.java` — table `reserved_tenant_identifiers`, `identifier` as the `@Id` (varchar 63), nullable `tenant_id` UUID with no FK, `reserved_at` timestamp not null; Javadoc must state the row is insert-only and outlives its tenant (FR-012, data-model.md §1.2)
- [X] T009 Add `Optional<Tenant> findByUrlIdentifier(String urlIdentifier)` to `auth-service/src/main/java/com/reuven/auth/repository/TenantRepository.java` (depends on T007)
- [X] T010 Create `auth-service/src/main/java/com/reuven/auth/repository/ReservedTenantIdentifierRepository.java` extending `JpaRepository<ReservedTenantIdentifier, String>` with `boolean existsByIdentifier(String identifier)` (depends on T008)
- [X] T011 [P] Create `auth-service/src/main/java/com/reuven/auth/service/TenantHostParser.java` — pure `Optional<String> extractIdentifier(String hostHeader)` with no Spring types beyond the injected base-domain list: trim → lowercase(`Locale.ROOT`) → strip one trailing dot → strip port including the bracketed IPv6 form → label-boundary suffix match against a configured base domain → require exactly one preceding label → require the RFC 1123 pattern `^[a-z0-9]([a-z0-9-]*[a-z0-9])?$` (data-model.md §3.1)
- [X] T012 [P] Create `auth-service/src/test/java/com/reuven/auth/TenantHostParserTest.java` — a plain JUnit 5 `@ParameterizedTest` table reproducing every row of data-model.md §3.1 (`acme.localhost`, `ACME.LocalHost:5173`, `acme.localhost.`, `acme.hydra.example.com`, bare base domain, `a.b.hydra.example.com`, `notacme.localhost`, `acme.evil.com`, `127.0.0.1:8083`, `[::1]:8083`, `-acme.localhost`, `acme-.localhost`) against base domains `localhost` and `hydra.example.com` (depends on T011)
- [X] T013 [P] Create `auth-service/src/main/java/com/reuven/auth/service/TenantResolution.java` — record `TenantResolution(Status status, UUID tenantId, String displayName)` with nested `enum Status { RECOGNIZED, INACTIVE, UNKNOWN }` and static factories; Javadoc must record that `tenantId` is internal-only and is stripped at the web boundary (data-model.md §3.2, SC-006)
- [X] T014 Create `auth-service/src/main/java/com/reuven/auth/service/TenantResolutionService.java` — reads `HttpHeaders.HOST` with `getServerName()` as fallback (research.md R2), delegates to `TenantHostParser`, looks up `TenantRepository.findByUrlIdentifier`, and maps `ACTIVE` → `RECOGNIZED`, any other status → `INACTIVE`, absent identifier or absent tenant → `UNKNOWN` (depends on T009, T011, T013)
- [X] T015 [P] Add `UNKNOWN_TENANT_ADDRESS = "unknown_tenant_address"` and `TENANT_INACTIVE = "tenant_inactive"` to `auth-service/src/main/java/com/reuven/auth/exception/AuthErrorCodes.java`, updating its class Javadoc which currently scopes itself to the refresh flow
- [X] T016 [P] Create `auth-service/src/main/java/com/reuven/auth/exception/UnknownTenantAddressException.java`
- [X] T017 [P] Create `auth-service/src/main/java/com/reuven/auth/exception/InactiveTenantException.java`
- [X] T018 Add `@ExceptionHandler` methods for both new exceptions to `auth-service/src/main/java/com/reuven/auth/exception/GlobalExceptionHandler.java` — 400 with `message = AuthErrorCodes.UNKNOWN_TENANT_ADDRESS`, 403 with `message = AuthErrorCodes.TENANT_INACTIVE`, reusing the existing `ErrorResponse` shape (research.md R7; depends on T015, T016, T017)
- [X] T019 In `auth-service/src/main/java/com/reuven/auth/config/SecurityCommons.java` `authRules()`, add `.requestMatchers(HttpMethod.GET, "/api/v1/tenant").permitAll()` and `.requestMatchers(HttpMethod.POST, "/api/v1/admin/tenants").hasAuthority(Role.SUPER_ADMIN.authority())`, both before `anyRequest().authenticated()`
- [X] T020 Rename the record component `allowedOrigins` to `allowedOriginPatterns` in `auth-service/src/main/java/com/reuven/auth/config/CorsProperties.java` and rewrite the class Javadoc, which currently states outright that the value "MUST be explicit origins - never a wildcard pattern": patterns (not `"*"`) are what keeps `allowCredentials(true)` legal under per-tenant origins, and an empty list still fails closed (research.md R4; the matching yaml key is renamed in T002 — renaming one without the other binds to nothing, so treat them as a single change)
- [X] T021 In `auth-service/src/main/java/com/reuven/auth/config/CorsConfig.java`, call `config.setAllowedOriginPatterns(...)` instead of `setAllowedOrigins(...)`, remove `Headers.TENANT_ID` from the allowed request headers list and drop the now-unused `com.reuven.Headers` import, and keep the empty-list startup warning (depends on T020)
- [X] T022 [P] Apply the same origin-pattern change to order-service: `order-service/src/main/java/com/reuven/orderservice/config/CorsProperties.java`, `order-service/src/main/java/com/reuven/orderservice/config/CorsConfig.java` (its `X-Tenant-ID` Javadoc note stays accurate — order-service still derives tenant from the JWT), and the `hydra.cors` blocks in `order-service/src/main/resources/application.yaml` and `order-service/src/main/resources/application-local.yml`
- [X] T023 Update `auth-service/src/main/java/com/reuven/auth/service/BootstrapService.java` to create the System Tenant as `new Tenant("System Tenant", "system", EntityStatus.ACTIVE)` and insert its `reserved_tenant_identifiers` row in the same `@Transactional` unit, so the super-admin signs in at `system.localhost` like any other account (contracts/auth-service-api.md §4; depends on T007, T008, T010)
- [X] T024 Fix the constructor arity at every remaining `new Tenant(name, status)` call site so the build compiles: `auth-service/src/test/java/com/reuven/auth/AuthIntegrationTest.java` (lines 56, 62, 218), `auth-service/src/test/java/com/reuven/auth/RefreshFlowIntegrationTest.java` (line 35), `auth-service/src/test/java/com/reuven/auth/ratelimit/RateLimitIntegrationTest.java` (line 55), `auth-service/src/test/java/com/reuven/auth/ratelimit/RateLimitDisabledIntegrationTest.java` (line 40), `integration-tests/src/test/java/com/reuven/integration/AuthOrderCrossServiceIntegrationTest.java` (line 253) — give each fixture tenant a distinct identifier (`system`, `acme`, `other`, …); the no-arg `new Tenant()` uses in `JwksSecurityIntegrationTest` and `SecurityIntegrationTest` are unaffected (depends on T007)

**Checkpoint**: Schema, parser, resolution service, error codes, and CORS posture are in place; the build is green; no endpoint behavior has changed yet.

---

## Phase 3: User Story 1 - Sign in with no tenant field at all (Priority: P1) 🎯 MVP

**Goal**: A user at an active tenant's address signs in with username and password only. The tenant comes from the login request's own `Host`; the page shows the organization's display name; no tenant identifier is displayed, requested, or accepted anywhere.

**Independent Test**: Open `http://acme.localhost:5173`, confirm the heading reads "Sign in to Acme Corp", that no Tenant ID input and no UUID exist in the page source, that `GET /api/v1/tenant` fired once with body `{"status":"recognized","displayName":"Acme Corp"}`, and that submitting valid credentials signs in against Acme with **no** `X-Tenant-ID` on the request (quickstart.md Step 4).

### Backend — resolution at the two entry points

- [X] T025 [P] [US1] Create `auth-service/src/main/java/com/reuven/auth/dto/TenantResolutionResponse.java` — a record serializing to exactly `{status}` or `{status, displayName}`, with `@JsonInclude(NON_NULL)` so `displayName` is omitted (not null, not empty) on non-recognized states — note this service runs Jackson 3 (`tools.jackson.*`, see `GeneralConfig.jsonMapper()`) while the annotation still lives in `com.fasterxml.jackson.annotation`, and a Javadoc stating no field may ever carry the tenant UUID (data-model.md §4.1, SC-006)
- [X] T026 [US1] Create `auth-service/src/main/java/com/reuven/auth/controller/TenantController.java` — public `GET /api/v1/tenant` returning `200` with `TenantResolutionResponse` for all three outcomes, annotated `@RateLimited(limit = "tenant-resolve-ip", key = "T(com.reuven.ratelimit.ClientIpResolver).resolve(#httpRequest)")` per research.md R6 (depends on T014, T025)
- [X] T027 [US1] Change `AuthService.login` in `auth-service/src/main/java/com/reuven/auth/service/AuthService.java` to take the resolved tenant UUID from the caller instead of a client-supplied one; everything downstream of `findWithRolesByTenantIdAndUsername` is unchanged (depends on T014)
- [X] T028 [US1] In `auth-service/src/main/java/com/reuven/auth/controller/AuthController.java`, delete `@RequestHeader(Headers.TENANT_ID) UUID tenantId` and its `com.reuven.Headers` import, resolve the tenant from the request via `TenantResolutionService` **after** the existing rate-limit dimensions and **before** any credential lookup, throwing `UnknownTenantAddressException` / `InactiveTenantException` on the non-recognized outcomes (contracts/auth-service-api.md §2; depends on T016, T017, T027)
- [X] T029 [US1] Delete `infra-shared/src/main/java/com/reuven/Headers.java` — `TENANT_ID` is its only member, and its removal is what makes any surviving sender a compile error rather than a silently ignored header (data-model.md §5; depends on T021, T028)
- [X] T030 [US1] In `auth-service/src/test/java/com/reuven/auth/AuthIntegrationTest.java`, replace every `.header(Headers.TENANT_ID, ...)` with `.header(HttpHeaders.HOST, "<identifier>.localhost")` (lines 105, 117, 128, 141, 278), delete the "Missing X-Tenant-ID header returns 400" test at line 148, and drop the `com.reuven.Headers` import (research.md R2 confirms `MockHttpServletRequest` derives `getServerName()` from a set `Host` header; depends on T024, T028)
- [X] T031 [P] [US1] Same substitution in `auth-service/src/test/java/com/reuven/auth/RefreshFlowIntegrationTest.java` (line 44) — refresh and logout themselves stay untouched, only the login that seeds the flow changes (depends on T024, T028)
- [X] T032 [P] [US1] Same substitution in `auth-service/src/test/java/com/reuven/auth/ratelimit/RateLimitIntegrationTest.java` (lines 73, 80, 103, 110, 120) and `auth-service/src/test/java/com/reuven/auth/ratelimit/RateLimitDisabledIntegrationTest.java` (line 54) (depends on T024, T028)
- [X] T033 [P] [US1] Replace `headers.set(Headers.TENANT_ID, ...)` with a `Host` header at `integration-tests/src/test/java/com/reuven/integration/AuthOrderCrossServiceIntegrationTest.java:287` and drop the import (depends on T024, T028)
- [X] T034 [US1] Create `auth-service/src/test/java/com/reuven/auth/TenantResolutionIntegrationTest.java` covering the recognized path: `GET /api/v1/tenant` with `Host: acme.localhost` returns `200 {"status":"recognized","displayName":"Acme Corp"}`, the serialized body contains **no** UUID-shaped string, case-insensitivity (`ACME.localhost`) and trailing-dot (`acme.localhost.`) both still resolve, and the `tenant-resolve-ip` limit returns `429` with `Retry-After` past capacity (FR-015, FR-016, SC-006; depends on T026)

### Frontend — remove the field, add the lookup

- [X] T035 [P] [US1] Create `hydra-ui/src/lib/tenant-resolution.ts` — a `fetchTenantResolution(apiBaseUrl, signal)` that GETs `/api/v1/tenant` unauthenticated and normalizes the response into `{status, displayName}`, treating network failures, 5xx, and 429 as a distinct `error` outcome rather than `unknown` (research.md R8)
- [X] T036 [US1] Create `hydra-ui/src/hooks/useTenant.ts` exporting `TenantStatus` (`"resolving" | "recognized" | "inactive" | "unknown" | "error"`), `TenantState`, and `useTenant(): TenantState` reading the provider context (contracts/hydra-ui-api.md §2; depends on T035)
- [X] T037 [US1] In `hydra-ui/src/components/HydraProvider.tsx`, delete the `tenantId` prop and `HydraContextValue.tenantId` (including the `useOrdersClient` `tenantId: ""` workaround at line 84), add a `tenant: TenantState` context field populated by exactly one mount-time `fetchTenantResolution` call guarded with the same `useRef` StrictMode idiom as the existing `restoreSession()` and issued in parallel with it, and document on `apiBaseUrl` that it MUST point at the same tenant host the page is served from (research.md R1; depends on T036)
- [X] T038 [P] [US1] In `hydra-ui/src/lib/http-client.ts`, remove `HttpClientOptions.tenantId`, `RequestOptions.sendTenantHeader`, `RequestOptions.tenantId`, the `headers["X-Tenant-ID"] = …` assignment at line 86, and the module Javadoc paragraph describing the header (contracts/hydra-ui-api.md §5)
- [X] T039 [US1] Narrow `login` to `(username: string, password: string) => Promise<void>` in `hydra-ui/src/hooks/useLogin.ts`, dropping the per-call tenant override and the `sendTenantHeader` request option (depends on T038)
- [X] T040 [US1] In `hydra-ui/src/components/hydra/LoginForm.tsx`, delete the Tenant ID `<Input>` (lines 77–81), the `defaultTenantId` prop, the `tenantId`/`tenantIdError` state and its blank-check, and the `useHydraContext().tenantId` read; render the username/password form only on `recognized` with a default heading incorporating `displayName` ("Sign in to Acme Corp", still overridable by the `title` prop), and a neutral loading state on `resolving` (FR-017; depends on T036, T039)
- [X] T041 [US1] Export `useTenant` and its `TenantState` / `TenantStatus` types from `hydra-ui/src/index.ts` (depends on T036)
- [X] T042 [US1] In `hydra-ui/tests/mocks/handlers.ts`, add a `GET /api/v1/tenant` handler returning `{"status":"recognized","displayName":"Acme Corp"}` by default and delete the missing-`X-Tenant-ID` → 400 branch at lines 114–115
- [X] T043 [US1] Remove the `tenantId` prop from the provider in `hydra-ui/tests/test-utils.tsx` (depends on T037)
- [X] T044 [US1] Invert the tenant-header test in `hydra-ui/tests/unit/useLogin.test.tsx` (line 36): assert the login request carries **no** `X-Tenant-ID` header at all, and update the `login()` call sites to the two-argument signature (depends on T039, T042, T043)
- [X] T045 [US1] In `hydra-ui/tests/component/LoginForm.test.tsx`, assert the `recognized` state renders the display name in the heading, renders exactly the username and password inputs, and that no input named `tenantId` and no UUID-shaped string appears anywhere in the rendered output (SC-001, Story 1 scenario 2; depends on T040, T042, T043)
- [X] T046 [P] [US1] In `hydra-ui/demo/App.tsx`, derive `apiBaseUrl` and `ordersBaseUrl` from `window.location.hostname` instead of fixed origins, delete the `VITE_HYDRA_TENANT_ID` fallback UUID at line 14 and the `tenantId` provider prop, and remove `VITE_HYDRA_TENANT_ID` from `hydra-ui/.env.local`
- [X] T047 [P] [US1] Add `server.allowedHosts` permitting `.localhost` hosts (and bind `server.host`) in `hydra-ui/vite.demo.config.ts` so `acme.localhost:5173` reaches the dev server instead of being rejected by Vite's DNS-rebinding guard (research.md R3)
- [X] T048 [P] [US1] In `hydra-ui/stories/hydra-decorator.tsx`, delete `STORY_TENANT_ID` (lines 19–20) and the `tenantId` provider prop (line 27), and mock `GET /api/v1/tenant` as `recognized` for the default decorator

**Checkpoint**: User Story 1 is fully functional — a user signs in at a tenant address with no tenant field anywhere, and the organization name is shown before submission.

---

## Phase 4: User Story 2 - Super-admin operates across every tenant from one sign-in (Priority: P2)

**Goal**: A super-admin's login resolves strictly to their own home tenant's address like any other account, while their post-login cross-tenant authority is unchanged. This story is largely a *proof of non-regression* — FR-007 and FR-010 require that nothing in the JWT-derived tenant path changes.

**Independent Test**: Sign in as the super-admin at `system.localhost`, then register an admin into a different tenant via `POST /api/v1/admin/{tenantId}/register-admin` and confirm `201` (quickstart.md Step 6).

- [X] T049 [US2] Add a test to `auth-service/src/test/java/com/reuven/auth/AuthIntegrationTest.java` asserting that a super-admin logging in with `Host: system.localhost` receives a token whose `tenantId` claim is the System Tenant, and that the same super-admin's credentials at `Host: acme.localhost` do **not** authenticate (login resolution is strictly per-address, never bypassed by role — FR-010, spec Story 2 scenario 2; depends on T023, T030)
- [X] T050 [US2] Add a cross-tenant test to `integration-tests/src/test/java/com/reuven/integration/AuthOrderCrossServiceIntegrationTest.java`: after a `Host`-resolved super-admin login, `POST /api/v1/admin/{otherTenantId}/register-admin` returns `201`, and an order-service call carrying that token still derives its tenant from the JWT claim with no tenant header in sight (FR-007, SC-005; depends on T033)
- [X] T051 [P] [US2] In `hydra-ui/stories/Provisioning.stories.tsx`, replace the `STORY_TENANT_ID` import and the `defaultTenantId={STORY_TENANT_ID}` prop (lines 7, 46) with a literal fixture UUID — `RegisterAdminForm.defaultTenantId` is an authenticated admin form naming a *target* tenant and is explicitly out of scope, so only the removed story constant changes (depends on T048)

**Checkpoint**: Super-admin login resolves per-address while cross-tenant authority is provably intact.

---

## Phase 5: User Story 3 - Clear error on an unrecognized address (Priority: P2)

**Goal**: An address that resolves to no tenant, or to an inactive one, produces a distinct, actionable state at page load — before any credentials exist to submit — and fails closed at the login endpoint independently of the page.

**Independent Test**: Open `http://nosuch.localhost:5173` and confirm an "address isn't recognized" message with **no** form rendered; deactivate Acme and confirm `http://acme.localhost:5173` shows a third, distinct message; `curl` login at `nosuch.localhost:8083` returns `400 unknown_tenant_address`, never `401` (quickstart.md Step 5).

- [X] T052 [US3] Extend `auth-service/src/test/java/com/reuven/auth/TenantResolutionIntegrationTest.java` with the non-recognized outcomes: `Host: nosuch.localhost` → `{"status":"unknown"}`, bare `Host: localhost` → `unknown`, `Host: a.b.localhost` → `unknown`, `Host: acme.evil.com` (unconfigured base domain) → `unknown`, a non-`ACTIVE` tenant → `{"status":"inactive"}` with **no** `displayName`, and assert every one of the three bodies is `200` and contains no UUID-shaped string (FR-014, FR-015, SC-006; depends on T034)
- [X] T053 [US3] Extend `auth-service/src/test/java/com/reuven/auth/AuthIntegrationTest.java` with the login fail-closed cases: unresolvable `Host` → `400` with `message: "unknown_tenant_address"`, inactive tenant's `Host` → `403` with `message: "tenant_inactive"`, and a valid-credentials-on-unknown-host case proving no login is ever attributed to another tenant (FR-004, FR-005, FR-006, SC-002; depends on T018, T028, T030)
- [X] T054 [P] [US3] Add `"unknown_tenant_address"` and `"tenant_inactive"` to the `ApiErrorCode` union and the `AuthError` code union in `hydra-ui/src/types/errors.ts`
- [X] T055 [US3] Map both new codes in `hydra-ui/src/lib/normalize-error.ts` alongside the existing `GlobalExceptionHandler` codes, so a login attempted against an address that stopped resolving between page load and submit surfaces a distinct message rather than "Incorrect username or password" (depends on T054)
- [X] T056 [US3] In `hydra-ui/src/components/hydra/LoginForm.tsx`, render `unknown`, `inactive`, and `error` as three distinct messages with **no form at all** — not a disabled submit button, since FR-006 and Story 3 require that no submission path exists which could be misattributed; `error` must never reuse the `unknown` copy (contracts/hydra-ui-api.md §4; depends on T040)
- [X] T057 [US3] Add `unknown`/`inactive` response variants to the `GET /api/v1/tenant` handler in `hydra-ui/tests/mocks/handlers.ts`, plus a failing variant for the `error` path (depends on T042)
- [X] T058 [US3] Extend `hydra-ui/tests/component/LoginForm.test.tsx` with coverage of all five statuses (`resolving`, `recognized`, `inactive`, `unknown`, `error`), asserting that the three failure states render no form and that no `tenantId` input and no UUID-shaped string appears in **any** state (depends on T045, T056, T057)
- [X] T059 [P] [US3] Add the two new codes to `hydra-ui/tests/unit/normalize-error.test.ts` and `hydra-ui/tests/unit/error-mapping.test.ts` (depends on T055)
- [X] T060 [P] [US3] Add stories for all five tenant states to `hydra-ui/stories/LoginForm.stories.tsx`, each mocking the lookup accordingly (depends on T048, T056)

**Checkpoint**: Unrecognized, inactive, and lookup-error addresses are distinct and actionable at both the page and the endpoint.

---

## Phase 6: User Story 4 - Operator provisions a working sign-in address for a new tenant (Priority: P3)

**Goal**: A super-admin creates a tenant with an explicit URL identifier, validated for format, reserved words, and permanent uniqueness — and its sign-in address works immediately with no further step.

**Independent Test**: `POST /api/v1/admin/tenants {"name":"Acme Corp","urlIdentifier":"acme"}` returns `201`, and `GET /api/v1/tenant` at `acme.localhost` returns `recognized` with no configuration in between (quickstart.md Step 3 → Step 4, SC-004).

- [X] T061 [P] [US4] Create `auth-service/src/main/java/com/reuven/auth/dto/CreateTenantRequest.java` — `{name, urlIdentifier}` with `@NotBlank`, `@Size(max = 100)` on `name` and `@NotBlank`, `@Size(max = 63)`, `@Pattern(regexp = "^[a-z0-9]([a-z0-9-]*[a-z0-9])?$")` on `urlIdentifier` so format failures land on the existing `MethodArgumentNotValidException` handler as `400` (data-model.md §4.2)
- [X] T062 [P] [US4] Create `auth-service/src/main/java/com/reuven/auth/dto/TenantResponse.java` — `{id, name, urlIdentifier}`; Javadoc must note this admin-only surface deliberately carries the UUID, unlike the public lookup (data-model.md §4.3)
- [X] T063 [US4] Create `auth-service/src/main/java/com/reuven/auth/service/TenantProvisioningService.java` — one `@Transactional` method that rejects a `hydra.tenant.reserved-identifiers` match and an existing `reserved_tenant_identifiers` row with `BusinessRuleException` (422), then saves the `Tenant` and its reservation row together, letting the primary-key violation resolve a concurrent double-claim at the database rather than by check-then-write (FR-012, FR-013, contracts/auth-service-api.md §3; depends on T007, T010, T061)
- [X] T064 [US4] Add `POST /api/v1/admin/tenants` returning `201` with `TenantResponse` to `auth-service/src/main/java/com/reuven/auth/controller/AdminController.java`, annotated `@PreAuthorize(Roles.SUPER_ADMIN_ONLY)` consistently with the existing admin endpoints (depends on T062, T063)
- [X] T065 [US4] Create `auth-service/src/test/java/com/reuven/auth/TenantProvisioningIntegrationTest.java` covering: `201` happy path; `400` on `-bad-` and on `ADMIN` (uppercase fails the pattern before the reserved check); `422` on `admin` (reserved word) and on an already-claimed identifier; `403` for a non-super-admin caller; and the permanence half of FR-012 — delete the tenant row directly, re-POST the same identifier, and assert it **still** returns `422` (quickstart.md Step 3; depends on T064)
- [X] T066 [US4] Add an end-to-end assertion — in `auth-service/src/test/java/com/reuven/auth/TenantProvisioningIntegrationTest.java` — that immediately after a `201`, `GET /api/v1/tenant` with `Host: <urlIdentifier>.localhost` returns `recognized` with the new tenant's name, with no configuration step in between (SC-004; depends on T065)

**Checkpoint**: All four user stories are independently functional.

---

## Phase 7: Polish & Cross-Cutting Concerns

- [X] T067 [P] Update `README.md` — remove the `-H "X-Tenant-ID: <tenant-uuid-from-step-3>"` curl at line 102, document the `*.localhost` sign-in addresses, the tenant-provisioning endpoint, and the `/etc/hosts` fallback for browsers that do not resolve `*.localhost` natively (research.md R3)
- [X] T068 [P] Update `hydra-ui/README.md` — delete the `tenantId` required-prop section (lines 59–60), document the `useTenant` hook and its five statuses, and state the `apiBaseUrl` same-tenant-host requirement as the one way a consumer can silently break the feature (research.md R1)
- [X] T069 Grep the repository for surviving `X-Tenant-ID`, `Headers.TENANT_ID`, `sendTenantHeader`, `defaultTenantId` on `LoginForm`, and `VITE_HYDRA_TENANT_ID` references outside `specs/`, and confirm each remaining hit is intentional (`RegisterAdminForm.defaultTenantId` and order-service's explanatory Javadoc are the only expected survivors)
- [X] T070 Run the backend suite: `$MVN -q -pl infra-shared,rate-limit-starter,auth-service -am test`, then the cross-service suite in `integration-tests/` — **GREEN.** Full reactor: 119 tests, 0 failures, 0 errors, `BUILD SUCCESS` across all 7 modules. New suites: `Public tenant resolution lookup` 12/12, `Tenant provisioning` 15/15, `TenantHostParserTest` 28/28, `Auth Integration Tests` 18/18 (incl. the 5 new address-resolution cases), `Cross-service` 3/3.

  Two prerequisites, neither a code defect but both required to reproduce:
  1. `export JWT_PRIVATE_KEY_PATH="$(pwd)/keys/jwt-private-key-local.pem"` — `BaseIntegrationTest` aborts every context load with `No JWT key found (env or test resource)` otherwise. There is no `auth-service/src/test/resources/test-private-key.pem`; CI generates an ephemeral key per run.
  2. Wipe the local H2 file first (`rm -f ~/data/auth_db.mv.db ~/data/auth_db.trace.db`). `ddl-auto: update` cannot add a `NOT NULL` column to an existing populated table, so it silently skips it and every insert then fails with `Column "url_identifier" not found`. This is the wipe the spec's Assumptions already require.

  One real defect found and fixed by running this: `AuthOrderCrossServiceIntegrationTest.seedTenantAndAdmin()` seeds the same `crossco` identifier on every test method, which was harmless before `url_identifier` was unique and now collides — both between methods in one run and across runs, since the local-profile H2 file outlives the JVM. Added a `@BeforeEach` clearing users then tenants; verified idempotent over two consecutive runs.
- [~] T071 [P] Run the frontend suite: `cd hydra-ui && npm test && npx tsc --noEmit` — **PARTIAL: blocked on a pre-existing harness bug.** `tsc --noEmit` reports exactly two errors, both in files this feature does not touch (`src/components/ui/Card.tsx`, `vitest.config.ts`) and both present on a clean tree. `npm test`: verified green are `useLogin.test.tsx` (7/7, including the inverted no-tenant-header assertion), `normalize-error.test.ts` (10/10, including the two new tenant codes), and the new error-mapping case. The rest — including all of `LoginForm.test.tsx` — is blocked by a **pre-existing** jsdom/msw incompatibility: under the `jsdom` environment `globalThis.AbortSignal` is jsdom's class while `globalThis.Request` is Node 24's native undici, so any fetch carrying a signal throws `Expected signal to be an instance of AbortSignal`. Baseline on an untouched tree: **40 tests already failing across 12 of 15 files.** It hits this feature because `tenant-resolution.ts` aborts its lookup on unmount, so the lookup always lands in the `error` state under test. The fix (install `undici`, add the standard msw-v2 global polyfill to `tests/setup.ts`) is test-harness-only and deliberately not folded into this feature — see the spawned task.

  **Node is not on PATH for tooling here**; prefix commands with `export PATH="$HOME/Library/Application Support/JetBrains/IntelliJIdea2026.2/node/versions/24.19.0/bin:$PATH"`.
- [ ] T072 Execute the full [quickstart.md](./quickstart.md) walkthrough end to end (wipe `~/data/auth_db.mv.db` first), ticking every row of its success-criteria checklist (SC-001 … SC-006) — **NOT RUN: requires running services and a browser**, neither available in the implementing session. This is the remaining acceptance gate; run it before merging, and note the DB must be wiped first (`rm -f ~/data/auth_db.mv.db ~/data/auth_db.trace.db`) because `url_identifier` is `NOT NULL` with no backfill.

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: no dependencies — start immediately
- **Foundational (Phase 2)**: depends on Setup (T001 supplies the properties T011/T014/T063 read) — **BLOCKS all user stories**
- **US1 (Phase 3)**: depends on Foundational
- **US2 (Phase 4)**: depends on Foundational + T023 (System Tenant identifier) + US1's `Host`-based login (T028, T030, T033)
- **US3 (Phase 5)**: depends on Foundational + US1's controller wiring (T028) and its baseline test/mocks (T034, T042, T045)
- **US4 (Phase 6)**: depends on Foundational only — the provisioning endpoint is genuinely independent of the login path
- **Polish (Phase 7)**: depends on the stories you intend to ship

### User Story Dependencies

- **US1 (P1)**: no dependency on another story. The MVP.
- **US2 (P2)**: leans on US1's login path for its own test setup, but proves an *unchanged* capability — it adds no production code, which is the point (FR-007).
- **US3 (P2)**: shares three files with US1 (`LoginForm.tsx`, `handlers.ts`, `LoginForm.test.tsx`) and the two integration test classes; sequence it after US1 rather than in parallel.
- **US4 (P3)**: the only story that can be built fully in parallel with US1 — different controller, different service, different test class, no shared files.

### Within Each User Story

- Entities → repositories → services → controllers → tests
- Frontend: `lib/` → `hooks/` → `components/` → `tests/` → `stories/`
- The story is done when its Independent Test passes without any later story's code

### Parallel Opportunities

- **Phase 1**: T003, T004, T006 all touch different files (T005 documents the same env vars T002 introduces, so sequence it after T002)
- **Phase 2**: three independent clusters — {T007, T008} entities, {T011, T012, T013} parsing, {T015, T016, T017} exceptions; T020/T021 (auth CORS) and T022 (order-service CORS) touch different modules and can run alongside each other
- **Phase 3**: T031, T032, T033 (three separate test classes); T035, T038, T046, T047, T048 (five separate frontend files)
- **Cross-story**: US4 (T061–T066) can run alongside all of US1 with a second developer

---

## Parallel Example: Phase 2 Foundational

```bash
# Entities and pure logic, all different files:
Task: "Add urlIdentifier to auth-service/src/main/java/com/reuven/auth/entity/Tenant.java"
Task: "Create auth-service/src/main/java/com/reuven/auth/entity/ReservedTenantIdentifier.java"
Task: "Create auth-service/src/main/java/com/reuven/auth/service/TenantHostParser.java"
Task: "Create auth-service/src/main/java/com/reuven/auth/service/TenantResolution.java"

# Error vocabulary, all different files:
Task: "Add the two codes to auth-service/src/main/java/com/reuven/auth/exception/AuthErrorCodes.java"
Task: "Create auth-service/src/main/java/com/reuven/auth/exception/UnknownTenantAddressException.java"
Task: "Create auth-service/src/main/java/com/reuven/auth/exception/InactiveTenantException.java"
```

## Parallel Example: User Story 1 frontend

```bash
Task: "Create hydra-ui/src/lib/tenant-resolution.ts"
Task: "Remove tenant plumbing from hydra-ui/src/lib/http-client.ts"
Task: "Derive base URLs from window.location.hostname in hydra-ui/demo/App.tsx"
Task: "Allow *.localhost hosts in hydra-ui/vite.demo.config.ts"
Task: "Drop STORY_TENANT_ID from hydra-ui/stories/hydra-decorator.tsx"
```

---

## Implementation Strategy

### MVP First (User Story 1 only)

1. Phase 1 Setup (T001–T006)
2. Phase 2 Foundational (T007–T024) — **must end green**
3. Phase 3 User Story 1 (T025–T048)
4. **STOP and VALIDATE**: quickstart.md Step 4 at `http://acme.localhost:5173` (provision the Acme tenant by hand or via `BootstrapService` until US4 lands)
5. This alone retires the UUID-typing problem the temporary field exists to work around

### Incremental Delivery

1. Setup + Foundational → resolution engine exists, nothing behaves differently yet
2. + US1 → **MVP**: sign-in with no tenant field, organization name shown
3. + US3 → the safety net: unrecognized/inactive/error states, login fails closed
4. + US2 → proven non-regression on cross-tenant super-admin reach
5. + US4 → self-service provisioning, closing SC-004's "no manual step"

Note the delivery order differs from the phase order: US3 is the natural second increment because it completes US1's safety story, while US2 adds no production code. Phases are numbered by spec priority; ship in whichever order suits the team.

### Parallel Team Strategy

1. Everyone on Setup + Foundational
2. Then: Developer A on US1 (the whole login path, backend + frontend); Developer B on US4 (provisioning — no shared files with US1)
3. US3 follows US1 on the same developer (three shared files); US2 is a test-only pass either can pick up

---

## Notes

- **The single highest-risk mistake in this feature** (research.md R1): the front-end must call auth-service on the *same tenant host it is served from*. A page at `acme.localhost:5173` calling `http://localhost:8083` sends `Host: localhost:8083`, which resolves to `unknown` — the UI looks correct and every login fails closed. T037 and T046 are where this is enforced; T068 is where it is documented.
- **FR-011 is not code in this repository.** The edge layer must forward the original `Host` unmodified; that requirement is levied on `002-cors-edge-hardening`, which owns the browser-edge ownership decision. It is surfaced here, not settled.
- The database must be wiped before first boot (`rm -f ~/data/auth_db.mv.db ~/data/auth_db.trace.db`) — `url_identifier` is `NOT NULL` from day one with no backfill, per the spec's Assumptions.
- Schema comes from Hibernate `ddl-auto: update`, not Liquibase; T006's changelog file is parity documentation that never executes (research.md R5).
- [P] tasks touch different files and have no incomplete dependency
- Commit after each task or logical group; stop at any checkpoint to validate a story independently
