# Phase 0 Research: Hydra UI Modern Redesign

**Feature**: 004-hydra-ui-redesign | **Date**: 2026-08-14

All findings below were verified against the installed toolchain and the actual source tree,
not from documentation or recall, per Constitution Principle V (Audit Before Building).

**Verified environment**

| Package | Version |
|---|---|
| tailwindcss | 4.3.3 |
| react | 19.2.8 |
| vite | 6.4.3 |
| @radix-ui/react-dialog | 1.1.23 |
| @radix-ui/react-select | 2.3.7 |
| lucide-react | 0.468.0 |
| vitest | 2.1.9 |
| msw | 2.15.0 |
| @mswjs/interceptors | 0.41.9 |
| node | 24.19.0 (JetBrains-managed; **not on the default shell PATH**) |

---

## R1 — Where the new tokens live

**Decision**: Extend the existing `@theme` block in `hydra-ui/src/styles/index.css`. Add
`--shadow-*` (elevation), `--ease-*` (motion curves), and `--font-sans` (system stack)
alongside the existing `--color-*` and `--radius-*` tokens.

**Rationale**: Verified by reading `node_modules/tailwindcss/theme.css` — `--shadow-*`,
`--inset-shadow-*`, `--radius-*`, `--ease-*`, and `--font-*` are all real first-class `@theme`
namespaces in 4.3.3, so values declared there become genuine utilities (`shadow-md`,
`ease-out`, `rounded-card`). This is what lets a consuming app restyle a component through
`className` without forking it, which is the property FR-001 requires be preserved.

**Alternatives considered**: Plain CSS custom properties on `:root` — rejected, they would not
generate utilities, so components would need hardcoded `style={{}}` or arbitrary-value classes
and the override mechanism in FR-001 would break.

---

## R2 — Elevation must not be shadow-only in dark mode

**Decision**: The elevation scale carries **two** signals per level: a `box-shadow` **and** a
surface-tint step (`--color-surface-1` / `-2` / `-3`, each slightly lighter than the last).
Light mode leans on the shadow; dark mode leans on the tint.

**Rationale**: This is the single most likely way to satisfy FR-013 on paper and still ship a
flat-looking dark theme. A `box-shadow` is a dark halo — on a near-black ground it is close to
invisible, so a shadow-only scale silently degrades to no hierarchy at all in dark mode,
reproducing exactly the defect this feature exists to fix. Material and GitHub Primer both
solve this with surface tinting rather than shadows.

**Alternatives considered**: Shadow-only (rejected: fails in dark mode as above); border-color
stepping only (rejected: FR-013 explicitly forbids making a single border treatment the only
separator).

---

## R3 — Reduced motion

**Decision**: Use Tailwind's `motion-safe:` variant to *apply* movement, rather than
`motion-reduce:` to remove it. Movement-based utilities (transforms, translations) are written
`motion-safe:transition-transform`; colour/opacity transitions and the busy indicator stay
unconditional.

**Rationale**: Verified present in `tailwindcss@4.3.3` — both `motion-safe` and `motion-reduce`
variants exist, backed by `prefers-reduced-motion: no-preference` / `reduce`. Opting *in* to
motion is fail-safe: a component author who forgets the variant produces a still interface, not
an unsuppressed animation. The reverse default fails open, which is what FR-014 forbids.

**Alternatives considered**: A single global `@media (prefers-reduced-motion: reduce) { * {
animation: none !important } }` kill-switch — rejected, it would also kill the busy spinner,
which FR-014 explicitly requires to survive.

---

## R4 — Demo navigation without a router

**Decision**: The three destinations (FR-018) are switched by React state in `demo/App.tsx`, not
by URL routing. The small-screen drawer (FR-019) is built from the already-installed
`@radix-ui/react-dialog`.

**Rationale**: FR-015 forbids new runtime dependencies, and there is no router in the project
today — adding `react-router` would violate it. FR-016 independently rules out routed
dashboards, so the two requirements agree. Radix Dialog already provides the focus trap, focus
restore, and Escape handling that FR-019 requires; hand-rolling a drawer would mean
reimplementing exactly the parts that are easy to omit and impossible to notice without a
screen reader.

**Alternatives considered**: `react-router` (rejected: violates FR-015); hash-based routing
hand-rolled (rejected: adds state-sync complexity for no requirement); a hand-built drawer
(rejected: loses Radix's accessibility wiring).

---

## R5 — Verifying contrast (SC-004)

**Decision**: Add a dependency-free Node script under `hydra-ui/scripts/` that parses the token
values out of `src/styles/index.css`, computes WCAG 2.1 relative luminance and contrast ratios
for every declared foreground/background pairing, and exits non-zero on any pair below its
threshold (4.5:1 body text, 3:1 large text and UI boundaries). Run it for both themes.

**Rationale**: SC-004 demands *every* pair be verified in both themes. No contrast tooling
exists in this repo today, and eyeballing 2 themes × ~12 colour pairs is precisely the kind of
check that silently rots. The WCAG formula is ~20 lines and needs no packages, so this satisfies
FR-015 while making the criterion genuinely testable rather than aspirational.

**Open detail for implementation**: the tokens are authored in `oklch()`. The script must
convert OKLCH → linear sRGB before computing luminance; it cannot read hex directly.

**Alternatives considered**: A dev-dependency contrast library (rejected: FR-015 is about
*runtime* deps so a devDependency would be permissible, but the conversion is small enough that
a dependency is not worth the supply-chain surface); manual spot-checking (rejected: not
repeatable, and SC-004 says "every" pair).

---

## R6 — The existing test suite does not currently pass (blocks SC-002)

**Decision**: Treat "record and repair the test baseline" as work item zero. SC-002 must be
re-anchored to a *measured* baseline rather than the assumed 100%.

**Finding**: Running `npx vitest run` on the current working tree, before any redesign work:

```
Test Files  12 failed | 3 passed (15)
     Tests  54 failed | 37 passed (91)
```

**Root cause**: The failures originate inside `node_modules/@mswjs/interceptors`, not in project
code:

```
TypeError: RequestInit: Expected signal ("AbortSignal {}") to be an instance of AbortSignal
  at recordRawHeaders (@mswjs/interceptors/src/.../recordRawHeaders.ts:207)
```

`@mswjs/interceptors@0.41.9` is incompatible with Node 24.19's undici. Every failure is a
downstream consequence: 11 direct `AbortSignal` type errors and 17 `network_error`s raised when
the broken interceptor makes `fetch` reject. The three files that pass
(`normalize-error`, `order-transitions`, `useLogin`) are the ones least dependent on the
interceptor. `src/lib/session-manager.ts` is **unmodified** in the working tree yet all of its
tests fail, which confirms the breakage is environmental rather than caused by the in-flight
003 changes.

**Why this matters to this feature**: SC-002 states "100% of existing automated tests pass after
the redesign, with no changes to test logic". As written it is unsatisfiable — they do not pass
*before* the redesign either. Without fixing this, the redesign has no regression net at all:
FR-012's whole guarantee (roles, labels, visible text preserved) is enforced by these tests, and
right now 59% of them cannot report.

**Precise mechanism** (measured 2026-08-14, not inferred):

- Source code creates `new AbortController()` — in `HydraProvider.tsx`, `useOrders.ts`, and
  `useOrder.ts` — and passes `controller.signal` to `fetch`.
- `vitest.config.ts` sets `environment: "jsdom"`. jsdom supplies its own
  `AbortController`/`AbortSignal`, but jsdom has **no** `fetch`, so `globalThis.fetch` remains
  Node's undici.
- msw's interceptor reconstructs the Request and undici checks
  `signal instanceof AbortSignal` against **Node's** class. A jsdom signal fails that check.

So it is a **realm mismatch between jsdom's AbortSignal and Node's fetch**, not a version skew.

**Two hypotheses tested and their results:**

| Experiment | Result |
|---|---|
| Override `@mswjs/interceptors` 0.41.9 → 0.42.3 (latest; `msw@2.15.0` is already latest) | **Rejected the version hypothesis** — got *worse*: 59 failed / 32 passed, same error, same file. Change was reverted. |
| Run `tests/unit/session-manager.test.ts` under `--environment node` instead of jsdom, no other change | **Confirmed the realm hypothesis** — 4 failed under jsdom, **4 passed under node**. |

**Correction to the mechanism** (the first description above was directionally right but
imprecise). The mismatch is *not* observable as an `instanceof` failure from inside a test. A
probe run in the jsdom environment showed:

```
ac.signal instanceof AbortSignal              -> true
new Request(url).signal.constructor === ac.signal.constructor -> true
new Request(url, { signal: ac.signal })       -> THROWS
```

Everything visible to test code agrees. What disagrees is undici's **module-scope reference** to
`AbortSignal`, captured when undici was evaluated — before jsdom overwrote the global. So the
check fails against a class the test can no longer name. This is why the bug looks impossible
from the test's point of view, and why msw is a bystander: msw is merely the first code to
construct a `Request`.

**Resolution applied**: a custom Vitest environment,
`hydra-ui/tests/env-jsdom-node-abort.ts`, which delegates to the built-in jsdom environment and
then restores Node's `AbortController`/`AbortSignal` onto the test global. The two constructors
are captured at the environment module's top level, which evaluates in the Node realm *before*
jsdom installs its globals — that ordering is the entire mechanism. `vitest.config.ts` points
`environment` at that file (Vitest resolves an environment name beginning with `.` or `/` as a
path). No dependency added, no `src/` change.

**Result**: `54 failed / 37 passed` → **`3 failed / 88 passed`**.

### The 3 residual failures are not ours

Attribution was established by re-running the suite against `git archive HEAD` with only the
environment fix applied:

| Codebase under test | Failures |
|---|---|
| Working tree, before the fix | 54 |
| Working tree + fix | 3 |
| **HEAD (committed) + fix** | **2** |

- `useLogout > ignores an in-flight refresh that resolves after sign-out` — **pre-existing on
  committed code.** `clear()` aborts the in-flight refresh; `requestRefresh` catches the
  `AbortError` and rethrows it as `networkError`, so the promise rejects where the test expects
  it to be ignored. Arguably a real defect in `src/lib/session-manager.ts`, which the msw
  breakage was masking.
- `LoginForm > never reveals which credential was wrong` — **pre-existing on committed code.**
  Message copy disagreement: `'invalid credentials'` vs the expected `'username or password'`.
- `credential-validation > LoginForm rejects an over-long password` — **introduced by the
  in-flight 003 tenant-resolution work**, not present at HEAD. `LoginForm` became tenant-gated,
  so the test's synchronous `getByLabelText("Username")` now runs before the field exists.

All three sit in `src/lib/`, `src/hooks/`, or message copy — areas this feature is contractually
forbidden to touch (contracts/public-surface.md §1–2, FR-011/FR-012). They are therefore
reported, not fixed, and SC-002 is re-anchored to the measured 88 rather than an assumed 91.

**Alternatives considered**: Proceeding and comparing "failures before vs. after" (rejected: a
54-failure baseline hides new regressions in the noise, and FR-012 is the requirement most
likely to be violated silently by markup restructuring).

---

## R7 — Typography

**Decision**: Override `--font-sans` in `@theme` with a system stack
(`ui-sans-serif, system-ui, -apple-system, "Segoe UI", Roboto, "Helvetica Neue", Arial,
sans-serif`) and introduce a type scale via existing `--text-*` utilities. No web font.

**Rationale**: FR-015 forbids it, and the reasoning holds independently: `@hydra/ui` is a
published library, and a library cannot ship `@font-face` without dictating network behaviour
and layout-shift characteristics to every host application.

---

## R8 — What the redesign must not disturb

**Decision**: Restyling is free to restructure markup, because **no test asserts a class name or
inline style**.

**Rationale**: Verified by grepping `tests/` and `stories/` for `toHaveClass`, `toHaveStyle`,
`classList`, and `.className` — zero matches. Queries are overwhelmingly `*ByRole` (32),
`*ByLabelText` (18), and `*ByText` (22); the only 6 `getByTestId` calls target fixtures defined
inside `tests/` itself, never library source (`src/` contains zero `data-testid` attributes).

**Consequence**: FR-012's constraint is exactly the right one and is the *only* one that binds —
preserve roles, accessible labels, and visible copy, and the suite (once R6 is resolved) will
confirm the redesign broke nothing.

---

## Resolved unknowns

| Unknown | Resolution |
|---|---|
| Can elevation/easing be real Tailwind tokens? | Yes — `--shadow-*`, `--ease-*` verified as `@theme` namespaces (R1) |
| Will shadows read in dark mode? | No — pair every level with a surface tint (R2) |
| How to honour reduced motion? | `motion-safe:` opt-in variants, verified present (R3) |
| How to navigate without a router? | React state + Radix Dialog drawer (R4) |
| How to verify contrast? | Dependency-free OKLCH→sRGB WCAG script (R5) |
| Is the test suite a usable safety net? | **Not currently** — must be repaired first (R6) |
| Does any test couple to styling? | No — zero class/style assertions (R8) |
