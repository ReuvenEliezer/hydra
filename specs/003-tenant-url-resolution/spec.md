# Feature Specification: Tenant Resolution from URL

**Feature Branch**: `003-tenant-url-resolution`

**Created**: 2026-08-13

**Status**: Draft

**Input**: User description: "Resolve the tenant for login from the URL (e.g. subdomain, like acme.hydra.example.com) instead of requiring the user to manually type/paste a Tenant ID (currently a raw UUID) into the LoginForm. This replaces the temporary Tenant ID input field added to @hydra/ui's LoginForm component and the corresponding X-Tenant-ID header handling in auth-service's AuthController.login, which currently requires the frontend to supply an explicit tenant UUID with every login request. The new behavior: the app derives the tenant automatically from the browser's current URL at login time, with no manual entry required, removing the Tenant ID field from the login UI once implemented. This is a separate, standalone feature from the existing 001-hydra-ui-package spec — scope it on its own."

## Context: what this replaces

`001-hydra-ui-package` shipped `LoginForm` with a real, user-editable **Tenant ID** field (a raw UUID) sitting above Username/Password, because the backend's `POST /api/v1/auth/login` requires an explicit `X-Tenant-ID` header with no default — omitting it is rejected before credentials are even checked. That field was built and documented as a deliberate stopgap: asking a human to type or paste a UUID to sign in is not a real product experience, only a way to unblock testing while the real resolution mechanism didn't exist yet.

This feature is that real mechanism: the tenant is derived automatically from the URL the user is already on, so nothing about "which tenant" is ever typed, selected, or shown to the end user. It supersedes the Tenant ID field entirely rather than sitting alongside it.

## Clarifications

### Session 2026-08-13

- Q: When the browser sends the login request, how does auth-service learn which tenant the URL resolved to? → A: auth-service resolves the tenant itself directly from the incoming request's Host header — frontend sends nothing tenant-related.
- Q: Does anything sit between the browser and auth-service that could rewrite or strip the Host header before auth-service sees it? → A: Host header is preserved unmodified end-to-end (browser → edge/gateway → auth-service); this is a requirement on the edge layer, stated explicitly.
- Q: When a tenant's URL identifier changes after users already have it bookmarked, what should happen to logins at the old address? → A: Old identifier stops resolving immediately once changed — falls into the existing "address not recognized" state from Story 3, no aliasing needed.
- Q: What characters and format are allowed in a Tenant URL Identifier? → A: Lowercase letters, digits, and hyphens only (RFC 1123 DNS label rules), max 63 chars, no leading/trailing hyphen.
- Q: How does a new tenant get its Tenant URL Identifier at provisioning time? → A: Supplied explicitly by the operator during provisioning, validated against the format rules and uniqueness at creation time.
- Q: Can a Tenant URL Identifier freed up by deactivation, deletion, or renaming be reused later? → A: Never reuse — once assigned, an identifier is permanently reserved even if the tenant is deactivated/deleted/renamed.
- Q: Are certain subdomain names (www, api, admin, app) reserved and off-limits as Tenant URL Identifiers? → A: Yes — maintain an explicit reserved-word list rejected at provisioning validation.
- Q: How does the sign-in page learn, before any credentials are submitted, that the current address resolves to no tenant? → A: A public, unauthenticated lookup the page calls on load resolves the Host header server-side and returns recognized / inactive / unknown; the page renders state from that response and never receives a tenant UUID.
- Q: How is the tenant label separated from the rest of the Host header? → A: Configured allowed base-domain list per environment; Host must end with one of them, and the single label immediately preceding it is the Tenant URL Identifier. Non-matching Hosts resolve to unknown.
- Q: What happens to tenants that already exist without a URL identifier? → A: No backfill — the system is not yet deployed to production, so existing data is wiped and the identifier is mandatory for every tenant from the start.
- Q: How is the public, unauthenticated tenant-resolution lookup protected against tenant enumeration? → A: Rate-limited per client IP using the existing rate-limiting mechanism, keeping the three statuses distinct; tenant existence is accepted as discoverable since DNS exposes it anyway.
- Q: On a recognized address, does the sign-in page show which organization the user is signing in to? → A: Yes — the lookup returns the tenant's display name and the page shows it; no UUID, logo, colors, or other branding.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Sign in with no tenant field at all (Priority: P1)

A user visits their organization's sign-in address and enters only a username and password. The system already knows which tenant they belong to from the address itself, so no tenant field is shown and no tenant value is ever typed.

**Why this priority**: This is the entire point of the feature — it's the only story that, on its own, eliminates the UUID-typing problem the current temporary field exists to work around.

**Independent Test**: Visit a known-good tenant sign-in address, submit only username and password, and confirm the login succeeds against the correct tenant with no tenant input rendered anywhere on the page.

**Acceptance Scenarios**:

1. **Given** a user is at a URL that maps to an active, known tenant, **When** they submit valid username/password with no tenant input, **Then** they are signed in against that tenant.
2. **Given** a user is signed in via one tenant's URL, **When** they inspect the sign-in page, **Then** no Tenant ID (or any other raw tenant identifier) is visible, editable, or present in the page's source.
3. **Given** a user is at a URL that maps to an active, known tenant, **When** the sign-in page loads, **Then** it shows that tenant's display name so the user can confirm which organization they are signing in to.

---

### User Story 2 - Super-admin operates across every tenant from one sign-in (Priority: P2)

A super-admin (an operator role that already manages accounts across tenants, e.g. via account-provisioning for any tenant) signs in through their own single address and, once signed in, can see and manage users across every tenant — not just whichever one their own address happens to resolve to.

**Why this priority**: Login now resolves to exactly one tenant per address, but a super-admin's home tenant is not the boundary of what they're authorized to see. Without this called out explicitly, "tenant is derived from the URL" could be misread as also limiting what a super-admin can view post-login, which would be a regression against existing cross-tenant admin capability.

**Independent Test**: Sign in as a super-admin through their address, then view/manage users belonging to a different tenant than the one that address resolved to, and confirm it succeeds.

**Acceptance Scenarios**:

1. **Given** a super-admin is signed in via their own sign-in address, **When** they view or manage users belonging to a different tenant, **Then** the action succeeds — their visibility is not limited to the tenant their address resolved to at login.
2. **Given** a super-admin's account itself belongs to one specific (home) tenant, **When** they sign in, **Then** login still resolves to that one home tenant like any other account — only their *authorized actions after signing in* span tenants, not the login-time resolution itself.

---

### User Story 3 - Clear error on an unrecognized address (Priority: P2)

A user reaches a sign-in page at an address that doesn't correspond to any known tenant (a typo, a decommissioned tenant, a stale bookmark). They see a distinct, actionable message telling them the address isn't recognized, rather than a generic sign-in failure or a misleading "wrong password" message.

**Why this priority**: Without this, an unresolvable tenant either silently fails in a confusing way or — worse — falls back to some default tenant, which would be a security-relevant misattribution. This is the safety net for Story 1.

**Independent Test**: Visit a sign-in address that maps to no tenant and confirm the page shows an "address not recognized" state before any credentials are ever submitted, distinguishable from an invalid-credentials error.

**Acceptance Scenarios**:

1. **Given** a user is at a URL that does not map to any tenant, **When** the sign-in page loads, **Then** it shows a clear, distinct message that the address isn't recognized, and the username/password fields are not usable for a submission that could be misattributed to the wrong tenant.
2. **Given** a user is at a URL that maps to a tenant that has been deactivated, **When** the sign-in page loads, **Then** they see a message distinct both from "address not recognized" and from "wrong username or password".
3. **Given** the sign-in page loads at any address, **When** it performs its load-time tenant lookup, **Then** the response conveys only the resolution status (recognized / inactive / unknown) plus, when recognized, the tenant's display name — never the tenant's internal UUID.

---

### User Story 4 - Operator provisions a working sign-in address for a new tenant (Priority: P3)

When a new tenant is created, it is given a working, human-readable sign-in address as part of provisioning, so its users have somewhere to go on day one without any manual DNS or config step per tenant.

**Why this priority**: Stories 1 and 2 describe the sign-in experience assuming a tenant's address already exists; this story is what makes that true for every new tenant, but a system could initially ship with addresses assigned by an out-of-band/manual step and still deliver Stories 1 and 2's value.

**Independent Test**: Provision a new tenant and confirm that, without any additional manual configuration, a sign-in address for it resolves correctly per Story 1.

**Acceptance Scenarios**:

1. **Given** a new tenant is provisioned, **When** provisioning completes, **Then** a sign-in address for that tenant is usable immediately.
2. **Given** two different tenants, **When** their sign-in addresses are compared, **Then** they are guaranteed distinct — no two tenants ever share a resolvable address.

### Edge Cases

- Local development and testing use `*.localhost` addresses (e.g. `acme.localhost`) resolved by the same mechanism as production, with `localhost` configured as an allowed base domain for that environment (FR-008, FR-015) — no dev-only bypass exists.
- If a tenant's human-readable identifier (the part of the URL that names it) changes after users already have it bookmarked, the old identifier stops resolving immediately — it falls into the "address not recognized" state (Story 3), with no alias/redirect kept.
- A tenant that exists but is inactive/suspended is reported distinctly from one that does not exist at all, both at page load and on a login attempt (FR-005, FR-014) — neither is reported as an invalid-credentials failure.
- A request arriving on the bare base domain with no tenant label, or on a host with more than one label in front of the base domain, resolves to unknown rather than to a default tenant (FR-015).
- If the app is reached through a proxy that rewrites or strips the Host header, resolution fails closed — the address reports as unrecognized rather than falling back to a guessed tenant. Preserving the Host header end-to-end is a hard requirement on the edge layer (FR-011).
- What happens when a super-admin, authorized across every tenant, is at a specific tenant's sign-in address rather than their own home tenant's — does login still resolve strictly to that one address's tenant (correct), or could the elevated role be mistaken for a reason to bypass URL resolution at login time (incorrect — see FR-010)?

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST derive the tenant for a login attempt from the URL the user is currently on, without the user typing, pasting, or selecting a tenant identifier. Resolution happens server-side in auth-service, reading the Host header of the incoming login request — the frontend does not parse the URL or send any tenant-related value with the login request.
- **FR-002**: The sign-in UI MUST NOT present a Tenant ID field, or any other manual tenant-selection control, to the end user.
- **FR-003**: System MUST map a given URL unambiguously to at most one tenant — never zero-or-more with an arbitrary choice, and never two tenants resolving to the same address.
- **FR-004**: System MUST distinguish, in what is shown to the user, between "this address doesn't resolve to any tenant" and "this address resolves to a tenant, but the credentials submitted were wrong."
- **FR-005**: System MUST distinguish "resolves to no tenant" from "resolves to a tenant that is currently inactive/suspended."
- **FR-006**: System MUST NOT attempt a login against a guessed or default tenant when the current URL does not resolve to one — an unresolvable address must block submission rather than silently falling back.
- **FR-007**: Every other authenticated endpoint, which already derives its tenant from the signed-in session rather than from user input, MUST be unaffected by this change — this feature is scoped to how the tenant is established at login, not how it is used afterward.
- **FR-008**: System MUST support resolving a working sign-in address for local development and testing environments using `*.localhost` subdomains (e.g. `acme.localhost`) — the same URL-based resolution mechanism used in production, rather than a separate dev-only bypass, so the resolution logic itself is exercised identically in both environments.
- **FR-009**: Every provisioned tenant MUST have exactly one canonical sign-in address usable immediately upon provisioning, per User Story 4. The Tenant URL Identifier is supplied explicitly by the operator during provisioning (not auto-generated), and MUST be validated against the format rules (see Key Entities) and checked for uniqueness at creation time. The identifier is mandatory for every tenant — a tenant without one MUST NOT be creatable, and no backfill or nullable-identifier state needs to be supported (see Assumptions).
- **FR-010**: A super-admin's authorized visibility and actions across tenants (e.g. viewing or managing users belonging to a tenant other than their own) MUST NOT be restricted by which tenant their own sign-in address resolves to — URL-based resolution governs login only, not post-login authorization scope, per User Story 2.
- **FR-011**: The edge layer (load balancer / API gateway / Envoy route, whatever sits in front of auth-service) MUST preserve the original Host header unmodified end-to-end from browser to auth-service — no component in the request path may rewrite or strip it, since it is the sole signal auth-service uses to resolve the tenant (per FR-001).
- **FR-012**: A Tenant URL Identifier MUST be permanently reserved once assigned — it MUST NOT be reassigned to a different tenant, or reused by the same tenant under a new registration, even after the original tenant is deactivated, deleted, or renamed off of it.
- **FR-013**: System MUST maintain an explicit list of reserved subdomain names (e.g. `www`, `api`, `admin`, `app`, `auth`, `mail`) that are used by the platform's own infrastructure, and MUST reject any of these as a Tenant URL Identifier at provisioning-time validation.
- **FR-014**: System MUST expose a public, unauthenticated tenant-resolution lookup that the sign-in page calls on load. It resolves the tenant from the incoming request's Host header using the same server-side rule as FR-001, and returns exactly one status: recognized, inactive, or unknown. On a recognized address it MUST also return the tenant's display name, and nothing else — no internal UUID, no logo, colors, or other branding, and no value the browser could submit as a tenant override. The sign-in page derives its displayed state solely from this response.
- **FR-015**: System MUST resolve the tenant label from the Host header against a configured list of allowed base domains for the running environment (e.g. `hydra.example.com` in production, `localhost` in development). A Host resolves to a tenant only if it ends with one of those base domains and has exactly one additional label immediately preceding it; that label is the Tenant URL Identifier. A Host that matches no configured base domain, that is the bare base domain itself with no tenant label, or that carries more than one additional label MUST resolve to unknown — never to a default or guessed tenant (per FR-006). Matching MUST ignore any port suffix and MUST be case-insensitive.
- **FR-016**: The public tenant-resolution lookup (FR-014) MUST be rate-limited per client IP using the platform's existing rate-limiting mechanism, so it cannot be swept to enumerate tenants at will. Its three statuses remain distinct as required by FR-004 and FR-005; the existence of a tenant at a given address is treated as discoverable information (DNS already exposes it), so the mitigation is throttling rather than hiding the distinction.
- **FR-017**: On a recognized address, the sign-in page MUST display the tenant's display name (e.g. "Sign in to Acme Corp") so a user who arrives at the wrong organization's address can tell before submitting credentials. This name is presentational only — it is never an input to tenant resolution, which remains Host-header-based per FR-001.

### Key Entities

- **Tenant URL Identifier**: The human-facing, URL-safe value that appears in a tenant's sign-in address (for example, the subdomain segment) and is what the system resolves to a tenant. Distinct from the tenant's existing internal UUID, which remains the identifier used everywhere the system already talks about a tenant server-side. Must be unique across all tenants. Format: lowercase letters, digits, and hyphens only (RFC 1123 DNS label rules), maximum 63 characters, no leading or trailing hyphen. Required (non-null, unique) on every tenant.
- **Tenant Display Name**: The human-readable organization name shown on the sign-in page for a recognized address (per FR-017). Presentational only — never used to resolve a tenant, and publicly readable via the FR-014 lookup by anyone who can reach that address.
- **Tenant Resolution Result**: What the FR-014 lookup returns for a given Host: a status of recognized, inactive, or unknown, plus the Tenant Display Name when (and only when) the status is recognized. Never carries the tenant's internal UUID.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A user can complete sign-in without the sign-in page ever displaying, requesting, or accepting a raw tenant identifier.
- **SC-002**: 100% of sign-in attempts on a recognized tenant address resolve to the correct tenant — zero instances of a login being attributed to the wrong tenant.
- **SC-003**: A user on an unrecognized sign-in address sees an "address not recognized" state immediately on page load, before submitting any credentials.
- **SC-004**: A newly provisioned tenant has a working sign-in address with no manual step beyond provisioning itself.
- **SC-005**: A super-admin can view or manage users belonging to any tenant, regardless of which tenant's address they personally sign in through.
- **SC-006**: A user on a recognized address sees the correct organization's display name on the sign-in page before submitting credentials, and the page's load-time lookup response contains no tenant UUID in any state.

## Assumptions

- The tenant's existing internal UUID remains the identifier used everywhere the system already operates on a tenant (JWT claims, database keys, server-to-server calls); this feature only changes how that UUID is *established* at the start of a login, not what it is used for afterward.
- Each tenant has exactly one canonical URL identifier for the purposes of this feature; supporting multiple addresses per tenant (e.g. a custom domain in addition to a default one) is out of scope unless a future feature extends this one.
- This feature covers the sign-in flow only. Other places a tenant is referenced today (e.g. account-provisioning forms that already receive tenant context from an authenticated admin session) are unaffected.
- The system is not yet deployed to production, so no existing tenant data has to be preserved: the database is wiped as part of adopting this feature, and every tenant is created with a Tenant URL Identifier from the outset. No migration, backfill, or "tenant without an identifier" state is in scope, and the identifier can be a required (non-null, unique) field from day one.
- The temporary Tenant ID field and its supporting plumbing (`LoginForm`'s field, `useLogin`'s per-call tenant override, `HydraProvider`'s tenant default) are removed as part of delivering this feature, not kept as a fallback.
- A super-admin account belongs to exactly one home tenant (today, the bootstrapped "System Tenant") and signs in through that tenant's one address like any other account; their cross-tenant reach is an existing, unrelated authorization capability (already granted via role, independent of login) that this feature must not narrow, per FR-010.
