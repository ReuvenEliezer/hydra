# Implementation Plan: Tenant Resolution from URL

**Branch**: `003-tenant-url-resolution` | **Date**: 2026-08-13 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/003-tenant-url-resolution/spec.md`

## Summary

Replace the temporary, user-typed Tenant ID (a raw UUID sent as `X-Tenant-ID` on login) with server-side tenant resolution from the incoming request's `Host` header. auth-service gains a `Tenant URL Identifier` (a required, unique, permanently-reserved DNS label on every tenant), a host-parsing rule driven by a per-environment list of allowed base domains, a public unauthenticated `GET /api/v1/tenant` lookup that the sign-in page calls on load (returning `recognized` / `inactive` / `unknown` plus a display name, never a UUID), and a super-admin tenant-provisioning endpoint that validates the identifier's format, reserved-word list, and permanent uniqueness at creation time. `@hydra/ui` drops the Tenant ID field, the `HydraProvider.tenantId` prop, the `useLogin` tenant override, and the `X-Tenant-ID` plumbing entirely, and renders three distinct load-time states from the lookup.

The load-bearing constraint that shapes everything below: **the tenant is whatever host the login request itself is addressed to**, not the host of the page. The front-end must therefore reach auth-service at the *same* tenant host it is served from (`acme.localhost:5173` → `acme.localhost:8083` in development; one host through the edge in production), and no component in the path may rewrite `Host` (spec FR-011).

## Technical Context

**Language/Version**: Java 25 (backend), TypeScript 5.6+ strict (frontend package).

**Primary Dependencies**: Spring Boot 4.1 (Web MVC, Data JPA, Security), Lombok, existing `rate-limit-starter` (Bucket4j + Redis, consumed via `@RateLimited` + one config entry — no changes to the starter itself); React 19 + Vite 6 library mode on the `@hydra/ui` side.

**Storage**: PostgreSQL (prod/test profiles) / H2 file (local profile), via Spring Data JPA. Schema is created by Hibernate `ddl-auto: update` — **Liquibase is not on the classpath**; `db/changelog/**` is currently inert documentation (see [research.md](./research.md) R5). Two schema changes: a required unique `tenants.url_identifier`, and a new `reserved_tenant_identifiers` allocation table that makes FR-012's "never reuse" durable. No migration or backfill: per spec Assumptions the database is wiped.

**Testing**: JUnit 5 + MockMvc integration tests over Testcontainers (`BaseIntegrationTest` + `TestContainersConfig`, `@ActiveProfiles("test")`), plus plain unit tests for the pure host-parsing logic; Vitest + React Testing Library + MSW on the frontend, with new handlers for `GET /api/v1/tenant`.

**Target Platform**: Linux/JVM services behind an edge layer; evergreen browsers for the package.

**Project Type**: Existing multi-module Maven backend (`auth-service` is the only service touched) + the sibling `hydra-ui/` TypeScript package.

**Performance Goals**: Resolution adds at most one indexed single-row lookup (`tenants.url_identifier`, unique index) to login and one to the public lookup; the sign-in page performs exactly one resolution call per mount, in parallel with the existing silent `restoreSession()`.

**Constraints**:

- Resolution input is the `Host` header of the request being served, read as `getHeader("Host")` with `getServerName()` as fallback (HTTP/2 `:authority`); matching ignores port and is case-insensitive (FR-015).
- The public lookup response carries **only** `{status, displayName?}` — no tenant UUID in any state (FR-014, SC-006), and nothing in it may be echoed back by the browser as a tenant override.
- Unresolvable/inactive hosts must fail closed at both entry points: the page blocks submission, and login itself rejects with codes distinct from `invalid_credentials` (FR-004, FR-005, FR-006).
- A super-admin's cross-tenant authorization is untouched — resolution governs login only (FR-010). Nothing in `AdminController`/`OrderController`'s JWT-derived tenant path changes (FR-007).
- Browser origins are now per-tenant subdomains, so CORS must move from a fixed `allowedOrigins` list to `allowedOriginPatterns` (wildcard origins are illegal alongside the `allowCredentials(true)` the refresh cookie requires — see research.md R4).

**Scale/Scope**: One backend service (auth-service), one frontend package. New public surface: `GET /api/v1/tenant` and `POST /api/v1/admin/tenants`. Removed public surface: the `X-Tenant-ID` login header and `infra-shared`'s `Headers` class.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

**Principle I — Framework-Free Shared Core**: `infra-shared` is only *reduced* by this feature (`Headers.TENANT_ID` is its sole constant and becomes dead once login stops reading the header). No framework type is added anywhere in it. **PASS.**

**Principle II — Dedicated Modules for Cross-Cutting Concerns**: no new module. Tenant resolution is auth-service domain logic, not a cross-cutting infrastructure concern: it is consumed by exactly one service (order-service and every other authenticated endpoint derive tenant from the JWT `tenantId` claim and are explicitly out of scope per FR-007), and it depends on auth-service's own JPA entities. The one genuine cross-cutting concern this feature touches — rate limiting on the public lookup (FR-016) — is consumed exactly as `rate-limit-starter` was designed for: one `@RateLimited` annotation plus one `rate-limit.limits.*` entry, no changes to the starter. **PASS.**

**Principle III — Load-Path-Authoritative Paths**: no classpath resource directories are renamed or restructured; no new Lua scripts. The inert `db/changelog/**` tree is updated in place for parity, not moved. **PASS.**

**Principle IV — Atomic Distributed State Mutations**: no new Redis state. The provisioning-time "claim this identifier forever" mutation is *relational*, not distributed, and is made atomic by a single `@Transactional` unit plus a primary-key/unique constraint on `reserved_tenant_identifiers` — the database rejects the race rather than application code checking-then-writing. **PASS.**

**Principle V — Audit Before Building**: this plan was written against source, not README/prior docs. Confirmed rather than assumed:

- `AuthController.login` takes `@RequestHeader(Headers.TENANT_ID) UUID tenantId` with no default; `AuthService.login(request, tenantId)` uses it for `findWithRolesByTenantIdAndUsername`. Both change.
- `Tenant` (`auth-service/.../entity/Tenant.java`) has only `id`, `name`, `status`, `createdAt`; `TenantRepository` is a bare `JpaRepository` with no finders.
- **There is no tenant-provisioning endpoint at all today.** Tenants are created only by `BootstrapService` ("System Tenant"), which is `@Profile({"local"})`. User Story 4 therefore requires building provisioning, not extending it.
- **Liquibase is not a dependency of `auth-service`**; `db.changelog-master.yaml` never runs. Schema comes from `ddl-auto: update` in every profile.
- Rate limiting is declarative (`@RateLimited(limit, key)` + `rate-limit.limits.<name>` map, `ClientIpResolver` honoring `X-Forwarded-For`) — a new endpoint needs no new Java infrastructure.
- Public paths are enumerated explicitly in `SecurityCommons.authRules()`; the new lookup must be added there or it 401s.
- CORS in both services uses `config.setAllowedOrigins(...)` with `allowCredentials(true)`, and auth-service allows `X-Tenant-ID` as a request header — both need to change.
- `GlobalExceptionHandler` already owns the error-body shape; new failure modes plug in as handlers rather than new body layouts.

**Surfaced dependency (Principle V, second clause)**: FR-011 (edge preserves `Host` end-to-end) and the CORS change below both land inside the territory `002-cors-edge-hardening` exists to decide — specifically *who owns the browser-edge policy* and whether a gateway fronts the services. This feature does **not** settle that. It does the minimum that makes URL resolution work in the topologies that exist today (direct-to-service local development, and a `Host`-preserving edge in production), and records FR-011 as a requirement that 002 must honor whichever ownership model it picks. Flagged, not silently assumed.

**Result: PASS.** No unjustified violations; Complexity Tracking intentionally omitted.

### Post-design re-check (after Phase 1)

Re-evaluated against the artifacts actually produced ([research.md](./research.md), [data-model.md](./data-model.md), [contracts/](./contracts/), [quickstart.md](./quickstart.md)):

- **I** — the design's only `infra-shared` change is still the deletion of `Headers`. No framework type added. **PASS.**
- **II** — Phase 1 added no module. The new types are all auth-service-local; `rate-limit-starter` is consumed via one annotation plus `rate-limit.limits.tenant-resolve-ip`, exactly its documented extension path. **PASS.**
- **III** — no classpath resource path moved or renamed; `002-tenant-url-identifier.yaml` is a new file in the existing (inert) changelog tree, and research.md R5 records that Liquibase does not execute it. **PASS.**
- **IV** — no Redis state added. The one "claim forever" mutation is relational and made atomic by a single transaction plus a primary-key constraint, per data-model.md §1.2. **PASS.**
- **V** — the design rests on audited facts (no provisioning endpoint exists, Liquibase is not wired, CORS uses a fixed origin list, public paths are enumerated explicitly), and the FR-011 edge dependency on `002-cors-edge-hardening` is surfaced in research.md and contracts/auth-service-api.md §6 rather than assumed away. **PASS.**

No new violations; Complexity Tracking remains empty.

## Project Structure

### Documentation (this feature)

```text
specs/003-tenant-url-resolution/
├── plan.md              # This file (/speckit-plan command output)
├── research.md          # Phase 0 output (/speckit-plan command)
├── data-model.md        # Phase 1 output (/speckit-plan command)
├── quickstart.md        # Phase 1 output (/speckit-plan command)
├── contracts/           # Phase 1 output (/speckit-plan command)
│   ├── auth-service-api.md
│   └── hydra-ui-api.md
├── checklists/
│   └── requirements.md  # Existing spec-quality checklist
└── tasks.md             # Phase 2 output (/speckit-tasks command - NOT created by /speckit-plan)
```

### Source Code (repository root)

```text
auth-service/src/main/java/com/reuven/auth/
├── config/
│   ├── CorsConfig.java                     # MODIFIED: allowedOriginPatterns; drop X-Tenant-ID allowed header
│   ├── SecurityCommons.java                # MODIFIED: permitAll GET /api/v1/tenant
│   └── TenantResolutionProperties.java     # NEW: hydra.tenant.base-domains, hydra.tenant.reserved-identifiers
├── controller/
│   ├── AuthController.java                 # MODIFIED: drop @RequestHeader(X-Tenant-ID); resolve from Host
│   ├── AdminController.java                # MODIFIED: + POST /api/v1/admin/tenants (SUPER_ADMIN)
│   └── TenantController.java               # NEW: public GET /api/v1/tenant, @RateLimited per IP
├── dto/
│   ├── CreateTenantRequest.java            # NEW: {name, urlIdentifier} with bean validation
│   ├── TenantResponse.java                 # NEW: provisioning result (admin-only; may carry the UUID)
│   └── TenantResolutionResponse.java       # NEW: {status, displayName?} — never carries the UUID
├── entity/
│   ├── Tenant.java                         # MODIFIED: + urlIdentifier (non-null, unique, len 63)
│   └── ReservedTenantIdentifier.java       # NEW: permanent allocation record (FR-012)
├── exception/
│   ├── AuthErrorCodes.java                 # MODIFIED: + unknown_tenant_address, tenant_inactive
│   ├── UnknownTenantAddressException.java  # NEW
│   ├── InactiveTenantException.java        # NEW
│   └── GlobalExceptionHandler.java         # MODIFIED: handlers for the two above
├── repository/
│   ├── TenantRepository.java               # MODIFIED: + findByUrlIdentifier
│   └── ReservedTenantIdentifierRepository.java  # NEW
└── service/
    ├── TenantHostParser.java               # NEW: pure Host → identifier (port-insensitive, case-insensitive)
    ├── TenantResolutionService.java        # NEW: Host → TenantResolution (RECOGNIZED/INACTIVE/UNKNOWN)
    ├── TenantProvisioningService.java      # NEW: validate + claim identifier + create tenant, one @Transactional
    ├── AuthService.java                    # MODIFIED: login takes the resolved tenant, unchanged otherwise
    └── BootstrapService.java               # MODIFIED: System Tenant gets an identifier + reservation row

auth-service/src/main/resources/
├── application.yaml                        # MODIFIED: hydra.tenant.*, rate-limit.limits.tenant-resolve-ip
├── application-local.yml                   # MODIFIED: base-domains: localhost; CORS origin patterns
├── application-test.yml                    # MODIFIED: base-domains for integration tests
├── application-prod.yml                    # MODIFIED: base-domains from env
└── db/changelog/changes/002-tenant-url-identifier.yaml  # NEW (parity only — Liquibase is not wired; see research.md R5)

auth-service/src/test/java/com/reuven/auth/
├── TenantHostParserTest.java               # NEW: unit, table-driven
├── TenantResolutionIntegrationTest.java    # NEW: public lookup, 3 statuses, no UUID, rate limit
├── TenantProvisioningIntegrationTest.java  # NEW: format/reserved-word/uniqueness/never-reuse
├── AuthIntegrationTest.java                # MODIFIED: login by Host; delete the missing-header test
├── RefreshFlowIntegrationTest.java         # MODIFIED: Host instead of X-Tenant-ID
├── BaseIntegrationTest.java                # MODIFIED: test tenants get identifiers
└── ratelimit/*.java                        # MODIFIED: Host instead of X-Tenant-ID

infra-shared/src/main/java/com/reuven/Headers.java   # DELETED (TENANT_ID was its only member)
integration-tests/.../AuthOrderCrossServiceIntegrationTest.java  # MODIFIED: Host instead of the header
order-service/.../config/CorsConfig.java             # MODIFIED: allowedOriginPatterns (per-tenant origins)

hydra-ui/src/
├── components/
│   ├── HydraProvider.tsx                   # MODIFIED: drop tenantId prop/context; add resolution state
│   └── hydra/LoginForm.tsx                 # MODIFIED: remove field + defaultTenantId; 3 load-time states
├── hooks/
│   ├── useTenant.ts                        # NEW: resolution status + display name
│   └── useLogin.ts                         # MODIFIED: login(username, password)
├── lib/
│   ├── http-client.ts                      # MODIFIED: remove tenantId / sendTenantHeader
│   ├── tenant-resolution.ts                # NEW: GET /api/v1/tenant fetch + response normalization
│   └── normalize-error.ts                  # MODIFIED: map the two new codes
├── types/errors.ts                         # MODIFIED: + unknown_tenant_address, tenant_inactive
└── index.ts                                # MODIFIED: export useTenant + its types
hydra-ui/{demo,stories,tests}/              # MODIFIED: host-derived base URL, MSW handler, new/updated specs
hydra-ui/vite.demo.config.ts                # MODIFIED: serve *.localhost (allowedHosts)
```

**Structure Decision**: No new modules or packages. Backend work lands entirely in `auth-service` under its existing `config/controller/dto/entity/exception/repository/service` layout, matching how every other concern in that service is organized; frontend work lands in the existing `hydra-ui/` package under its existing `components/hooks/lib/types` layout. The one deletion outside auth-service (`infra-shared`'s `Headers`) is the compiler-enforced way to prove no caller still sends a tenant header.

## Complexity Tracking

*No Constitution Check violations — table intentionally omitted.*
