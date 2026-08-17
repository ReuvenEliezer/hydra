# Phase 0 Research: Tenant Resolution from URL

**Feature**: `003-tenant-url-resolution` | **Date**: 2026-08-13 | **Plan**: [plan.md](./plan.md)

Every entry below resolves something the Technical Context could not state outright. Findings marked **audited** were confirmed against this repository's source, not inferred from documentation (constitution Principle V).

---

## R1 — Which host must the login request be addressed to?

**Decision**: The front-end MUST call auth-service on the *same tenant host* it is served from. In development that is `http://acme.localhost:5173` (page) → `http://acme.localhost:8083` (API); in production it is one host, `https://acme.hydra.example.com`, with the edge path-routing `/api/v1/auth/**` to auth-service while preserving `Host`. `@hydra/ui` therefore stops taking a hardcoded `apiBaseUrl` host in the demo/stories and derives it from `window.location.hostname`.

**Rationale**: FR-001 makes the `Host` header of the *login request* the sole resolution signal. The browser sets `Host` from the request's own URL, not from the page's URL. A page at `acme.localhost:5173` calling `http://localhost:8083/api/v1/auth/login` sends `Host: localhost:8083`, which has no tenant label and resolves to `unknown` (FR-015) — the feature would fail closed on every login in local development while looking correct in the UI. This is the single highest-risk misunderstanding in the feature and is stated as a Technical Context constraint for that reason.

**Alternatives considered**:
- *Front-end parses the subdomain and sends it in a header/body field* — rejected by FR-001 and the clarification session: the browser would supply a tenant value again, which is exactly the override this feature removes.
- *An `Origin`-header-based resolution* — rejected: `Origin` is absent on same-origin requests and is browser-controlled in a different way; FR-001 names `Host`, and `Host` is present on every HTTP request including server-to-server and curl.
- *A per-tenant API host such as `auth.acme.hydra.example.com`* — rejected: two labels precede the base domain, which FR-015 requires to resolve to `unknown`.

---

## R2 — How to read the Host header in Spring MVC (and in MockMvc)

**Decision**: Read `request.getHeader(HttpHeaders.HOST)`, falling back to `request.getServerName()` when it is absent or blank. Normalize before matching: trim, lowercase (`Locale.ROOT`), strip a trailing dot, strip the port — including the bracketed-IPv6 form `[::1]:8083` — and treat a bracketed literal or bare IP as never matching a base domain.

**Rationale**: HTTP/1.1 requires `Host`; HTTP/2 and HTTP/3 send `:authority` instead, and servlet containers surface that as the `Host` header, so one read covers all three. `getServerName()` is the container's already-parsed view of the same value and is the correct fallback rather than a second source of truth. Explicitly reading the header (rather than only `getServerName()`) keeps the resolution rule visible at the call site and makes the parser trivially unit-testable on plain strings, with no servlet involved.

**Alternatives considered**:
- *`getServerName()` only* — works, but hides the actual contract behind container behavior and is harder to assert against in a table-driven unit test.
- *`ServletUriComponentsBuilder`* — pulls in forwarded-header semantics this feature deliberately does not want; `X-Forwarded-Host` is not a trusted signal here (FR-011 puts the burden on the edge to preserve `Host` itself).

**Testing note (audited)**: `MockHttpServletRequest` derives `getServerName()` from a `Host` header when one is set, so `mockMvc.perform(post("/api/v1/auth/login").header(HttpHeaders.HOST, "acme.localhost"))` exercises the real path. This is the mechanical substitution for every existing `.header(Headers.TENANT_ID, ...)` call in `AuthIntegrationTest`, `RefreshFlowIntegrationTest`, the rate-limit tests, and `integration-tests`.

---

## R3 — `*.localhost` in development

**Decision**: Configure `localhost` as the sole allowed base domain in the `local` and `test` profiles, and serve the Vite demo with `server.allowedHosts` permitting `.localhost` hosts (plus `server.host` bound so the subdomain reaches it). Document `acme.localhost` as the canonical dev address, with an `/etc/hosts` line as the fallback for browsers that do not resolve `*.localhost` natively.

**Rationale**: FR-008 requires the same mechanism in development as in production, with no dev-only bypass. Chrome and Firefox resolve any `*.localhost` name to the loopback address without DNS or hosts-file entries; Safari and some CLI tools historically do not, so the hosts-file fallback must be documented rather than assumed. Vite 6 rejects requests whose `Host` is not in its allow-list by default (a DNS-rebinding protection), which would otherwise make `acme.localhost:5173` fail before any of this feature's code runs.

**Alternatives considered**:
- *A dev-only header or query parameter override* — rejected outright by FR-008; it would leave the real resolution path untested locally, which is precisely the failure mode the requirement targets.
- *A wildcard DNS entry pointing at 127.0.0.1 (`*.localtest.me`)* — workable but adds an external dependency to local development, and `localhost` needs to be a configured base domain anyway.

---

## R4 — CORS with per-tenant origins and credentials

**Decision**: Switch both services' `CorsConfiguration` from `setAllowedOrigins(...)` to `setAllowedOriginPatterns(...)`, configured per environment (e.g. `http://*.localhost:5173`, `https://*.hydra.example.com`), keep `allowCredentials(true)`, and drop `X-Tenant-ID` from auth-service's allowed request headers.

**Rationale (audited)**: today `hydra.cors.allowed-origins` is a fixed list (`http://localhost:5173`). With this feature, every tenant is its own origin, so a fixed list would require an entry per tenant — a provisioning-time deployment step, contradicting SC-004 ("no manual step beyond provisioning"). The CORS spec forbids `Access-Control-Allow-Origin: *` alongside credentialed requests, and the refresh cookie flow requires credentials; Spring's `allowedOriginPatterns` exists for exactly this case — it matches the request's `Origin` and echoes back that specific origin rather than a wildcard, so credentials stay legal. `X-Tenant-ID` becomes an unused allowed header the moment login stops reading it, and leaving it in the allow-list advertises a parameter that no longer exists.

**Note**: an empty pattern list must keep failing closed, matching the current `CorsProperties` contract and its startup warning.

**Ownership caveat**: which component *emits* these headers is `002-cors-edge-hardening`'s decision. This change keeps the services as the emitter — the status quo — and does not preempt 002.

---

## R5 — Schema change mechanism, and how "never reuse" is stored

**Decision**: Express both schema changes as JPA mappings and let `ddl-auto: update` apply them (the mechanism that actually builds the schema today); add `002-tenant-url-identifier.yaml` to the Liquibase changelog tree for parity only, clearly marked as not-yet-executed. Model permanent reservation as a dedicated `reserved_tenant_identifiers` table whose primary key is the identifier itself, written in the same transaction that creates the tenant and never deleted.

**Rationale (audited)**: `auth-service/pom.xml` has no Liquibase (or Flyway) dependency; `db/changelog/db.changelog-master.yaml` and its one changeset never run. Every profile — `local` (H2 file), `test`, `prod` — uses `spring.jpa.hibernate.ddl-auto: update`. Planning a "migration" against Liquibase would be planning against a mechanism that does not execute. Per the spec's Assumptions the database is wiped, so no backfill or nullable interim state is needed and `url_identifier` can be `NOT NULL UNIQUE` from the first boot.

A separate allocation table (rather than, say, a soft-deleted tenant row) is what makes FR-012 survive tenant deletion and renaming: the tenant row can disappear or change its identifier, and the reservation row still blocks reuse. Making the identifier the table's primary key delegates the race between two concurrent provisioning calls to the database's uniqueness enforcement instead of a check-then-write in application code (constitution Principle IV's reasoning, applied relationally).

**Alternatives considered**:
- *`tenants.url_identifier` unique constraint alone* — insufficient: deleting or renaming a tenant frees the value, violating FR-012.
- *Soft-delete tenants and never hard-delete* — couples an unrelated lifecycle decision to identifier reservation, and still does not cover the rename case.
- *Adding Liquibase as part of this feature* — real value, but it is a separate infrastructure decision affecting every service; folding it in here would widen the feature well past its spec. Worth its own spec.

---

## R6 — Rate limiting the public lookup

**Decision**: One dimension, per client IP: `@RateLimited(limit = "tenant-resolve-ip", key = "T(com.reuven.ratelimit.ClientIpResolver).resolve(#httpRequest)")` on `GET /api/v1/tenant`, with `rate-limit.limits.tenant-resolve-ip` defaulting to a capacity of 30 per `PT1M` and env-overridable like every existing limit.

**Rationale (audited)**: this is exactly the extension path `rate-limit-starter` documents — annotation plus a config entry, no new Java types, no starter changes (constitution Principle II). `ClientIpResolver` already honors `X-Forwarded-For`'s left-most address with a `getRemoteAddr()` fallback, which is what FR-016's "per client IP" means behind a proxy. The capacity is set well above the one-call-per-page-load the sign-in page makes (a normal user retrying, reloading, or hitting several tenant addresses stays comfortably under it) while making a sweep of the identifier space impractical. FR-016 explicitly accepts that tenant existence is discoverable via DNS, so throttling — not blurring the three statuses — is the mitigation; the statuses stay distinct as FR-004/FR-005 require.

**Alternatives considered**:
- *A second per-host dimension* — adds no protection: an enumerator varies the host by definition, so each attempt would get its own fresh bucket.
- *Uniform "unknown" responses to hide existence* — directly contradicts FR-004/FR-005 and the clarified decision.

---

## R7 — What login returns when the address does not resolve

**Decision**: Two new failure modes, both distinct from `invalid_credentials`:

| Condition | HTTP | `message` code |
|---|---|---|
| Host resolves to no tenant | 400 | `unknown_tenant_address` |
| Host resolves to an inactive/suspended tenant | 403 | `tenant_inactive` |
| Wrong username/password (unchanged) | 401 | `Invalid credentials` |

Resolution runs *after* the existing rate-limit dimensions and *before* any credential lookup.

**Rationale (audited)**: `GlobalExceptionHandler` already owns one error-body shape (`ErrorResponse{status, error, message, path}`) and already carries machine-readable codes in `message` (`AuthErrorCodes`), so two new exception handlers slot in with no new body layout for the client to normalize. 400 mirrors the status the old missing-`X-Tenant-ID` path produced (`MissingRequestHeaderException` → 400), which keeps "the request cannot name a tenant" in the same class it was before. 403 for an inactive tenant separates "we know who you mean, and that org is switched off" from both 400 and 401, satisfying FR-005 on the login path as well as the page-load path. Running resolution before the credential lookup guarantees FR-006 — there is no tenant to guess with, so no login can be attributed to a default.

**Alternatives considered**:
- *404 for unknown host* — arguably cleaner REST semantics, but 404 collides with `ResourceNotFoundException`'s existing meaning in this service and reads as "no such endpoint" to a client debugging a login.
- *Collapsing both into 401 `invalid_credentials`* — explicitly forbidden by FR-004/FR-005.

---

## R8 — Front-end resolution state: where it lives

**Decision**: `HydraProvider` performs the one load-time lookup on mount (guarded against StrictMode double-invocation exactly like the existing `restoreSession()` call) and publishes `{status, displayName}` on context; a new `useTenant()` hook reads it; `LoginForm` renders from that hook and renders **no form at all** when the status is `unknown` or `inactive`.

**Rationale**: FR-014 specifies one lookup "on load", and the page's whole state derives from it — provider-level is the only placement where two components cannot each fire their own call or disagree about the answer. It mirrors the provider's existing single-shot `restoreSession()` pattern, including its `useRef` StrictMode guard, so there is one idiom in the package rather than two. Withholding the form (rather than disabling a submit button) is the literal reading of FR-006 and Story 3's "not usable for a submission that could be misattributed": there is no submit path to reach at all.

A fourth client-side status, `resolving`, exists between mount and response, and a fifth, `error`, covers the lookup itself failing (network/5xx/429). `error` must render as its own message, **not** as `unknown` — telling a user their address is unrecognized because the API was briefly unreachable is a misdiagnosis they cannot act on.

**Alternatives considered**:
- *`LoginForm` fetches for itself* — duplicates the call if a page shows the org name anywhere else, and leaves the hook-first design (`@hydra/ui`'s stated principle) with no hook.
- *Resolve lazily on submit* — fails SC-003, which requires the unrecognized state before any credentials are submitted.

---

## Resolved unknowns

No `NEEDS CLARIFICATION` markers remain in the Technical Context. The spec carried none into planning — its twelve-question clarification session had already settled Host-based resolution, the base-domain matching rule, identifier format, provisioning, permanent reservation, reserved words, the public lookup and its payload, rate limiting, and the no-backfill assumption.

One dependency is surfaced rather than resolved, per constitution Principle V: **FR-011's end-to-end `Host` preservation is a requirement levied on the edge layer, whose ownership is `002-cors-edge-hardening`'s open question.** This plan proceeds for the topologies that exist today and does not decide 002.
