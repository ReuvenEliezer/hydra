# Implementation Plan: Hydra UI Modern Redesign

**Branch**: `004-hydra-ui-redesign` | **Date**: 2026-08-14 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/004-hydra-ui-redesign/spec.md`

## Summary

Replace the visual language of `@hydra/ui` — a published React component library for HYDRA's
auth and order services — and restructure its bundled demo into a modest application shell,
without changing a single prop, event signature, or accessible name.

The current interface reads as inert because the token layer has exactly one border colour, one
radius, and no elevation, so no surface recedes or advances. The fix is therefore mostly one
file: extend `@theme` in `src/styles/index.css` with an elevation scale, warm neutrals, a new
accent, motion curves, and a system font stack, then propagate through 6 primitives and 10
domain components. The demo gains state-based navigation (no router), a page-header pattern, a
constrained content column, and a drawer at small widths.

Two prerequisites gate the styling work, both found during Phase 0:

1. **The test suite does not currently pass** — 54 of 91 tests fail on a
   `@mswjs/interceptors` / Node 24 incompatibility, entirely inside `node_modules`. Until
   repaired there is no regression net, and FR-012 (the requirement most likely to be violated
   silently by markup restructuring) is unenforceable.
2. **No contrast tooling exists**, so SC-004's "every pair, both themes" cannot be evidenced.

## Technical Context

**Language/Version**: TypeScript 5.7, React 19.2.8, Node 24.19.0

**Primary Dependencies**: Tailwind CSS 4.3.3 (CSS-first `@theme`, no JS config),
`@radix-ui/react-dialog` 1.1.23, `@radix-ui/react-select` 2.3.7, `lucide-react` 0.468.0.
**No new runtime dependencies may be added** (FR-015).

**Storage**: N/A — no persisted state beyond the demo's existing `localStorage` theme key.

**Testing**: Vitest 2.1.9 + Testing Library + MSW 2.15.0 (jsdom). Storybook 8.4 for visual
review.

**Target Platform**: Evergreen browsers. Published as an ESM package consumed by host React
applications.

**Project Type**: Component library (`hydra-ui/src`) plus a bundled reference application
(`hydra-ui/demo`) that is not published.

**Performance Goals**: No runtime budget applies — this is a styling change. The binding
constraint is bundle impact: zero added runtime dependencies and no web font (FR-015).

**Constraints**: WCAG AA contrast in both themes (SC-004); visible focus on every interactive
element (SC-005); reduced motion honoured without losing progress feedback (SC-006); no
horizontal page scroll at 375px (SC-007); public TypeScript surface frozen (FR-011); accessible
roles, labels, and visible copy frozen (FR-012).

**Scale/Scope**: ~1,470 lines across 6 UI primitives, 11 domain components, 1 stylesheet, and a
4-file demo. 15 test files / 91 tests. 4 existing Storybook story files, plus 1 new showcase.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-checked after Phase 1 design.*

The constitution governs the Java/Spring backend. Most principles do not reach a frontend-only
change; they are recorded as N/A rather than silently skipped.

| Principle | Applies? | Assessment |
|---|---|---|
| I — Framework-Free Shared Core (`infra-shared` stays POJO) | No | Touches no Java module. |
| II — Dedicated Modules for Cross-Cutting Concerns | No | Introduces no infrastructure concern. |
| III — Load-Path-Authoritative Paths | **Yes, narrowly** | `@hydra/ui/styles.css` maps to `dist/hydra-ui.css` via `exports` in `package.json`. That mapping is a functional contract for consumers; the redesign must not rename or restructure the stylesheet entry point. Recorded in contracts/public-surface.md §5. |
| IV — Atomic Distributed State Mutations | No | No Redis, no distributed state. |
| V — Audit Before Building (NON-NEGOTIABLE) | **Yes** | Satisfied. Every technical claim in research.md was verified against installed packages and the source tree. This audit is what surfaced the broken test baseline (R6), the absence of class-name coupling (R8), and the dark-mode shadow problem (R2) — none of which were visible from the spec or prior docs. |

**Gate result: PASS.** No violations; Complexity Tracking is therefore empty.

**Post-Phase-1 re-check: PASS.** The design adds no dependency, no module, and no new
classpath-style path contract. Principle V continues to be honoured: the plan's two prerequisite
tasks exist precisely because the audit contradicted assumptions the spec had made.

## Project Structure

### Documentation (this feature)

```text
specs/004-hydra-ui-redesign/
├── plan.md                      # This file
├── spec.md                      # Feature specification (7 clarifications integrated)
├── research.md                  # Phase 0 output
├── data-model.md                # Phase 1 output — the design token set
├── quickstart.md                # Phase 1 output — validation guide
├── contracts/
│   └── public-surface.md        # Phase 1 output — what consumers may rely on
├── checklists/
│   └── requirements.md          # Spec quality checklist (16/16)
└── tasks.md                     # Phase 2 output (/speckit-tasks — NOT created here)
```

### Source Code (repository root)

```text
hydra-ui/
├── src/
│   ├── styles/
│   │   └── index.css            # PRIMARY CHANGE — @theme tokens, 3-state dark, status classes
│   ├── components/
│   │   ├── ui/                  # Button, Card, Dialog, Input, Select, Table — restyled
│   │   └── hydra/               # LoginForm, OrderList, OrderDetail, CreateOrderForm,
│   │                            #   OrderStatusBadge, OrderStatusControl, CancelOrderButton,
│   │                            #   RegisterUserForm, RegisterAdminForm, SessionGate
│   │                            #   (RequireRole renders no markup — out of visual scope)
│   ├── hooks/                   # UNCHANGED
│   ├── lib/                     # UNCHANGED
│   ├── types/                   # UNCHANGED
│   └── index.ts                 # UNCHANGED (frozen public surface, FR-011)
├── stories/
│   └── Primitives.stories.tsx   # NEW — showcase for review (FR-017)
├── scripts/
│   └── check-contrast.mjs       # NEW — dependency-free WCAG verification (SC-004)
├── demo/
│   ├── App.tsx                  # Rebuilt — shell, state-based nav, drawer
│   ├── useTheme.ts              # Retained
│   └── index.css                # Retained
└── tests/                       # UNCHANGED LOGIC — must pass unmodified (FR-012, SC-002)
```

**Structure Decision**: Existing `hydra-ui` package layout is kept as-is. No new directories
beyond `scripts/` (contrast checker) and one new story file. The change is deliberately
concentrated in `src/styles/index.css` so that the visual language has one authority and the
component edits are mechanical propagation rather than independent styling decisions.

## Implementation Sequence

Ordered so that each stage is independently verifiable. Detailed task breakdown is
`/speckit-tasks` output; this is the shape.

**Stage 0 — Prerequisites (blocking).** Repair the test suite (research.md R6) so the regression
net exists before anything is restyled. Add `scripts/check-contrast.mjs`. Re-anchor SC-002 to
the measured, now-green baseline.

**Stage 1 — Token layer.** Rewrite the `@theme` block: warm neutrals, new accent, 3-step
elevation paired with surface tints, radius scale, motion tokens, system font stack. Mirror
every token across all three theme states. Run the contrast checker; iterate until clean. This
stage alone changes the look of every component.

**Stage 2 — UI primitives.** Button (including making disabled and busy visually distinct),
Input, Card, Select, Table, Dialog. Add the showcase story (FR-017) alongside, so each primitive
is reviewable as it lands.

**Stage 3 — Domain components.** Ten components inherit most of their appearance through
composition; the real work is status badges gaining non-colour markers (FR-008), and empty,
loading, and error states gaining deliberate design (FR-005).

**Stage 4 — Demo shell.** State-based navigation across Orders / New order / Team, page-header
pattern, constrained content column, drawer below the breakpoint with focus handling.

**Stage 5 — Verification and sign-off.** Full quickstart pass: tests, typecheck, contrast,
keyboard, reduced motion, 375px, both themes. Then capture before/after screenshots of every
component and screen in both themes for the SC-001 gate.

## Risks

| Risk | Mitigation |
|---|---|
| **Elevation invisible in dark mode**, reproducing the exact flatness this feature exists to fix | Every elevation level pairs a shadow with a surface tint; dark mode leans on the tint (research.md R2). Verified visually in Stage 1, not deferred to Stage 5. |
| **Markup restructuring silently breaks accessible queries** — the suite is the only thing that catches it | Stage 0 makes the suite green first. FR-012 states the constraint in the terms the suite actually uses (roles / labels / text), verified as the real coupling in R8. |
| Test repair (Stage 0) turns out to be large — an msw major upgrade could churn `tests/mocks/` | Bounded by preferring a patch/minor bump or a Node pin. If it proves large, it is separable work and should be split out rather than absorbed silently into a styling feature. |
| Accent change collides with consumer overrides that hardcoded the old blue | Accepted and documented — it is the intended effect (contracts/public-surface.md §4, spec Edge Cases). |
| Scope creep from "the demo looks thin" into building real features | FR-016 and FR-018 forbid it, and FR-018 exists specifically because the review mockup had already drifted into inventing a Users list and a Settings screen. |

## Complexity Tracking

No constitution violations. Table intentionally empty.
