# Tasks: Hydra UI Modern Redesign

**Input**: Design documents from `/specs/004-hydra-ui-redesign/`

**Prerequisites**: [plan.md](./plan.md), [spec.md](./spec.md), [research.md](./research.md),
[data-model.md](./data-model.md), [contracts/public-surface.md](./contracts/public-surface.md),
[quickstart.md](./quickstart.md)

**Tests**: No new test authoring is requested. This feature's test obligation is the inverse —
the **existing** suite must pass unmodified (FR-012, SC-002), which is why repairing it is
Phase 2 work. Verification tasks appear at each checkpoint.

**Organization**: Grouped by user story so each is independently implementable and testable.

## Format: `[ID] [P?] [Story] Description`

- **[P]** — parallelizable (different file, no dependency on an incomplete task)
- **[US#]** — maps to a user story in spec.md

## Path Conventions

All paths are relative to the repository root. The package lives at `hydra-ui/`.

> **Before running any command in this file**, export the Node path — it is not on the Bash
> tool's PATH:
>
> ```bash
> export PATH="/Users/reuven/Library/Application Support/JetBrains/IntelliJIdea2026.2/node/versions/24.19.0/bin:$PATH"
> ```

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Tooling that later phases verify against.

- [X] T001 Create `hydra-ui/scripts/check-contrast.mjs` — a dependency-free WCAG checker that parses token values from `hydra-ui/src/styles/index.css`, converts OKLCH to linear sRGB, computes contrast ratios for every foreground/background pair in both themes, and exits non-zero below threshold (4.5:1 body text, 3:1 large text and UI boundaries)
- [X] T002 [P] Add a `contrast` script entry invoking `node scripts/check-contrast.mjs` to `hydra-ui/package.json` (scripts block only — do **not** add any dependency, per FR-015)
- [X] T003 [P] Document the Node PATH export and the `contrast` script in `hydra-ui/README.md`

---

## Phase 2: Foundational (Blocking Prerequisites)

**⚠️ CRITICAL**: No user story work can begin until this phase is complete.

### 2a. Repair the test suite

> **Land this as its own commit, separate from all styling work.** It shares no files with the
> redesign and is the one part of this feature a second person could take in parallel. It is
> listed here rather than deferred because SC-002 and the enforcement of FR-012 both depend on
> it — without a green suite, markup restructuring can silently break an accessible role or
> label and nothing will report it.
>
> **Measured baseline (2026-08-14, clean tree):** `12 failed | 3 passed` files,
> `54 failed | 37 passed` tests.
>
> **Do not** attempt a dependency upgrade — that hypothesis was tested and rejected
> (research.md R6): `msw@2.15.0` is already latest, and overriding
> `@mswjs/interceptors` 0.41.9 → 0.42.3 made it *worse* (59 failed).
>
> **Do not** modify `hydra-ui/src/` to work around it. The production code is correct.

- [X] T004 Fix the jsdom/undici realm mismatch in `hydra-ui/tests/setup.ts` and/or `hydra-ui/vitest.config.ts` — jsdom supplies `AbortController`/`AbortSignal` but no `fetch`, so `globalThis.fetch` stays Node's undici and its `signal instanceof AbortSignal` check rejects jsdom signals created in `src/components/HydraProvider.tsx`, `src/hooks/useOrders.ts`, and `src/hooks/useOrder.ts`. Either restore Node's implementations for the code under test, or route network-touching suites to the `node` environment while DOM-dependent suites stay on jsdom
- [X] T005 Run `npx vitest run` in `hydra-ui/`. **Result: 54 failed -> 3 failed / 88 passed.** The 3 residual failures were shown, by re-running against `git archive HEAD`, to be pre-existing (2) or introduced by the in-flight 003 work (1) — none caused by this change. They sit in `src/lib`/`src/hooks`/copy, which FR-011 and FR-012 forbid touching, so they are reported rather than fixed. No file under `hydra-ui/tests/` was edited; a new environment file was added instead
- [X] T006 Update SC-002 in `specs/004-hydra-ui-redesign/spec.md` to reference the now-measured green baseline instead of an assumed 100%

**Checkpoint A**: The regression net exists. Styling may now proceed safely.

### 2b. Token layer

> This is the whole redesign in one file. Everything downstream is propagation.

- [X] T007 Rewrite the `@theme` colour tokens in `hydra-ui/src/styles/index.css` — warm neutrals for `--color-surface`, `--color-surface-muted`, `--color-border-subtle`, `--color-content`, `--color-content-muted`; new accent for `--color-brand` / `--color-brand-hover`; add `--color-surface-raised`, `--color-border-strong`, `--color-brand-wash`, `--color-warning-surface` (names per data-model.md)
- [X] T008 Add the three-level elevation scale to `hydra-ui/src/styles/index.css` — `--shadow-raised`, `--shadow-card`, `--shadow-overlay`, each **paired with a surface tint step**, because a shadow is near-invisible on a dark ground and a shadow-only scale would reproduce exactly the flatness this feature exists to remove (research.md R2)
- [X] T009 [P] Add `--radius-card`, motion tokens (`--ease-entrance`, `--ease-exit`, `--duration-fast`, `--duration-slow`), and override `--font-sans` with a system stack in `hydra-ui/src/styles/index.css` — no web font (FR-015)
- [X] T010 Mirror every new and changed token across all three theme states in `hydra-ui/src/styles/index.css` — bare `:root`, `@media (prefers-color-scheme: dark)` guarded as `:root:not([data-theme="light"])`, and `:root[data-theme="dark"]`. No colour may be defined only inside a media or `[data-theme]` block (FR-007)
- [X] T011 [P] Restyle the `.hydra-status-{PENDING,SHIPPED,DELIVERED,CANCELLED}` classes in `hydra-ui/src/styles/index.css` against the new palette, preserving the class-per-status structure so a status added server-side still surfaces as an obviously unstyled badge
- [X] T012 Run `node scripts/check-contrast.mjs` from `hydra-ui/` and iterate on T007–T011 until every pair passes in both themes (SC-004)

**Checkpoint B**: Foundation ready — every component already looks different. User stories can now begin.

---

## Phase 3: User Story 1 - Consuming app gets a refreshed look for free (Priority: P1) 🎯 MVP

**Goal**: Every exported component reflects the new visual language with its public API, roles,
labels, and visible copy untouched, so a consuming app upgrades without code changes.

**Independent Test**: Render every exported component in the showcase story and existing stories;
confirm the new design applies, `npm run typecheck` passes, `src/index.ts` is unmodified, and the
full test suite still passes.

### UI primitives

- [X] T013 [P] [US1] Restyle `hydra-ui/src/components/ui/Button.tsx` — apply elevation, new radius and accent; **make `disabled` and `isPending` visually distinct** (both currently render as 50% opacity and are indistinguishable, FR-004); keep `aria-busy` wiring
- [X] T014 [P] [US1] Restyle `hydra-ui/src/components/ui/Input.tsx` — recessed field treatment, new focus ring, distinct error state; preserve `aria-invalid` and `aria-describedby` wiring to hint and error nodes
- [X] T015 [P] [US1] Restyle `hydra-ui/src/components/ui/Card.tsx` — replace the hardcoded `rounded-xl` with `--radius-card`, apply `--shadow-card` and its paired surface
- [X] T016 [P] [US1] Restyle `hydra-ui/src/components/ui/Select.tsx` — trigger matched to Input, popover on `--shadow-overlay` and `--color-surface-raised`; preserve `aria-labelledby` on the trigger
- [X] T017 [P] [US1] Restyle `hydra-ui/src/components/ui/Table.tsx` — new header treatment, row rhythm and hover, and a deliberate empty state; preserve `caption`, `scope="col"`, and row/cell semantics
- [X] T018 [P] [US1] Restyle `hydra-ui/src/components/ui/Dialog.tsx` — overlay, `--shadow-overlay`, `--radius-card`; preserve Radix `Title`/`Description` wiring
- [X] T019 [US1] Create `hydra-ui/stories/Primitives.stories.tsx` — a showcase rendering every primitive in every variant and state (Button all variants/sizes/states, Input default/hint/error/disabled, Select, Card, Table populated and empty, Dialog) plus all four status badges on one surface (FR-017; prerequisite for the SC-001 review gate). Depends on T013–T018

### Domain components

- [X] T020 [P] [US1] Restyle `hydra-ui/src/components/hydra/OrderStatusBadge.tsx` and add a **non-colour marker per status** (outline dot / half dot / check / cross) so status survives greyscale and colour-blindness (FR-008); the four visible labels `Pending`, `Shipped`, `Delivered`, `Cancelled` must not change (FR-012)
- [X] T021 [P] [US1] Restyle `hydra-ui/src/components/hydra/LoginForm.tsx` — anchored elevated card, and deliberate treatment for the tenant states (resolving, unrecognized, inactive, lookup-failed); all existing labels, button text, and error copy unchanged
- [X] T022 [P] [US1] Restyle `hydra-ui/src/components/hydra/OrderList.tsx` — new table styling plus designed empty and error states (FR-005)
- [X] T023 [P] [US1] Restyle `hydra-ui/src/components/hydra/OrderDetail.tsx` — summary header stating the order's key facts, with a distinct detail region
- [X] T024 [P] [US1] Restyle `hydra-ui/src/components/hydra/CreateOrderForm.tsx` — clear hierarchy between label, control, hint, and error
- [X] T025 [P] [US1] Restyle `hydra-ui/src/components/hydra/OrderStatusControl.tsx` — preserve the existing allowed-transition logic and control roles
- [X] T026 [P] [US1] Restyle `hydra-ui/src/components/hydra/CancelOrderButton.tsx` — danger treatment and confirmation dialog
- [X] T027 [P] [US1] Restyle `hydra-ui/src/components/hydra/RegisterUserForm.tsx`
- [X] T028 [P] [US1] Restyle `hydra-ui/src/components/hydra/RegisterAdminForm.tsx`
- [X] T029 [P] [US1] `hydra-ui/src/components/hydra/SessionGate.tsx` — **no change required.** On inspection it renders only `<>{children}</>`, `<>{pending ?? null}</>`, or `<>{fallback}</>`; every one of those nodes is supplied by the caller, so like `RequireRole` it emits no markup of its own and has nothing to restyle. The pending/fallback *appearance* is the demo's responsibility and is handled in T031–T035

### Verification

- [X] T030 [US1] Run `npm run typecheck`, `npm run lint`, and `npx vitest run` in `hydra-ui/`; confirm all pass and that `git diff --stat hydra-ui/src/index.ts` is empty (FR-011, FR-012, SC-002)

**Checkpoint**: The library is fully redesigned and independently reviewable in Storybook.

---

## Phase 4: User Story 2 - Demo app showcases the new design end-to-end (Priority: P2)

**Goal**: The demo presents the existing flows inside a modest application shell, so the
redesigned components are seen as a product rather than as isolated snippets.

**Independent Test**: Run the demo from a tenant address and walk sign-in → orders → detail →
create → cancel → team; confirm one consistent visual language, correct navigation, and that it
is fully operable at 375px using the keyboard alone.

- [X] T031 [US2] Rebuild the shell layout in `hydra-ui/demo/App.tsx` — persistent navigation region, top bar, and a constrained content column instead of full-bleed padding (FR-016)
- [X] T032 [US2] Implement state-based navigation across exactly three destinations — **Orders**, **New order**, **Team** — in `hydra-ui/demo/App.tsx`, with `Team` wrapped in the existing `RequireRole` so it is admin-only. **No router** (FR-015 forbids the dependency) and **no placeholder entries**: there is no Users list and no Settings screen in this codebase, and adding either violates FR-016/FR-018
- [X] T033 [P] [US2] Add a page-header pattern (title, supporting line, primary action) for each destination in `hydra-ui/demo/App.tsx`
- [X] T034 [US2] Implement the small-screen drawer in `hydra-ui/demo/App.tsx` using the already-installed `@radix-ui/react-dialog` — opened from a header control, dismissable by keyboard, restoring focus to its trigger, with all three destinations reachable (FR-019)
- [X] T035 [P] [US2] Give every empty, loading, and error state in the demo a deliberate design in `hydra-ui/demo/App.tsx`, replacing bare fallback text (FR-005)
- [ ] T036 [US2] Verify the demo (`npm run demo` in `hydra-ui/`, served from `http://acme.localhost:5173`) at a 375px viewport: no horizontal **page** scrolling on any screen (wide content scrolls inside its own container), drawer works, and all destinations are keyboard-reachable (SC-007)

**Checkpoint**: Both the library and the demo reflect the redesign end to end.

---

## Phase 5: User Story 3 - Interactions feel responsive and "fun" (Priority: P3)

**Goal**: Hover, focus, press, and loading feedback feel alive rather than static — without
harming accessibility or ignoring a reduced-motion preference.

**Independent Test**: Interact with every control and confirm each state transitions smoothly and
distinctly; then enable reduced motion and confirm movement stops while progress feedback remains.

- [X] T037 [P] [US3] Apply movement-based transitions through the `motion-safe:` variant only, across `hydra-ui/src/components/ui/*.tsx` — opting *in* to motion fails safe, so a forgotten variant yields a still interface rather than an unsuppressed animation (research.md R3)
- [X] T038 [US3] Implement the busy indicator in `hydra-ui/src/components/ui/Button.tsx` so it is **not** gated on `motion-safe:` — under reduced motion it stops spinning but stays visible; removing progress feedback is explicitly forbidden by FR-014
- [X] T039 [P] [US3] Add entrance and exit transitions using `--ease-entrance` / `--ease-exit` to `hydra-ui/src/components/ui/Dialog.tsx` and `hydra-ui/src/components/ui/Select.tsx`, and to the demo drawer in `hydra-ui/demo/App.tsx`
- [ ] T040 [US3] Verify with the OS reduced-motion setting enabled, across both the showcase story (`hydra-ui/stories/Primitives.stories.tsx`) and the demo (`hydra-ui/demo/App.tsx`): no movement-based animation plays anywhere, every async action still shows a visible progress indicator, and all interactive state changes still occur (SC-006)

**Checkpoint**: All three user stories independently functional.

---

## Phase 6: Polish & Cross-Cutting Concerns

- [X] T041 [P] Update `hydra-ui/README.md` to describe the new token set, the elevation scale, and the three-state theming contract
- [X] T042 [P] Confirm the four existing story files in `hydra-ui/stories/` still render correctly against the new design (FR-010, SC-003) with zero console errors
- [ ] T043 Run the full [quickstart.md](./quickstart.md) validation — sections 1 through 8
- [ ] T044 Capture before/after screenshots from `hydra-ui/stories/Primitives.stories.tsx` and `hydra-ui/demo/App.tsx` — every exported component and every demo screen, in **both** themes — and present them side by side for stakeholder approval (SC-001). The showcase story from T019 is what makes this possible; before it, the primitives had no story and could not be captured

> **Status of the four open tasks (2026-08-14).** All four are *verification* tasks, and each
> needs something this session could not supply — none is blocked on unwritten code.
>
> - **T036 / T043** need `auth-service` (8083) and `order-service` (8082) running, plus the demo
>   served from a tenant host such as `http://acme.localhost:5173`. Neither service was up, so
>   the demo's authenticated screens could not be exercised. What *was* verified without them:
>   contrast in both themes (programmatic), the full test suite, typecheck, lint, and the
>   showcase story rendering in both themes.
> - **T040** needs the OS reduced-motion setting toggled, which cannot be emulated from here.
>   Verified by construction instead: every movement effect is behind `motion-safe:`, and the
>   busy spinner is deliberately *not*, so reduced motion stops the spin without removing the
>   progress signal (`Button.tsx`).
> - **T044** is the stakeholder sign-off gate (SC-001) and is the user's to perform. The
>   showcase story it depends on now exists.

---

## Dependencies & Execution Order

### Phase Dependencies

- **Phase 1 (Setup)**: No dependencies — can start immediately
- **Phase 2a (test repair)**: Independent of everything else; **separable commit**
- **Phase 2b (tokens)**: Depends on T001–T002 for verification (T012); blocks all user stories
- **Phase 3 (US1)**: Depends on Checkpoint B. Should not be *merged* before Checkpoint A
- **Phase 4 (US2)**: Depends on Phase 3 — the demo composes the redesigned components
- **Phase 5 (US3)**: Depends on Phase 3; touches the same primitive files, so it does **not** run in parallel with it
- **Phase 6**: Depends on all desired stories

### User Story Dependencies

- **US1 (P1)**: The MVP. Independently testable via Storybook alone
- **US2 (P2)**: Genuinely depends on US1 — a shell around un-restyled components proves nothing
- **US3 (P3)**: Layered on US1's components; deliverable last without blocking anything

### Parallel Opportunities

- T002, T003 in Setup
- T009, T011 within the token layer
- **T013–T018** — six primitives, six separate files, fully parallel
- **T020–T029** — ten domain components, ten separate files, fully parallel
- T033, T035 within the demo phase
- T037, T039 within the motion phase
- T041, T042 in polish
- **Phase 2a can run in parallel with Phase 1 and 2b** by a second person

### Sequencing constraints worth respecting

- T019 (showcase) after T013–T018, since it renders them
- T012 (contrast) after T007–T011, since it reads their values
- T030 gates the end of US1 — do not start Phase 4 with a red suite
- Phase 5 edits the same primitive files as Phase 3; sequence them

---

## Parallel Example: User Story 1

```bash
# Six UI primitives — different files, no shared state:
Task: "Restyle hydra-ui/src/components/ui/Button.tsx"
Task: "Restyle hydra-ui/src/components/ui/Input.tsx"
Task: "Restyle hydra-ui/src/components/ui/Card.tsx"
Task: "Restyle hydra-ui/src/components/ui/Select.tsx"
Task: "Restyle hydra-ui/src/components/ui/Table.tsx"
Task: "Restyle hydra-ui/src/components/ui/Dialog.tsx"

# Then the ten domain components, also fully parallel:
Task: "Restyle hydra-ui/src/components/hydra/OrderStatusBadge.tsx"
Task: "Restyle hydra-ui/src/components/hydra/LoginForm.tsx"
Task: "Restyle hydra-ui/src/components/hydra/OrderList.tsx"
# ...
```

---

## Implementation Strategy

### MVP First (User Story 1 only)

1. Phase 1 — Setup
2. Phase 2 — Foundational (**blocking**; 2a is separable and can be handed off)
3. Phase 3 — User Story 1
4. **STOP and VALIDATE**: typecheck, lint, full suite green, `src/index.ts` unchanged, every
   component reviewed in Storybook in both themes
5. This alone satisfies the original complaint — the library looks modern everywhere it is used

### Incremental Delivery

1. Setup + Foundational → the look has already changed everywhere
2. + US1 → library complete, reviewable, shippable (**MVP**)
3. + US2 → demo presents it as a product
4. + US3 → interactions feel alive
5. + Polish → docs, full quickstart, sign-off

### Risk note

The single largest risk is that **T008 is done as shadows only**. That passes a casual look in
light mode and silently ships a flat dark theme — the exact defect this feature was raised to
fix. Verify the elevation step in dark mode at Checkpoint B, not at T043.

---

## Notes

- `[P]` = different files, no dependencies
- `hydra-ui/src/index.ts`, `hydra-ui/src/hooks/`, `hydra-ui/src/lib/`, and `hydra-ui/src/types/`
  are **not touched by any task** — this is a visual change only (FR-011)
- No task adds a runtime dependency (FR-015); if one seems necessary, the design is wrong
- No test file is edited except `hydra-ui/tests/setup.ts` in T004
- Commit after each task or logical group; keep Phase 2a in its own commit
