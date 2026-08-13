# Feature Specification: Hydra UI Package

**Feature Branch**: `001-hydra-ui-package`

**Created**: 2026-08-13

**Status**: Draft

**Input**: User description: "create me a new packege for UI to support all our END POINTS in auth-service & order-service. dont forget to use the refresh token as production behiviure - Specification: HYDRA UI Package Creation, a reusable frontend component/hook package covering every auth-service and order-service endpoint with production-grade refresh-token session handling."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Sign in and stay signed in (Priority: P1)

A user of a HYDRA-based application enters their username and password once. The application keeps them signed in across page reloads and normal usage without asking them to log in again, until their session is explicitly ended or their access is revoked.

**Why this priority**: Nothing else in the package is usable without a working, trustworthy sign-in and session experience. This is the foundation every other story depends on.

**Independent Test**: Can be fully tested by signing in with valid credentials, reloading the page, and confirming the user remains authenticated and can call a protected endpoint without re-entering credentials.

**Acceptance Scenarios**:

1. **Given** a user with valid credentials, **When** they submit the sign-in form, **Then** they are authenticated and land in the signed-in area of the application.
2. **Given** a user with an invalid username or password, **When** they submit the sign-in form, **Then** they see a clear error message and remain on the sign-in screen.
3. **Given** a signed-in user whose short-lived access credential has expired but whose session is still valid, **When** they perform any action that calls a protected endpoint, **Then** their session is silently renewed and the action completes without the user noticing an interruption.
4. **Given** a signed-in user, **When** they reload the browser tab or return after closing and reopening it (within the session's valid lifetime), **Then** they are still signed in.
5. **Given** a user whose session has been revoked or has fully expired, **When** they perform any action that calls a protected endpoint, **Then** they are cleanly signed out and redirected to the sign-in screen.

---

### User Story 2 - Sign out securely (Priority: P1)

A signed-in user ends their session on demand, and the application guarantees no further requests are made on their behalf afterward.

**Why this priority**: Session termination is a core security expectation and must ship alongside sign-in for the package to be safe to use in production.

**Independent Test**: Can be fully tested by signing in, triggering sign-out, and confirming that subsequent protected actions require signing in again.

**Acceptance Scenarios**:

1. **Given** a signed-in user, **When** they choose to sign out, **Then** their session ends immediately and they are returned to the sign-in screen.
2. **Given** a user who has just signed out, **When** the application attempts any previously-scheduled or in-flight session renewal, **Then** it is aborted and does not silently sign the user back in.

---

### User Story 3 - Manage orders (Priority: P2)

A signed-in user views their organization's orders, creates a new order, opens an order's details, and (for users with elevated permissions) updates an order's status or cancels it.

**Why this priority**: Order management is the primary business workflow the package must expose once authenticated access is in place; it delivers the actual day-to-day value of the application.

**Independent Test**: Can be fully tested by signing in as a standard user, listing orders, filtering by status, opening one, then signing in as an elevated user to update its status and cancel another order.

**Acceptance Scenarios**:

1. **Given** a signed-in user, **When** they open the orders view, **Then** they see a paginated list of their organization's orders, newest first.
2. **Given** a signed-in user viewing the orders list, **When** they filter by a specific order status, **Then** only orders matching that status are shown.
3. **Given** a signed-in user, **When** they submit a new order with an order number and a positive total amount, **Then** the order is created and appears in the list.
4. **Given** a signed-in user, **When** they submit a new order with a missing order number or a non-positive total amount, **Then** they see a validation error and no order is created.
5. **Given** a signed-in user, **When** they open a specific order, **Then** they see its full details (order number, amount, status, creator, timestamps).
6. **Given** a user with elevated (admin) permissions viewing an order, **When** they open the status control, **Then** they are offered only the status changes that are actually permitted from the order's current state, and selecting one updates the order.
7. **Given** a user with elevated (admin) permissions, **When** they cancel an order, **Then** the order's status becomes Cancelled (the record is retained, not deleted) and the list reflects the new status.
8. **Given** a standard (non-admin) user, **When** they attempt to change an order's status or cancel an order, **Then** the action is blocked and they see a permission error.
9. **Given** a user creating an order, **When** the order number is already used within their organization, **Then** they see a specific "order number already exists" message, not a generic failure.
10. **Given** a user with elevated permissions, **When** they attempt to cancel an order that is already delivered or already cancelled, **Then** they see a specific explanation of why that action is not allowed.

---

### User Story 4 - Provision new accounts (Priority: P3)

An administrator creates a new standard user account for their organization, and a super administrator creates a new administrator account for a given organization.

**Why this priority**: Account provisioning is needed for the package to be a complete administrative surface, but organizations can operate with a small number of manually-provisioned accounts while the higher-priority sign-in and order flows are what end users touch daily.

**Independent Test**: Can be fully tested by signing in as an administrator, registering a new user, then signing in as that new user to confirm the account works.

**Acceptance Scenarios**:

1. **Given** a signed-in administrator, **When** they submit a new user's username and password, **Then** the account is created and the administrator sees a success confirmation.
2. **Given** a signed-in administrator submitting a new account, **When** the username is already taken or the password does not meet minimum strength requirements, **Then** they see a specific validation error.
3. **Given** a signed-in super administrator, **When** they register a new administrator account for a given organization, **Then** the account is created with administrator permissions scoped to that organization.
4. **Given** a signed-in standard user or administrator (not super administrator), **When** they attempt to register a new administrator account, **Then** the action is blocked and they see a permission error.

---

### Edge Cases

- What happens when the network is unavailable during sign-in, session renewal, or an order action? The user must see a clear, retryable error rather than a silent failure or an incorrect "signed out" state.
- What happens when a session-renewal attempt itself fails (renewal credential invalid, expired, or reused)? The user must be signed out cleanly and prompted to sign in again, with no repeated renewal loop.
- What happens when two or more browser tabs are open and one tab signs out or triggers a renewal? Real-time cross-tab synchronization is explicitly out of scope for this release (see Assumptions). A tab that was not the one to sign out may still believe it is signed in; when it next calls a protected endpoint, it must recover cleanly by signing itself out rather than failing silently or looping.
- What happens when multiple protected requests fire at nearly the same moment and the short-lived access credential has just expired? Exactly one session-renewal attempt must occur; the other requests must wait for it and then proceed, rather than each triggering its own renewal.
- How does the system respond when a user without sufficient permissions loads a screen or triggers an action reserved for a higher role (e.g., a standard user opening the order status/cancel controls, or an administrator trying to create another administrator)? Restricted actions must be hidden or disabled, and any attempted call must surface a clear permission error.
- What happens when the orders list is empty, or a requested order/user no longer exists?
- What happens when an action is rejected because it violates a business rule rather than a permission or validation rule (duplicate order number, cancelling an already-delivered order, an unsupported status transition)? The user must see the specific reason, and the offending control should where possible prevent the attempt in the first place.
- What happens when the session-renewal attempt is itself rejected for making too many attempts in a short period? This must NOT be treated as an invalid session: the user stays signed in and the renewal is retried after the indicated delay, because signing them out would turn a temporary throttle into lost work.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The package MUST let a user sign in with a username and password and reach a signed-in state on success.
- **FR-002**: The package MUST surface a clear, field-appropriate error when sign-in fails due to invalid credentials, without revealing which of the two fields was wrong.
- **FR-003**: The package MUST keep a signed-in user's session usable across page reloads and short periods of inactivity, without requiring re-entry of credentials, for as long as the underlying session remains valid.
- **FR-004**: The package MUST automatically renew an expired short-lived access credential using the session-renewal mechanism, transparently to the user, before retrying the action that triggered the renewal.
- **FR-005**: The package MUST coalesce concurrent renewal needs into a single in-flight renewal attempt, queuing other pending requests behind it rather than issuing parallel renewal attempts.
- **FR-006**: The package MUST treat the session-renewal credential as sensitive: it MUST NOT be readable or storable by application script, and MUST NOT be logged, displayed, or included in error reports.
- **FR-007**: The package MUST end the session immediately and irreversibly when the user signs out, canceling any pending or scheduled renewal.
- **FR-008**: The package MUST sign the user out and return them to the sign-in screen when session renewal itself fails (the session is invalid, expired, or has been revoked).
- **FR-009**: The package MUST let a signed-in user view a paginated list of their organization's orders, sorted with the most recently created first.
- **FR-010**: The package MUST let a signed-in user filter the orders list by order status.
- **FR-011**: The package MUST let a signed-in user create a new order by supplying an order number and a total amount greater than zero, and MUST reject submissions missing either or with a non-positive amount.
- **FR-012**: The package MUST let a signed-in user view the full details of a single order they have access to.
- **FR-013**: The package MUST let a user with elevated (admin or higher) permissions change an existing order's status, offering only the transitions valid from the order's current status (Pending → Shipped or Cancelled; Shipped → Delivered or Cancelled; Delivered and Cancelled are final) so users cannot select a change that is guaranteed to be rejected.
- **FR-014**: The package MUST let a user with elevated (admin or higher) permissions cancel an existing order, treating cancellation as a status change to Cancelled (the order is retained and remains viewable, not deleted), and MUST refresh the displayed order state afterward since the cancel action returns no order data.
- **FR-015**: The package MUST hide or disable order status-change and cancel controls for users without elevated permissions, and MUST treat any resulting rejection from the backend as an expected, cleanly-surfaced permission error rather than an unexpected failure.
- **FR-016**: The package MUST let a user with administrator permissions register a new standard user account with a username and password.
- **FR-017**: The package MUST let a user with super-administrator permissions register a new administrator account for a specified organization.
- **FR-018**: The package MUST hide or disable the administrator-registration action for users who are not super administrators, and MUST cleanly surface a permission error if attempted anyway.
- **FR-019**: The package MUST validate username (3-50 characters) and password (at least 8 characters) client-side before submission on every sign-in and account-registration form, in addition to surfacing server-side validation errors.
- **FR-020**: The package MUST present a distinct, human-readable error message for each backend error condition it can encounter (invalid credentials, expired/invalid session, validation failure, **business-rule violation**, permission denied, not found, rate-limited, network/server failure), and MUST do so reliably even though the backend returns these conditions in several different response formats — recognizing the condition MUST NOT depend on a single response layout.
- **FR-021**: The package MUST surface a clear, non-technical message and a retry option when a request is rejected for making too many attempts in a short period (rate limiting), rather than presenting it as a generic failure. When the rejected request is a session renewal, the package MUST keep the user signed in and retry after the indicated delay rather than signing them out.
- **FR-023**: The package MUST surface business-rule rejections (duplicate order number, cancelling a delivered or already-cancelled order, an unsupported status transition) with the specific reason returned by the service, distinct from input-validation and permission errors.
- **FR-022**: The package MUST expose its sign-in, session, and order capabilities as reusable building blocks (components and/or hooks) that a consuming application can compose, rather than as a single fixed page flow.

### Key Entities

- **Session**: Represents a signed-in user's ongoing authenticated state. Comprises a short-lived access credential (held only in application memory) and a longer-lived, rotating renewal credential (held only in a protected browser cookie, never touched by application code). Renewal issues a fresh pair and invalidates the previous renewal credential.
- **Account**: A user of the system, identified by a username, belonging to exactly one organization, holding one permission level (standard user, administrator, or super administrator).
- **Order**: A business record belonging to one organization, with an order number (unique within the organization), a total amount, a status (pending, shipped, delivered, cancelled), the account that created it, and creation/update timestamps. Status follows a one-way lifecycle: Pending may become Shipped or Cancelled; Shipped may become Delivered or Cancelled; Delivered and Cancelled are final.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A returning user with a still-valid session never sees a sign-in prompt caused by short-lived-credential expiry during normal use — renewal is invisible in at least 99% of expiry events encountered during typical usage.
- **SC-002**: Users see a specific, actionable error message (not a generic failure) for 100% of the known rejection reasons: bad credentials, expired session, validation failure, permission denied, not found, and rate-limited.
- **SC-003**: Zero renewal credentials are ever observable in application logs, browser script-accessible storage, or error reports, across all package builds.
- **SC-004**: A developer integrating the package can wire up a working sign-in-to-orders flow in a new application using only the package's exposed building blocks, without writing custom session-renewal or token-storage logic.
- **SC-005**: When two protected requests expire at effectively the same moment, exactly one renewal call is made and both original requests still succeed after it completes.
- **SC-006**: Standard users never see, and cannot successfully trigger, the order status-change/cancel or administrator-registration actions reserved for higher permission levels.
- **SC-007**: An elevated user is never offered an order status change that the service will reject as an invalid transition — zero avoidable business-rule rejections originate from the status control.

## Assumptions

- "Production behavior" for the refresh token means: the renewal credential is delivered and read only via a protected (httpOnly) cookie, never exposed to application script, rotates on every use, and a single renewal is shared across concurrent requests — matching how the auth-service `/api/v1/auth/refresh` endpoint already behaves.
- The three permission levels in scope are standard user, administrator, and super administrator, matching the roles already enforced by auth-service and order-service.
- The package targets the existing auth-service endpoints (sign in, session renewal, sign out, register user, register administrator) and order-service endpoints (list, filter, create, view, update status, cancel) as they exist today; new backend endpoints are out of scope.
- Password and username validation rules mirror the backend's existing rules (username 3-50 characters, password at least 8 characters) so users get instant feedback before a round trip to the server.
- This package is a reusable UI library (components/hooks) meant to be consumed by one or more HYDRA front-end applications, not a single standalone deployed app; however, it will include enough of an example/demo usage to verify each flow end-to-end during development.
- Every request against these endpoints is scoped to a single organization (tenant); how the active organization is determined for a given signed-in session is treated as a configuration detail supplied by the consuming application, not a user-facing flow this package must design.

- **Deployment topology constraint**: the session-renewal credential is issued as a strictly same-site cookie. The consuming application and the services must therefore be served from the same registrable domain (e.g. `app.hydra.com` and `api.hydra.com`, or different ports on `localhost`). If they are deployed to genuinely different sites, the browser withholds the renewal credential and every renewal fails — users would be signed out on every credential expiry with no diagnosable error. Supporting a cross-site deployment requires a backend cookie-policy change and accompanying cross-site request forgery protection, which is out of scope here (tracked separately).
- Browser access additionally depends on the services permitting the consuming application's origin, including exposing the retry-delay information the rate-limit messaging depends on. This is backend configuration the package cannot supply for itself.

### Out of Scope (deferred)

- **Real-time cross-tab logout synchronization**: deferred out of this MVP release. When one tab signs out, other open tabs are not notified in real time; they discover the ended session on their next protected request and sign themselves out cleanly at that point (the recovery path in Edge Cases). Building active cross-tab propagation is a candidate for a follow-up release.
