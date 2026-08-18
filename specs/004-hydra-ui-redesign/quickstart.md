# Quickstart: Validating the Hydra UI Redesign

**Feature**: 004-hydra-ui-redesign | **Date**: 2026-08-14

How to prove the redesign works. Each section maps to success criteria in
[spec.md](./spec.md).

---

## 0. Prerequisites

**Node is not on the default shell PATH.** It is installed under JetBrains. Export it first, or
every command below fails with `command not found`:

```bash
export PATH="/Users/reuven/Library/Application Support/JetBrains/IntelliJIdea2026.2/node/versions/24.19.0/bin:$PATH"
```

Then, from `hydra-ui/`:

```bash
npm install
```

Storybook may already be running on port 6006 outside your session — check before starting a
second one:

```bash
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:6006
```

---

## 1. Test baseline — do this first (SC-002)

> **Blocking.** The suite does not currently pass. Before any styling work, establish that it
> can. See research.md R6.

```bash
npx vitest run
```

**Expected before the prerequisite fix** (measured 2026-08-14): `12 failed | 3 passed` files,
`54 failed | 37 passed` tests, all traceable to
`@mswjs/interceptors@0.41.9` rejecting Node 24's `AbortSignal`.

**Required after the prerequisite fix**: all files pass. Only then does the suite function as
the regression net that FR-012 depends on.

**Expected at feature completion**: still all passing, with **no changes to test logic**. Since
no test asserts a class name (research.md R8), a passing suite means roles, labels, and visible
copy survived the restyle.

---

## 2. Type and lint gates (FR-011)

```bash
npm run typecheck
npm run lint
```

Both must pass. `typecheck` failing means an exported prop or type changed, which FR-011
forbids. Also confirm the public surface is untouched:

```bash
git diff --stat src/index.ts
```

Expected: no output.

---

## 3. Component review surface (FR-017, SC-003)

```bash
npm run storybook
```

Open the primitives showcase story. Confirm on one screen:

- **Buttons** — all four variants, both sizes, and rest / hover / focus / disabled / busy.
  Disabled and busy must be **visibly different** (FR-004); today they are both 50% opacity.
- **Status badges** — all four, each with its non-colour marker (FR-008).
- **Inputs** — default, with hint, with error, disabled.
- **Select, Card, Table** (populated *and* empty), **Dialog**.

Then check the browser console: zero errors (SC-003).

**Both themes.** Toggle `data-theme` on `<html>` between `"light"` and `"dark"`, and also test
with it absent so `prefers-color-scheme` drives (FR-007 — three states, not two).

---

## 4. Contrast (SC-004)

```bash
node scripts/check-contrast.mjs
```

Exits non-zero and names any pair below threshold: 4.5:1 body text, 3:1 large text and UI
boundaries, checked for both themes. Note the tokens are authored in `oklch()`, so the script
converts OKLCH → linear sRGB before computing luminance (research.md R5).

---

## 5. Keyboard and focus (SC-005)

With the demo running (`npm run demo`), traverse each screen using **only** `Tab` /
`Shift+Tab` / `Enter` / `Escape`:

- Every interactive element shows a clearly visible focus indicator.
- The Dialog traps focus, closes on `Escape`, and returns focus to its trigger.
- The Select is fully operable from the keyboard.

---

## 6. Reduced motion (SC-006)

Enable the OS setting (macOS: System Settings → Accessibility → Display → Reduce motion), then
reload the demo.

- No movement-based animation plays anywhere.
- **The busy indicator is still visible** during login and order actions. This is the check that
  matters — removing progress feedback is the wrong reading of the preference and is explicitly
  forbidden by FR-014.
- Interactive state changes still occur, instantly.

---

## 7. Small screens (SC-007, FR-019)

Set the viewport to **375px** wide and walk every demo screen:

- No horizontal **page** scrolling anywhere. Wide content such as the order table scrolls inside
  its own container instead.
- Navigation has collapsed to a drawer, opened from a header control.
- All three destinations remain reachable — **using the keyboard alone**.
- The drawer closes on `Escape` and returns focus to the control that opened it.

---

## 8. Full demo walkthrough (FR-009, FR-016, FR-018)

```bash
npm run demo
```

Serve from a tenant address — `http://acme.localhost:5173`, not `http://localhost:5173`. The
tenant is derived from the current hostname; a bare `localhost` resolves to no tenant, every
lookup returns `unknown`, and login fails closed while the UI looks perfectly fine.

Requires `auth-service` (8083) and `order-service` (8082) running.

Walk: sign in → orders list → order detail → create order → cancel order → team/registration
(as an admin). Confirm:

- One consistent visual language across every screen; no leftover pre-redesign styling.
- Navigation shows exactly **Orders**, **New order**, and **Team** — and nothing else. There is
  no "Users" or "Settings" screen in this codebase; if either appears, FR-018 has been violated.
- **Team** is hidden for non-admin sessions.
- Empty, loading, and error states are all deliberately styled (FR-005).

---

## 9. Sign-off (SC-001)

The subjective gate. Capture before/after screenshots of every exported component and every
demo screen, in **both** themes, and present them side by side for stakeholder approval.

The showcase story from §3 is what makes this practical — before it existed, the primitives had
no story at all and could not be screenshotted.
