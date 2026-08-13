# Feature Specification: Browser Edge Hardening (CORS Ownership, Module Extraction, Cookie Topology)

**Feature Branch**: `002-cors-edge-hardening`

**Created**: 2026-08-13

**Status**: Draft

**Input**: Split out of the `001-hydra-ui-package` design review. Enabling browser access required CORS on auth-service and order-service, which did not exist. A working configuration was applied to both services to unblock front-end integration; that change deliberately left three questions unanswered, and this feature exists to answer them rather than let a tactical fix harden into an accidental architecture.

## Context: what already shipped

Both services now carry an equivalent, externally-configured CORS policy (`hydra.cors.allowed-origins`, credentials enabled, `OPTIONS` preflight permitted, `Retry-After` exposed). That configuration is production-shaped in its own right — origins are environment-supplied rather than compiled in, and an empty origin list fails closed. It is **not** temporary in the sense of "throwaway code."

What is unresolved is *where that policy should live* and *what deployment topologies it must support*. Those are architecture decisions, not code defects.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - One place to change the allowed origins (Priority: P1)

An engineer adding a new front-end environment (a staging origin, a preview deployment, a second product surface) changes the allowed-origin policy in exactly one place and both services pick it up, without the two drifting apart.

**Why this priority**: The current configuration is duplicated across two services. Duplication of a security policy is the specific failure mode where one copy gets updated and the other silently keeps rejecting traffic — producing an outage that looks like a front-end bug. The project constitution (Principle II) also requires cross-cutting infrastructure concerns to live in a dedicated module rather than being repeated per service.

**Independent Test**: Add a new allowed origin, deploy both services, and confirm both accept the new origin with no service-specific code change.

**Acceptance Scenarios**:

1. **Given** the shared policy names an origin, **When** either service receives a browser request from it, **Then** the request is permitted with credentials and the retry-delay information readable.
2. **Given** an engineer adds a service to the system, **When** that service adopts the shared policy, **Then** it inherits the identical CORS posture without copying configuration code.
3. **Given** the allowed-origin list is empty or absent, **When** any cross-origin browser request arrives, **Then** it is rejected (fail closed) and the service logs a clear warning at startup.

---

### User Story 2 - A decided, single owner for the browser edge policy (Priority: P1)

An operator can state definitively whether CORS is enforced by the services themselves or by the edge gateway, and the system behaves correctly in whichever deployment is in use.

**Why this priority**: The project's roadmap names an edge layer (gateway-based routing) as the target while the current local setup has no gateway at all. If both the gateway and the services emit CORS headers, browsers receive duplicated headers and reject the response outright — a failure that appears only in the deployed environment and not in local development. Leaving ownership undecided is an active production risk, not a documentation gap.

**Independent Test**: Run the same front-end against both a gateway-fronted deployment and a direct-to-service deployment; confirm exactly one set of CORS headers reaches the browser in each.

**Acceptance Scenarios**:

1. **Given** a deployment where the edge gateway enforces the policy, **When** a browser request completes, **Then** exactly one set of cross-origin headers is present in the response.
2. **Given** a deployment with no gateway (local development), **When** a browser request completes, **Then** the services supply the policy themselves and the front-end works identically.
3. **Given** either deployment, **When** an operator inspects configuration, **Then** the owning component is unambiguous and documented.

---

### User Story 3 - A supported answer for cross-site deployments (Priority: P2)

A team deploying the front-end on a different registrable domain from the services either has a working, documented path — or a clear, early failure telling them the topology is unsupported, rather than a silent session-renewal failure in production.

**Why this priority**: The session-renewal credential is currently issued as a strictly same-site cookie. Same-registrable-domain deployments (and local development across ports) work fine. A genuinely cross-site deployment causes the browser to withhold the credential on every renewal, so users are signed out at each credential expiry with no diagnosable error — the worst kind of failure, because it looks like an application bug and only appears in production. Lower priority than P1 because the same-site topology is workable today; this story removes a latent trap.

**Independent Test**: Deploy the front-end on a different registrable domain and confirm either that renewal works under the chosen policy, or that the constraint is detected and reported explicitly.

**Acceptance Scenarios**:

1. **Given** a same-site deployment, **When** an access credential expires, **Then** renewal succeeds transparently (unchanged from today).
2. **Given** a cross-site deployment under the chosen policy, **When** an access credential expires, **Then** renewal either succeeds or fails with an explicit, documented diagnostic — never a silent sign-out.
3. **Given** any relaxation of the same-site cookie restriction, **When** the change is made, **Then** compensating protection against cross-site request forgery is in place for the credential-bearing endpoints, which currently have none.

---

### Edge Cases

- What happens when the gateway and the services both enforce the policy simultaneously during a migration window? Duplicate headers must be prevented or detected, not left to chance.
- What happens when an origin is removed from the allowed list while sessions from that origin are active?
- How does an operator discover that a request was rejected specifically for origin policy, rather than for authentication or authorization? Rejections must be distinguishable in logs.
- What happens to preflight handling if the security filter ordering changes? Preflight carries no credentials by design and must never require authentication.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The browser origin policy MUST be defined once and consumed by every service that serves browser traffic, rather than duplicated per service.
- **FR-002**: The shared policy MUST be supplied per environment (not compiled into build artifacts) and MUST fail closed when unset.
- **FR-003**: The system MUST have exactly one component responsible for emitting cross-origin response headers in any given deployment, and that ownership MUST be documented and verifiable.
- **FR-004**: The policy MUST continue to permit credentialed requests and expose the retry-delay information the front-end's rate-limit messaging depends on — any restructuring MUST preserve both, since losing either silently breaks session renewal or rate-limit UX respectively.
- **FR-005**: Preflight requests MUST be permitted without authentication in every deployment configuration.
- **FR-006**: The supported deployment topologies for the session-renewal credential MUST be explicitly documented, including which ones are known not to work.
- **FR-007**: If the same-site restriction on the renewal credential is relaxed to support cross-site deployment, the credential-bearing endpoints MUST gain cross-site request forgery protection in the same change.
- **FR-008**: Origin-policy rejections MUST be distinguishable from authentication and authorization failures in service logs.

### Key Entities

- **Origin policy**: The set of browser origins permitted to call the services, plus the associated credential, method, header, and exposure rules. Currently duplicated; target is a single shared definition.
- **Edge owner**: The component (services vs. gateway) responsible for enforcing the origin policy in a given deployment.
- **Renewal credential cookie**: The session-renewal credential, whose same-site restriction determines which front-end/back-end domain topologies are viable.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Adding or removing an allowed origin requires a change in exactly one location and takes effect on every browser-facing service.
- **SC-002**: In every supported deployment, a browser response carries exactly one set of cross-origin headers — zero occurrences of duplicated headers across a full front-end regression pass.
- **SC-003**: An engineer can determine the owning component for origin policy from documentation alone, without reading service source.
- **SC-004**: Session renewal succeeds in 100% of expiry events in every deployment topology documented as supported.
- **SC-005**: No credential-bearing endpoint accepts a cross-site request without forgery protection once the same-site restriction is relaxed (zero unprotected endpoints).

## Assumptions

- The CORS configuration already applied to auth-service and order-service is correct and stays in place until this feature supersedes it — this work is a consolidation and decision exercise, not a bug fix, and the front-end package remains unblocked throughout.
- Extraction follows the precedent already set in this repository for cross-cutting infrastructure (a dedicated module owning its own auto-configuration and exposing configuration properties), rather than being folded into the framework-free shared core, which must remain free of framework dependencies.
- The edge-layer question is treated as genuinely open by the project's own roadmap; this feature is expected to resolve it, not assume an answer.
- Same-registrable-domain deployment is the assumed default topology unless the cross-site decision in User Story 3 concludes otherwise.

## Out of Scope

- Any change to the front-end package's behavior. The package consumes whatever policy the backend enforces; `001-hydra-ui-package` is unaffected by how this feature is resolved.
- Broader gateway responsibilities (routing, TLS termination, rate limiting at the edge) beyond origin-policy ownership.
