# Phase 1 Data Model: Hydra UI Modern Redesign

**Feature**: 004-hydra-ui-redesign | **Date**: 2026-08-14

This feature introduces no runtime data entities — no API shapes change, no persisted state is
added. Its "data model" is the **design token set**: the named values every component resolves
against. They are declared in `hydra-ui/src/styles/index.css` inside `@theme`, which is what
makes them real Tailwind utilities (see research.md R1).

---

## Entity: Colour token

Existing token **names are preserved**; only values change (FR-001). New names are additive.

| Token | Role | Change |
|---|---|---|
| `--color-surface` | Base card/panel ground | Value only — warmed |
| `--color-surface-muted` | Recessed ground (table head, inputs) | Value only — warmed |
| `--color-surface-raised` | Elevated ground (dialog, popover) | **New** — carries dark-mode elevation (R2) |
| `--color-border-subtle` | Hairline separator | Value only — warmed |
| `--color-border-strong` | Emphasised separator | **New** — gives borders a second step |
| `--color-content` | Primary text | Value only — warm near-black |
| `--color-content-muted` | Secondary text | Value only |
| `--color-brand` | Accent | Value — from blue to the chosen accent |
| `--color-brand-hover` | Accent, hovered | Value |
| `--color-brand-content` | Text on accent | Unchanged (white) |
| `--color-brand-wash` | Tinted accent ground (nav active, avatar) | **New** |
| `--color-danger` / `--color-danger-surface` | Error | Value only |
| `--color-success` | Delivered / success | Value only |
| `--color-warning` | Warning | Value only |
| `--color-warning-surface` | Warning ground | **New** — the warning colour had no paired ground |

**Validation rules**

- Every foreground/background pair must meet WCAG AA in **both** themes: 4.5:1 for body text,
  3:1 for large text and UI boundaries (SC-004), enforced by the script in research.md R5.
- Every token above must be defined in all three theme states — bare `:root` (light),
  `@media (prefers-color-scheme: dark)` guarded as `:root:not([data-theme="light"])`, and
  `:root[data-theme="dark"]` — preserving the existing three-state mechanism (FR-007).
- No colour may be defined *only* inside a media or `[data-theme]` block.

---

## Entity: Elevation token

**New.** Each level is a pair — a shadow *and* a surface tint — because shadow alone does not
read on a dark ground (research.md R2).

| Token | Applied to | Paired surface |
|---|---|---|
| `--shadow-raised` | Buttons, inputs at rest | `--color-surface` |
| `--shadow-card` | Cards, tables, panels | `--color-surface` |
| `--shadow-overlay` | Dialog, select popover, drawer | `--color-surface-raised` |

**Validation rules**

- Exactly three levels. A fourth invites inconsistent usage without adding hierarchy.
- In dark mode the visual step between levels must come from the surface tint; the shadow is
  supplementary and may be near-invisible.
- FR-013: no surface may rely on a single 1px border as its only separation from its parent.

---

## Entity: Radius token

| Token | Role | Change |
|---|---|---|
| `--radius-control` | Buttons, inputs, selects | Value — increased |
| `--radius-card` | Cards, tables, dialogs, drawer | **New** — replaces the hardcoded `rounded-xl` currently inlined in Card, Table, and Dialog |

---

## Entity: Motion token

**New.** Required so motion is consistent and so FR-014's reduced-motion rule has one place to
reason about.

| Token | Role |
|---|---|
| `--ease-entrance` | Elements appearing (dialog, drawer, popover) |
| `--ease-exit` | Elements leaving |
| `--duration-fast` | Hover / focus / colour state changes |
| `--duration-slow` | Drawer and dialog transitions |

**Validation rules**

- Movement-based effects (transform, translate) are applied through `motion-safe:` only (R3).
- Colour, opacity, and the busy indicator are **not** gated on `motion-safe:` — FR-014 requires
  progress to remain visible under reduced motion.

---

## Entity: Typography token

| Token | Role | Change |
|---|---|---|
| `--font-sans` | All UI text | **Overridden** to a system stack — no web font (FR-015) |

---

## Entity: Order status presentation

Not a new data entity — `OrderStatus` (`PENDING`, `SHIPPED`, `DELIVERED`, `CANCELLED`) is
unchanged and still owned by the backend. What changes is its **presentation contract**.

| Status | Colour role | Non-colour marker (FR-008) |
|---|---|---|
| `PENDING` | neutral | outline dot |
| `SHIPPED` | brand | half-filled dot |
| `DELIVERED` | success | check |
| `CANCELLED` | danger | cross |

**Validation rules**

- Status must remain distinguishable without colour — the marker and the existing text label
  both carry it (FR-008).
- The visible label text (`Pending`, `Shipped`, `Delivered`, `Cancelled`) is asserted by tests
  and **must not change** (FR-012).
- The existing `.hydra-status-{STATUS}` class-per-status structure is retained, so a status
  added server-side still surfaces as an obviously unstyled badge rather than a silently wrong
  one — this is deliberate existing behaviour and the redesign must not regress it.

---

## State: Demo navigation

The demo gains view state; the library does not.

| State | Values | Notes |
|---|---|---|
| Active destination | `orders` \| `new-order` \| `team` | React state, not a route (R4, FR-015) |
| Drawer open | `true` \| `false` | Only meaningful below the small-screen breakpoint (FR-019) |

**Validation rules**

- `team` is rendered only for sessions holding the admin role, via the existing `RequireRole`
  component (FR-018).
- Every destination maps to a capability that already exists; no placeholder entries (FR-018).
- Drawer must be dismissable by keyboard and must restore focus to its trigger (FR-019).
