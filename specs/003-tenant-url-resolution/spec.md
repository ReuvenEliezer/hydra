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

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Sign in with no tenant field at all (Priority: P1)

A user visits their organization's sign-in address and enters only a username and password. The system already knows which tenant they belong to from the address itself, so no tenant field is shown and no tenant value is ever typed.

**Why this priority**: This is the entire point of the feature — it's the only story that, on its own, eliminates the UUID-typing problem the current temporary field exists to work around.

**Independent Test**: Visit a known-good tenant sign-in address, submit only username and password, and confirm the login succeeds against the correct tenant with no tenant input rendered anywhere on the page.

**Acceptance Scenarios**:

1. **Given** a user is at a URL that maps to an active, known tenant, **When** they submit valid username/password with no tenant input, **Then** they are signed in against that tenant.
2. **Given** a user is signed in via one tenant's URL, **When** they inspect the sign-in page, **Then** no Tenant ID (or any other raw tenant identifier) is visible, editable, or present in the page's source.

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
2. **Given** a user is at a URL that maps to a tenant that has been deactivated, **When** they attempt to sign in, **Then** they see a message distinct both from "address not recognized" and from "wrong username or password".

---

### User Story 4 - Operator provisions a working sign-in address for a new tenant (Priority: P3)

When a new tenant is created, it is given a working, human-readable sign-in address as part of provisioning, so its users have somewhere to go on day one without any manual DNS or config step per tenant.

**Why this priority**: Stories 1 and 2 describe the sign-in experience assuming a tenant's address already exists; this story is what makes that true for every new tenant, but a system could initially ship with addresses assigned by an out-of-band/manual step and still deliver Stories 1 and 2's value.

**Independent Test**: Provision a new tenant and confirm that, without any additional manual configuration, a sign-in address for it resolves correctly per Story 1.

**Acceptance Scenarios**:

1. **Given** a new tenant is provisioned, **When** provisioning completes, **Then** a sign-in address for that tenant is usable immediately.
2. **Given** two different tenants, **When** their sign-in addresses are compared, **Then** they are guaranteed distinct — no two tenants ever share a resolvable address.

### Edge Cases

- What happens in local development or a testing environment where the production URL scheme (e.g. subdomains of a real domain) isn't available?
- If a tenant's human-readable identifier (the part of the URL that names it) changes after users already have it bookmarked, the old identifier stops resolving immediately — it falls into the "address not recognized" state (Story 3), with no alias/redirect kept.
- What happens when the resolved tenant is valid but suspended/inactive at the moment of login, versus not existing at all?
- What happens if the app is embedded or accessed through a URL that has been proxied/rewritten such that the original tenant-identifying part of the address is no longer visible to the browser?
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
- **FR-009**: Every provisioned tenant MUST have exactly one canonical sign-in address usable immediately upon provisioning, per User Story 4.
- **FR-010**: A super-admin's authorized visibility and actions across tenants (e.g. viewing or managing users belonging to a tenant other than their own) MUST NOT be restricted by which tenant their own sign-in address resolves to — URL-based resolution governs login only, not post-login authorization scope, per User Story 2.
- **FR-011**: The edge layer (load balancer / API gateway / Envoy route, whatever sits in front of auth-service) MUST preserve the original Host header unmodified end-to-end from browser to auth-service — no component in the request path may rewrite or strip it, since it is the sole signal auth-service uses to resolve the tenant (per FR-001).

### Key Entities

- **Tenant URL Identifier**: The human-facing, URL-safe value that appears in a tenant's sign-in address (for example, the subdomain segment) and is what the system resolves to a tenant. Distinct from the tenant's existing internal UUID, which remains the identifier used everywhere the system already talks about a tenant server-side. Must be unique across all tenants.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A user can complete sign-in without the sign-in page ever displaying, requesting, or accepting a raw tenant identifier.
- **SC-002**: 100% of sign-in attempts on a recognized tenant address resolve to the correct tenant — zero instances of a login being attributed to the wrong tenant.
- **SC-003**: A user on an unrecognized sign-in address sees an "address not recognized" state immediately on page load, before submitting any credentials.
- **SC-004**: A newly provisioned tenant has a working sign-in address with no manual step beyond provisioning itself.
- **SC-005**: A super-admin can view or manage users belonging to any tenant, regardless of which tenant's address they personally sign in through.

## Assumptions

- The tenant's existing internal UUID remains the identifier used everywhere the system already operates on a tenant (JWT claims, database keys, server-to-server calls); this feature only changes how that UUID is *established* at the start of a login, not what it is used for afterward.
- Each tenant has exactly one canonical URL identifier for the purposes of this feature; supporting multiple addresses per tenant (e.g. a custom domain in addition to a default one) is out of scope unless a future feature extends this one.
- This feature covers the sign-in flow only. Other places a tenant is referenced today (e.g. account-provisioning forms that already receive tenant context from an authenticated admin session) are unaffected.
- The temporary Tenant ID field and its supporting plumbing (`LoginForm`'s field, `useLogin`'s per-call tenant override, `HydraProvider`'s tenant default) are removed as part of delivering this feature, not kept as a fallback.
- A super-admin account belongs to exactly one home tenant (today, the bootstrapped "System Tenant") and signs in through that tenant's one address like any other account; their cross-tenant reach is an existing, unrelated authorization capability (already granted via role, independent of login) that this feature must not narrow, per FR-010.
