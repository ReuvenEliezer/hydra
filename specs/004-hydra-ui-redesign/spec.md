# Feature Specification: Hydra UI Modern Redesign

**Feature Branch**: `004-hydra-ui-redesign`

**Created**: 2026-08-14

**Status**: Draft

**Input**: User description (translated): "The current UI design looks awful and unwelcoming. I want a full redesign of the whole UI — modern, fun, and pleasant to use."

## Clarifications

### Session 2026-08-14

- Q: What visual personality should the redesign commit to? → A: Warm & tactile (Stripe/Height style) — soft layered shadows, generous spacing, rounded corners, a confident accent plus warm neutrals, smooth easing.
- Q: Should the new animations be suppressed for users who have asked their OS to reduce motion? → A: Yes — honor `prefers-reduced-motion` and degrade gracefully: drop transforms/springs, keep instant state changes and non-moving loading indicators.
- Q: May the redesign add new runtime dependencies (web font, animation library)? → A: No — zero new runtime dependencies. Motion is CSS-only, typography uses a system font stack, icons continue to come from the already-installed icon library.
- Q: Should the demo app keep its bare structure or be rebuilt into an application shell? → A: Modest shell — persistent nav/header, page title areas, constrained content width, and proper empty & error states; no new product features or routed dashboard.
- Q: How should "the redesign looks good" be signed off? → A: Stakeholder sign-off on a before/after review — screenshots of every component and demo screen, in both light and dark themes, presented side by side for approval.
- Q: What should the demo's navigation actually contain? → A: Orders, New order, and Team (register user / register admin, admin-only). Every entry must map to an already-existing capability; no placeholder or non-functional entries.
- Q: What should the sidebar navigation do on a phone-sized screen? → A: Collapse to an off-canvas drawer below a breakpoint, opened by a menu button in the header, with content taking full width underneath.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Consuming app gets a refreshed look for free (Priority: P1)

A developer building an app on top of `@hydra/ui` (login, registration, order management screens) upgrades to the redesigned component library and their screens immediately look modern, polished, and inviting — without having to rewrite how they use each component.

**Why this priority**: This is the actual deliverable — the component library is what every consuming application (including the bundled demo) inherits its look from. If this isn't right, nothing downstream matters.

**Independent Test**: Render each exported component (Button, Card, Dialog, Input, Select, Table, OrderStatusBadge, LoginForm, RegisterUserForm, RegisterAdminForm, OrderList, OrderDetail, OrderStatusControl, CreateOrderForm, CancelOrderButton, SessionGate) in isolation (e.g., via Storybook) and confirm each reflects the new visual language, with existing props/behavior unchanged.

**Acceptance Scenarios**:

1. **Given** the redesigned library is installed, **When** a consuming app renders existing components with their existing props, **Then** the components render without code changes and visually reflect the new design (colors, typography, spacing, shadows, motion).
2. **Given** a component previously accepted a `className` override, **When** the redesign ships, **Then** the same override mechanism still works.
3. **Given** the app's `data-theme` is unset, `"light"`, or `"dark"`, **When** components render, **Then** each theme reflects the new palette with sufficient contrast (WCAG AA).

---

### User Story 2 - Demo app showcases the new design end-to-end (Priority: P2)

A developer or stakeholder opens the bundled demo app (`hydra-ui/demo`) to evaluate the library and sees a cohesive, modern, inviting experience across login, registration, and order-management flows — not a bare-bones or dated-looking screen.

**Why this priority**: The demo is the primary way anyone (including the user) visually judges "does this look good now." It proves the redesign works as a real, assembled UI rather than isolated component snippets.

**Independent Test**: Run the demo app locally, walk through login, registration, order list, order detail, and order creation/cancellation, and confirm every screen uses the new visual language consistently (no leftover old styling, no visual regressions in layout or readability).

**Acceptance Scenarios**:

1. **Given** the demo app is running, **When** a user views the login screen, **Then** the layout, colors, and typography match the new modern style guide.
2. **Given** a user navigates from login to the order list to an order detail view, **Then** visual language (spacing, color usage, component styling) stays consistent across all screens.
3. **Given** a user triggers a validation error, loading state, or empty state in any flow, **When** it appears, **Then** it is styled consistently with the new design rather than falling back to unstyled or default browser appearance.

---

### User Story 3 - Interactions feel responsive and "fun" (Priority: P3)

A user interacting with buttons, forms, and status changes notices smooth, subtle motion and feedback (hover/press/focus states, loading indicators, transitions) that make the interface feel alive rather than static.

**Why this priority**: This is what turns "modern-looking" into "fun to use" — motion and micro-interactions are the layer above static visual style, valuable but not blocking if the static redesign lands first.

**Independent Test**: Interact with buttons, inputs, selects, and status badges and observe hover/focus/active/disabled/loading states each have distinct, smooth visual feedback (transitions, not instant jumps), without harming keyboard/focus accessibility.

**Acceptance Scenarios**:

1. **Given** a user hovers or focuses an interactive element (button, input, select, table row action), **Then** it transitions smoothly to a distinct visual state.
2. **Given** an async action is in flight (login, order creation, status update), **Then** a loading state is visually communicated (e.g., animated spinner/skeleton) instead of the UI appearing frozen.
3. **Given** a user navigates via keyboard only, **When** focus moves between interactive elements, **Then** a clearly visible focus indicator is present at every step.

---

### Edge Cases

- What happens to consuming apps that pass custom `className` values expecting the *old* visual tokens (e.g., hardcoded `bg-brand`)? The old token names should keep working with new values, so existing overrides still compose rather than visually clash.
- How does the redesign behave for long content (long tenant names, long order lists, long error messages) — does the new spacing/typography still wrap and truncate gracefully?
- How do status badges (`PENDING`, `SHIPPED`, `DELIVERED`, `CANCELLED`) stay visually distinguishable at a glance under the new palette, including for color-blind users (not color alone)?
- What happens in dark mode — does the "fun/modern" styling (e.g., accent gradients, shadows) still hold up, or does it wash out?
- Small viewports are resolved by FR-019 (navigation collapses to a drawer; no horizontal page scrolling). Still open: how individual components behave at very large (ultrawide) widths — the constrained content column in FR-016 should prevent line lengths from becoming unreadable, but this is unverified.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The design system MUST replace the current visual tokens (colors, radii, shadows, spacing scale) in `src/styles/index.css` with a modern, cohesive palette and scale, while keeping the same token names so consuming apps' overrides continue to resolve.
- **FR-002**: Every component under `src/components/ui` (Button, Card, Dialog, Input, Select, Table) MUST be restyled to use the refreshed tokens, with no change to its public props/behavior.
- **FR-003**: Every domain component under `src/components/hydra` that renders markup of its own (LoginForm, RegisterUserForm, RegisterAdminForm, OrderList, OrderDetail, OrderStatusBadge, OrderStatusControl, CreateOrderForm, CancelOrderButton, SessionGate) MUST visually adopt the refreshed design without changing its props, events, or data contracts. `RequireRole` is explicitly out of visual scope: it renders only its children or a caller-supplied fallback and emits no markup of its own, so it has nothing to restyle.
- **FR-004**: Interactive elements (buttons, inputs, selects, table rows, links) MUST have distinct, animated hover, focus, active, and disabled visual states. Disabled and busy/pending MUST be visually distinguishable from each other (today both render as 50% opacity and are indistinguishable).
- **FR-005**: Components with asynchronous behavior (login, order actions) MUST expose a visually styled loading/busy state consistent with the new design.
- **FR-006**: The redesign MUST preserve or improve accessibility: focus indicators MUST remain visible, and text/background color pairs MUST meet WCAG AA contrast in both light and dark themes.
- **FR-007**: The redesign MUST preserve the existing light/dark theme mechanism (`prefers-color-scheme` plus `data-theme` override) with both palettes updated to the new visual language.
- **FR-008**: Order status badges MUST remain visually distinguishable from one another after restyling, using shape/icon/label in addition to color so status is not conveyed by color alone.
- **FR-009**: The demo app (`hydra-ui/demo`) MUST be updated so every screen (login, registration, order list, order detail, order creation, cancellation) reflects the redesigned components end-to-end, with no leftover pre-redesign styling.
- **FR-010**: Storybook stories under `hydra-ui/stories` MUST continue to render each component correctly against the new design so they remain a valid living reference.
- **FR-011**: The redesign MUST NOT change any component's exported TypeScript prop types or event signatures.
- **FR-012**: The redesign MUST preserve the accessible query surface the existing test suite depends on: every interactive element MUST keep its current ARIA role, every form control MUST keep its current accessible label, and user-visible copy asserted by tests (button text, headings, status labels, error messages) MUST remain unchanged. Restructuring markup for visual purposes is allowed only where these three are preserved. Existing unit/component/integration tests MUST continue to pass unmodified.
- **FR-013**: The visual language MUST follow a **warm & tactile** direction: warm-tinted neutrals (not pure grey), a confident single accent, generous spacing, rounded corners, and smooth easing. Concretely, the token set MUST introduce a **multi-step elevation/shadow scale** and MUST NOT rely on a single 1px border as the only means of separating surfaces — the current design's flatness stems from every surface (card, table, input, dialog) sharing one border treatment with no elevation, and the redesign MUST establish visible depth hierarchy between them.
- **FR-014**: All motion MUST respect the user's reduced-motion preference. When reduced motion is requested, movement-based effects (transforms, springs, slides, parallax) MUST be suppressed while state changes still occur instantly and asynchronous work still shows a non-moving progress indicator — reduced motion MUST NOT remove loading feedback.
- **FR-015**: The redesign MUST NOT add any new runtime dependency to the published package. Motion MUST be expressed in CSS, typography MUST use a system font stack (no bundled or network-loaded web font), and icons MUST come from the already-installed icon library. Rationale: this is a published library, so every added dependency is imposed on every consuming application's bundle, and a library cannot load a web font without dictating network behavior to its host app.
- **FR-016**: The demo app MUST be restructured into a modest application shell: a persistent navigation/header region, a page title area per screen, a constrained content width rather than full-bleed padding, and deliberately designed empty and error states. It MUST NOT add new product features, routed dashboards, or summary/analytics screens — the shell exists to present the existing flows, not to extend them.
- **FR-017**: A showcase story MUST exist that renders every UI primitive (Button in all variants/sizes/states, Input including hint/error/disabled, Select, Card, Table populated and empty, Dialog) and every order status badge on a single surface. This is a prerequisite for the SC-001 review gate: today the primitives have no story at all, so there is no way to view or screenshot them, and the redesign cannot be visually approved without one.
- **FR-018**: The demo navigation MUST contain exactly three destinations — **Orders**, **New order**, and **Team** (user and admin registration, visible only to users holding the admin role) — plus sign-out. Every navigation entry MUST correspond to a capability that already exists in the library; placeholder, disabled, or non-functional entries (e.g. a "Users" list or a "Settings" screen) MUST NOT appear, since no such capability exists and adding one would violate FR-016.
- **FR-019**: Below a small-screen breakpoint the navigation MUST collapse into an off-canvas drawer opened by a menu control in the header, with page content occupying the full width beneath it. The drawer MUST be dismissable by keyboard as well as pointer, MUST return focus to the control that opened it, and all three destinations MUST remain reachable at small sizes. No screen may require horizontal page scrolling to operate; wide content such as the order table scrolls within its own container instead.

### Key Entities

- **Design tokens**: The named set of colors, radii, shadows, spacing, and typography values (currently in `src/styles/index.css`) that all components draw from; the redesign changes their values, not their names.
- **UI primitive components**: Low-level, reusable building blocks (Button, Card, Dialog, Input, Select, Table) with no business logic, restyled but functionally unchanged.
- **Domain components**: Higher-level components (forms, order views, status controls) composed from UI primitives, inheriting the new look through composition.
- **Demo app**: The reference application bundled in `hydra-ui/demo` that assembles domain components into full screens.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: The stakeholder approves a before/after visual review covering every exported component and every demo screen, captured in both light and dark themes and presented side by side. This is the sole subjective acceptance gate; SC-002 through SC-006 remain objectively verifiable.
- **SC-002**: The redesign introduces **zero new test failures** against a measured baseline, with no changes to test logic. Baseline established 2026-08-14 after repairing the test environment: **88 of 91 tests pass**. The 3 known failures are pre-existing and outside this feature's scope — two exist on committed code (`useLogout > ignores an in-flight refresh…`, `LoginForm > never reveals which credential was wrong`) and one comes from the in-flight 003 tenant work (`credential-validation > LoginForm rejects an over-long password`). All three live in `src/lib`, `src/hooks`, or message copy, which FR-011 and FR-012 forbid this feature from touching. Acceptance is therefore "still 88 passing, still the same 3 failing", not an assumed 100%.
- **SC-003**: 100% of exported components render correctly in Storybook with the new design applied, with zero console errors.
- **SC-004**: Every text/background color combination used in components meets WCAG AA contrast (4.5:1 for normal text, 3:1 for large text/UI components) in both light and dark themes.
- **SC-005**: All interactive elements exhibit a visible, distinct focus state reachable by keyboard-only navigation across every redesigned screen in the demo app.
- **SC-006**: With the reduced-motion preference enabled, no movement-based animation plays anywhere in the demo app or showcase story, while every asynchronous action still displays a visible progress indicator and every interactive state change still occurs.
- **SC-007**: At a 375px-wide viewport, every demo screen is fully operable with no horizontal page scrolling, and all three navigation destinations are reachable via the drawer using keyboard alone.

## Assumptions

- "Redesign the entire UI" refers to the `@hydra/ui` component library (all `src/components` and its design tokens) plus the bundled demo app that showcases it — not the unrelated `auth-service`/`order-service` backend code.
- This is a **visual and interaction refresh only**: component public APIs (props, emitted events, data contracts, accessibility attributes) stay backward compatible so apps already consuming `@hydra/ui` do not need code changes to upgrade.
- No existing brand guideline or fixed color palette was supplied. The visual direction was resolved by clarification (see Clarifications) to **"warm & tactile"** rather than left to interpretation; FR-013 states it as a requirement.
- Both light and dark themes remain supported, since the current library already implements both via `prefers-color-scheme` and `data-theme`.
- Existing test coverage is the acceptance bar for "nothing broke" — visual regression is judged manually/by demo review, not by a new automated visual-diffing tool (none exists in this repo today).
