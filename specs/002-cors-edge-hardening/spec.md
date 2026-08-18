# Feature Specification: Browser Edge Hardening (Policy Ownership, Module Extraction, Cookie & Host Topology)

**Feature Branch**: `002-cors-edge-hardening`

**Created**: 2026-08-13

**Last Updated**: 2026-08-17

**Status**: Draft

**Input**: Split out of the `001-hydra-ui-package` design review. Enabling browser access required CORS on auth-service and order-service, which did not exist. A working configuration was applied to both services to unblock front-end integration; that change deliberately left three questions unanswered, and this feature exists to answer them rather than let a tactical fix harden into an accidental architecture. **Updated 2026-08-17**: `003-tenant-url-resolution` shipped without settling any of those three questions, changed the shape of the policy underneath them, and levied one additional requirement on this feature — end-to-end `Host` preservation at the edge (003's FR-011). That requirement is now User Story 3 here.

## Context: what already shipped

Both services carry an equivalent, externally-configured browser origin policy: `hydra.cors.allowed-origin-patterns`, credentials enabled, `OPTIONS` preflight permitted without authentication, `Retry-After` exposed, and an empty list failing closed with a startup warning. That configuration is production-shaped in its own right — patterns are environment-supplied rather than compiled in. It is **not** temporary in the sense of "throwaway code."

All three questions this feature was created to answer now have decisions recorded in Clarifications below: the services own the policy in every deployment, cross-registrable-domain deployment is out of support, and the policy consolidates into a single shared definition. What remains is building to those decisions — the module extraction, the conformance suite, and the startup validation — rather than making them.

### What `003-tenant-url-resolution` changed underneath this feature

Audited against source on 2026-08-17, not taken from prior docs:

- The policy is no longer a fixed origin list. Both services moved from `setAllowedOrigins(...)` to `setAllowedOriginPatterns(...)`, because every tenant now signs in at its own subdomain and is therefore its own browser origin. A literal list would need an entry — and a deployment — per tenant.
- The property key was renamed from `hydra.cors.allowed-origins` to `hydra.cors.allowed-origin-patterns` in both services.
- `X-Tenant-ID` was removed from auth-service's allowed request headers, and the shared constant deleted. The tenant is now resolved from the request's own `Host`.
- The duplication this feature exists to remove was not reduced — it was **exercised**. The change above had to be applied by hand, twice, in lockstep: once to `auth-service` and once to `order-service`, across four files and two YAML blocks. That is the precise failure mode User Story 1 describes, now demonstrated rather than predicted.
- CSRF remains disabled in both services, and the renewal credential remains a `SameSite=Strict`, host-only cookie scoped to the `/api/v1/auth` path.

### What `003-tenant-url-resolution` levied on this feature

003 made the tenant identity a function of the `Host` header of the request itself. It stated explicitly that preserving that header end-to-end is a requirement on the edge layer, and that the edge layer belongs to this feature to decide. It did not settle it, and recorded that it did not. User Story 3 below is that requirement, restated as this feature's own.

### The open question is the constitution's, not the README's

The earlier revision of this spec attributed the unresolved edge-layer decision to the project README's roadmap. The README contains no such section. The authoritative open statement is the project constitution's Technology Constraints: Kubernetes + Envoy Gateway is named as the current target, with docker-compose a candidate alternative under active evaluation, and neither is to be treated as settled. The repository's `docker-compose.yml` today defines only PostgreSQL and Redis — there is no gateway, and no service definitions, in any committed environment.

## Clarifications

### Session 2026-08-17

- Q: Which component should own the browser origin policy — the services themselves, or an edge gateway in front of them? → A: The services own it permanently. Any edge must be transparent: it forwards `Host` unmodified and emits no cross-origin headers of its own, so local and deployed behave identically.
- Q: With no edge committed anywhere in the repository, how should the host-preservation and edge-transparency checks be verified? → A: Ship an executable, technology-agnostic transparent-edge conformance suite, run in CI against a throwaway stand-in proxy and pointable at any real edge later.
- Q: Should this feature make cross-site deployment work, or declare it unsupported and fail loudly? → A: Declare it unsupported. Keep the strict same-site restriction, leave forgery protection off, document the constraint, and detect a cross-site configuration early with an explicit diagnostic instead of letting it fail silently at first token expiry.
- Q: What should a service do at startup when a configured origin pattern is broader than the domains the deployment controls? → A: Refuse to start, naming the offending pattern and why it was rejected — the same fail-closed posture already applied to an empty pattern list.
- Q: How should a service decide which domains the deployment controls? → A: Derive the controlled set from the deployment's declared tenant base domains, and additionally reject any declared base domain that is itself a public suffix, so a misconfigured list cannot authorize an over-broad pattern.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - One place to change the origin policy (Priority: P1)

An engineer adding a new front-end environment — a staging domain, a preview deployment, a second product surface — changes the browser origin policy in exactly one place, and every browser-facing service picks it up without the copies drifting apart.

**Why this priority**: The configuration is duplicated across two services. Duplication of a security policy is the specific failure mode where one copy gets updated and the other silently keeps rejecting traffic, producing an outage that looks like a front-end bug. This is no longer hypothetical: `003-tenant-url-resolution` had to make the identical origin-pattern change twice, by hand, and its own task list flagged that renaming one side without the other binds to nothing and fails closed silently. The project constitution (Principle II) also requires cross-cutting infrastructure concerns to live in a dedicated module rather than being repeated per service, with the rate-limiting module as the established precedent.

**Independent Test**: Add a new allowed origin pattern in one location, deploy both services, and confirm both accept a matching origin with no service-specific code change.

**Acceptance Scenarios**:

1. **Given** the shared policy names an origin pattern, **When** either service receives a browser request from a matching origin, **Then** the request is permitted with credentials and the retry-delay information is readable by the client.
2. **Given** an engineer adds a new browser-facing service to the system, **When** that service adopts the shared policy, **Then** it inherits the identical posture without copying configuration code.
3. **Given** the pattern list is empty or absent, **When** any cross-origin browser request arrives, **Then** it is rejected (fail closed) and the service logs a clear warning at startup.
4. **Given** a service intentionally needs a narrower posture than the shared default, **When** it declares that difference, **Then** the difference is expressed as an explicit, reviewable override rather than as a divergent copy of the whole policy.
5. **Given** an origin pattern broad enough to match domains the deployment does not control, **When** the service starts, **Then** it refuses to start and names the offending pattern and the reason, rather than starting into a configuration that echoes credentials to an arbitrary origin.
6. **Given** a declared tenant base domain that is itself a public suffix, **When** the service starts, **Then** it refuses to start and names that base domain — even when every configured origin pattern is well-formed against it.

---

### User Story 2 - One emitter, identical in every deployment (Priority: P1)

The browser-facing services are the sole emitter of the origin policy everywhere, and any edge placed in front of them is transparent to it — so a response looks the same to the browser whether or not an edge is in the path.

**Why this priority**: If both an edge and the services emit cross-origin headers, browsers receive duplicated headers and reject the response outright — a failure that appears only in the deployed environment and never in local development. Ownership is now decided (see Clarifications), which converts this story from *making* that decision into *enforcing* it: the risk is no longer an undecided architecture but an edge that silently adds its own headers and breaks production while local development stays green.

**Independent Test**: Run the same front-end against an edge-fronted deployment and a direct-to-service deployment; confirm the cross-origin headers reaching the browser are equivalent in both, and present exactly once.

**Acceptance Scenarios**:

1. **Given** an edge-fronted deployment, **When** a browser request completes, **Then** exactly one set of cross-origin headers is present in the response, emitted by the service, with the edge contributing none.
2. **Given** a deployment with no edge (local development), **When** a browser request completes, **Then** the response carries the equivalent cross-origin headers and the front-end behaves identically.
3. **Given** either deployment, **When** an operator inspects configuration, **Then** the owning component is unambiguous and documented.
4. **Given** an edge configured to add, rewrite, or strip cross-origin headers, **When** the conformance suite is run against it, **Then** it is reported as a failure before serving traffic rather than surfacing as duplicated headers in the browser.
5. **Given** a request rejected by the origin policy, **When** an operator reads the logs, **Then** the rejection is identifiable as an origin-policy rejection and is not confusable with an authentication or authorization failure.
6. **Given** any supported deployment configuration, **When** a browser sends the preflight that precedes a cross-origin call, **Then** it is answered without requiring authentication, regardless of how request-filtering is ordered.
7. **Given** the policy is applied to a credentialed request, **When** the response is produced, **Then** it names the single requesting origin rather than a literal wildcard, which browsers reject on credentialed requests.

---

### User Story 3 - The edge preserves the tenant's address (Priority: P1)

A request that a browser addressed to a tenant's host arrives at auth-service still carrying that host, through every component in between, so the tenant the user signed in to is the tenant they get.

**Why this priority**: Since `003-tenant-url-resolution`, the `Host` header is the sole signal that identifies the tenant — there is no header, body field, query parameter, or path segment carrying a tenant identifier, by design. A proxy that rewrites `Host` to an upstream service name makes every address resolve to `unknown`. The system fails closed, which is correct, but it fails closed *universally* — a total outage rather than a degraded path, and one that cannot occur in local development because local development has no proxy. This is the highest-severity item in the feature; it is listed after User Story 2 only because the answer is a property of whatever edge that story selects.

**Independent Test**: Send a request through the deployed edge addressed to a tenant host, and assert that the host auth-service observes is byte-for-byte the host the client addressed.

**Acceptance Scenarios**:

1. **Given** an edge-fronted deployment, **When** a browser addresses a request to a tenant host, **Then** auth-service observes that exact host, unmodified in case, spelling, and value.
2. **Given** an edge that terminates TLS and forwards to services over an internal address, **When** the request is forwarded, **Then** the original host is still what the service reads — the internal routing address does not replace it.
3. **Given** an edge configuration that does not preserve the host, **When** the conformance suite is run against it, **Then** the misconfiguration is reported as a failure before it reaches users, rather than surfacing as universal sign-in failure.
4. **Given** a newly provisioned tenant, **When** a user visits its address, **Then** it resolves with no edge configuration change and no deployment.
5. **Given** a candidate edge technology under evaluation, **When** the team runs the existing conformance suite against it, **Then** they get a pass/fail verdict on the contract without writing any new tests.

---

### User Story 4 - Cross-site deployment fails at configuration time, not at first expiry (Priority: P2)

A team that configures the front-end on a different registrable domain from the services is told so immediately and explicitly, instead of discovering the constraint when users start getting signed out at every credential expiry.

**Why this priority**: The renewal credential is issued as a strictly same-site cookie. Same-registrable-domain deployments work fine, including the per-tenant subdomain topology 003 introduced and local development across ports, since neither ports nor sibling subdomains break same-site. A genuinely cross-site deployment causes the browser to withhold the credential on every renewal, so users are signed out at each expiry with no diagnosable error — the worst kind of failure, because it looks like an application bug and appears only in production. Cross-site is now explicitly out of support (see Clarifications), which makes this story about converting a silent runtime trap into a loud configuration-time error. Lower priority than the P1 stories because the same-site topology is workable today.

**Independent Test**: Configure a cross-site topology and confirm the system reports the unsupported configuration explicitly at startup, rather than starting cleanly and failing at first renewal.

**Acceptance Scenarios**:

1. **Given** a same-site deployment, **When** an access credential expires, **Then** renewal succeeds transparently (unchanged from today).
2. **Given** a configuration whose front-end origin is not same-site with the services, **When** the service starts, **Then** it reports the unsupported topology explicitly, naming the offending origin, rather than starting cleanly and failing at first renewal.
3. **Given** an engineer evaluating a deployment topology, **When** they consult the documentation, **Then** they can determine whether it is supported without reading service source.
4. **Given** any future relaxation of the same-site restriction on the renewal credential, **When** the change is made, **Then** cross-site request forgery protection is in place for the credential-bearing endpoints in the same change, which today have none.
5. **Given** any change to the renewal credential's scope, **When** it is applied, **Then** the credential remains confined to the single tenant host that issued it and is never transmitted to a sibling tenant's host.

---

### Edge Cases

- What happens when an edge is introduced that emits its own cross-origin headers alongside the services'? The browser sees duplicates and rejects the response. There is no migration window in which both legitimately emit — the services always own it — so this is a misconfiguration to be caught by the conformance suite, not a state to be sequenced through.
- What happens when the edge is configured with a literal wildcard origin instead of a matched-and-echoed one? Every credentialed request fails, and the browser reports it as an unexplainable network error rather than a policy error.
- What happens when the renewal credential is broadened to span all tenant subdomains in an attempt to fix a topology problem? One tenant's credential becomes readable at every other tenant's host — a cross-tenant leak introduced by a change that looks like a cookie-scope tweak.
- What happens when an origin is removed from the allowed policy while sessions from that origin are active?
- How does an operator discover that a request was rejected specifically for origin policy, rather than for authentication or authorization? Rejections must be distinguishable in logs.
- What happens to preflight handling if security filter ordering changes? Preflight carries no credentials by design and must never require authentication.
- What happens when a component in the request path normalizes or lowercases the host, or appends a port that the client did not send? Tenant resolution is defined as case- and port-insensitive, so these must remain non-breaking rather than becoming an accidental dependency.

## Requirements *(mandatory)*

### Functional Requirements

Each requirement is tagged with the concern it belongs to: **[policy]** definition and ownership, **[host]** tenant address preservation, **[credential]** renewal credential topology.

- **FR-001** *[policy]*: The browser origin policy MUST be defined once and consumed by every service that serves browser traffic, rather than duplicated per service.
- **FR-002** *[policy]*: The shared policy MUST be supplied per environment (not compiled into build artifacts) and MUST fail closed when unset.
- **FR-003** *[policy]*: The browser-facing services MUST be the sole emitter of cross-origin response headers, in every deployment. No edge component may add, rewrite, or strip them. This ownership MUST be documented and verifiable.
- **FR-004** *[policy]*: The policy MUST continue to permit credentialed requests and expose the retry-delay information the front-end's rate-limit messaging depends on — any restructuring MUST preserve both, since losing either silently breaks session renewal or rate-limit messaging respectively.
- **FR-005** *[policy]*: Preflight requests MUST be permitted without authentication in every deployment configuration.
- **FR-006** *[credential]*: The supported deployment topologies for the session-renewal credential MUST be explicitly documented. Same-site topologies — including per-tenant subdomains of one registrable domain, and local development across ports — are supported. Cross-registrable-domain deployment is explicitly **not** supported, and MUST be documented as such.
- **FR-007** *[credential]*: If the same-site restriction on the renewal credential is relaxed to support cross-site deployment, the credential-bearing endpoints MUST gain cross-site request forgery protection in the same change.
- **FR-008** *[policy]*: Origin-policy rejections MUST be distinguishable from authentication and authorization failures in service logs.
- **FR-009** *[policy]*: The policy MUST admit per-tenant origins without a per-tenant configuration entry, and MUST respond to an allowed request by naming that single requesting origin rather than a wildcard — whichever component owns enforcement.
- **FR-010** *[policy]*: Origin patterns MUST be constrained to the set of domains the deployment controls, which MUST be derived from the deployment's declared tenant base domains rather than configured separately. A pattern is valid only if its wildcard covers a single label of one of those domains. A pattern outside that set MUST cause the service to refuse to start, naming the offending pattern and the reason — the same fail-closed posture FR-002 applies to an empty list. A service MUST NOT start into a configuration that would echo credentials back to an arbitrary origin.
- **FR-011** *[host]*: Every component between the browser and auth-service MUST forward the original `Host` unmodified end-to-end. No component in the request path may rewrite, strip, or substitute it. *(Inherited from `003-tenant-url-resolution` FR-011, which levied this requirement on this feature.)*
- **FR-012** *[host]*: Host preservation MUST be covered by the transparent-edge conformance suite (FR-016), which MUST fail when any component in the path rewrites, strips, or substitutes `Host`, and MUST run before a deployment reaches users.
- **FR-013** *[host]*: Provisioning a new tenant MUST NOT require any edge or origin-policy configuration change.
- **FR-014** *[credential]*: The renewal credential MUST remain scoped to the single tenant host that issued it. No change to its topology may make it transmissible to a sibling tenant's host.
- **FR-015** *[policy]*: Edge transparency to the origin policy MUST be covered by the same conformance suite — an edge that adds, rewrites, or strips cross-origin headers MUST be caught before serving user traffic.
- **FR-016** *[host]* *[policy]*: The system MUST provide a transparent-edge conformance suite that is executable and independent of any particular edge technology. It MUST run in continuous integration against a stand-in proxy, and MUST be runnable unmodified against a real candidate edge to produce a pass/fail verdict on the contract in FR-011, FR-012, and FR-015.
- **FR-017** *[credential]*: A configuration whose front-end origin is not same-site with the services MUST be detected and reported explicitly at startup, naming the offending origin. The service MUST NOT start cleanly into a topology whose sessions are known to fail at first renewal.
- **FR-018** *[policy]*: A declared tenant base domain that is itself a public suffix MUST cause the service to refuse to start. Because the controlled-domain set in FR-010 is derived from that list, an unchecked list would let a single configuration error authorize an arbitrarily broad origin pattern; this backstop keeps the derivation from being widened by mistake.

### Key Entities

- **Origin policy**: The set of browser origins permitted to call the services — now expressed as patterns rather than literals — plus the associated credential, method, header, and exposure rules. Currently duplicated across two services; target is a single shared definition.
- **Transparent edge**: Whatever sits between the browser and the services. Its contract with this feature is defined by what it must *not* do — it forwards `Host` unmodified and contributes no cross-origin headers. The origin policy is always the services'.
- **Controlled domain set**: The domains a deployment is entitled to serve browser origins for. Not configured independently — derived from the tenant base domains the deployment already declares for tenant resolution, so the origin policy and tenant resolution cannot drift apart.
- **Transparent-edge conformance suite**: The executable statement of that contract. Technology-agnostic, run in continuous integration against a stand-in proxy, and runnable unmodified against any candidate edge to get a verdict. This is the artifact that makes the contract enforceable rather than advisory.
- **Tenant address**: The host a browser addressed the request to. Since `003-tenant-url-resolution` this is the sole tenant identifier on the wire, which makes every component in the request path a participant in tenant resolution.
- **Renewal credential cookie**: The session-renewal credential, whose same-site restriction determines which front-end/back-end domain topologies are viable, and whose host scope determines tenant isolation.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Adding or removing an allowed origin requires a change in exactly one location and takes effect on every browser-facing service.
- **SC-002**: In every supported deployment, a browser response carries exactly one set of cross-origin headers — zero occurrences of duplicated headers across a full front-end regression pass.
- **SC-003**: An engineer can determine the owning component for origin policy from documentation alone, without reading service source.
- **SC-004**: Session renewal succeeds in 100% of expiry events in every deployment topology documented as supported.
- **SC-005**: No credential-bearing endpoint accepts a cross-site request without forgery protection once the same-site restriction is relaxed — zero unprotected endpoints.
- **SC-006**: Across a full front-end regression pass through the deployed edge, the host observed by auth-service matches the host the client addressed in 100% of requests.
- **SC-007**: A newly provisioned tenant becomes reachable with zero configuration changes to the origin policy and zero changes to the edge.
- **SC-008**: A tenant's renewal credential is never transmitted to another tenant's host — zero occurrences across a multi-tenant regression pass.
- **SC-009**: An edge that breaks host preservation or contributes cross-origin headers of its own is caught by the conformance suite before serving user traffic — zero such misconfigurations reach production.
- **SC-010**: A team introducing a new edge technology can validate it against the transparent-edge contract by running the existing suite against it, writing zero new test code.
- **SC-011**: An unsupported cross-site configuration is reported at startup in 100% of cases — zero deployments reach a first credential expiry before the constraint surfaces.
- **SC-012**: No service instance ever serves traffic under an origin pattern matching a domain the deployment does not control — zero such instances reach a ready state.

## Assumptions

- The origin policy currently applied to auth-service and order-service is correct and stays in place until this feature supersedes it. This work is a consolidation and decision exercise, not a bug fix, and the front-end package remains unblocked throughout.
- Extraction follows the precedent already set in this repository for cross-cutting infrastructure — a dedicated module owning its own auto-configuration and exposing configuration properties, as the rate-limiting module does — rather than being folded into the framework-free shared core, which must remain free of framework dependencies (constitution Principles I and II).
- Policy ownership is settled (Clarifications): the services emit it, always. The constitution's *other* open edge question — Kubernetes + Envoy Gateway versus docker-compose — stays open and is deliberately not resolved here. Under a transparent edge, this feature does not need that answer, because the requirements it levies (`Host` preserved, no cross-origin headers added) hold for any edge technology.
- Same-registrable-domain deployment is the only supported topology (Clarifications). The per-tenant subdomain topology introduced by `003-tenant-url-resolution` is same-site and keeps working unchanged. Cross-site support is not deferred pending investigation — it is declined, with FR-007 standing as the condition any future reversal must satisfy.
- Tenant resolution semantics are settled by `003-tenant-url-resolution` and are an input to this feature, not a subject of it. This feature is responsible for the request path delivering the host intact, not for what auth-service does with it.
- Deriving the controlled domain set from declared tenant base domains (FR-010) assumes that list is reachable by every browser-facing service. Today it is not: `003-tenant-url-resolution` introduced it as auth-service tenant configuration, and order-service has no equivalent. Making the derivation work across both services is a consequence of this decision and belongs to planning; it is surfaced here rather than assumed away.
- The stand-in proxy the conformance suite runs against in continuous integration is test scaffolding, not a deployment target and not an implicit answer to the Kubernetes-versus-docker-compose question. It exists so the contract has something to execute against; a real edge replaces it as the subject under test without the suite changing.

## Out of Scope

- Any change to the front-end package's behavior. The package consumes whatever policy the backend enforces; `001-hydra-ui-package` is unaffected by how this feature is resolved.
- The tenant resolution algorithm itself — parsing, reserved identifiers, the allocation ledger, and the resolution endpoint all belong to `003-tenant-url-resolution` and are already implemented.
- Broader gateway responsibilities beyond origin-policy ownership and host preservation: TLS termination policy, path routing rules, rate limiting at the edge, and observability wiring.
- **Selecting the edge technology.** This was in scope while ownership was undecided. The Clarifications decision removes the dependency: a transparent edge is specified by constraints that hold regardless of implementation, so Kubernetes + Envoy Gateway versus docker-compose can be settled independently, on its own timeline, without reopening this feature.
