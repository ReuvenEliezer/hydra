# Contract: `@hydra/ui` Public Surface

**Feature**: 004-hydra-ui-redesign | **Date**: 2026-08-14

`@hydra/ui` is a published library, so its contract is what consuming applications may rely on.
This redesign is a **visual change only**: everything below is frozen. Any diff that alters an
item in the "Frozen" sections is a breaking change and out of scope for this feature.

---

## 1. Frozen — TypeScript surface (FR-011)

No exported type, prop, or event signature changes. The full export list in
`hydra-ui/src/index.ts` stays byte-identical in shape:

- **Provider**: `HydraProvider`, `useHydraContext`, `useOrdersClient`
- **Session hooks**: `useSession`, `useLogin`, `useLogout`, `useTenant`
- **Order hooks**: `useOrders`, `useOrder`, `useCreateOrder`, `useUpdateOrderStatus`,
  `useCancelOrder`
- **Provisioning hooks**: `useRegisterUser`, `useRegisterAdmin`
- **Domain components**: `LoginForm`, `SessionGate`, `RequireRole`, `OrderList`, `OrderDetail`,
  `CreateOrderForm`, `OrderStatusControl`, `CancelOrderButton`, `RegisterUserForm`,
  `RegisterAdminForm`, `OrderStatusBadge`
- **UI primitives**: `Button`, `Input`, `Card`, `Dialog`, `Select`, `Table`
- **Helpers**: `cn`, `allowedTransitions`, `isTerminalStatus`, `canCancel`, credential-validation
  exports, `ORDER_STATUS_LABELS`, `ORDER_STATUSES`
- **Types**: all error, session, order, page, and account types

Verification: `npm run typecheck` passes, and no line of `src/index.ts` is modified.

---

## 2. Frozen — Accessible query surface (FR-012)

This is the contract the test suite actually depends on. Verified: **no test asserts a class
name or inline style** (research.md R8), so markup may be restructured *only* while all three
of the following hold.

### 2a. Roles

Every interactive element keeps its current implicit or explicit ARIA role. Notably:

| Element | Role that must persist |
|---|---|
| All buttons (`Button`, `CancelOrderButton`, form submits) | `button` |
| `Input` | `textbox` |
| `Select` trigger | `combobox` |
| `Dialog` | `dialog`, modal, with title and description wired |
| `Table` | `table` / `row` / `columnheader` / `cell` |
| Headings in `Card`, `Dialog`, forms | `heading` |

### 2b. Accessible labels

Every form control keeps its current accessible name, supplied via `<label htmlFor>` (Input) or
`aria-labelledby` (Select). Existing wiring that must survive:

- `Input` — `aria-invalid` when `error` is set; `aria-describedby` pointing at the hint and/or
  error node.
- `Button` — `aria-busy` while `isPending`.
- `Select` — trigger labelled by the visible (or `sr-only`) label span.
- `Dialog` — Radix `Title` and `Description` remain present and non-empty.

### 2c. Visible copy

User-visible strings asserted by tests must not be reworded. This includes button text, form
labels, headings, the four order-status labels (`Pending`, `Shipped`, `Delivered`, `Cancelled`),
and all error messages produced by `normalize-error.ts` / `credential-validation.ts`.

> Copy improvements are **out of scope** for this feature precisely because they are
> indistinguishable from regressions to the test suite.

---

## 3. Frozen — Theming contract (FR-007)

The three-state mechanism is public behaviour and is preserved exactly:

1. No opinion from the host app → follows `prefers-color-scheme`.
2. Host sets `data-theme="light"` on `<html>` → forces light regardless of OS.
3. Host sets `data-theme="dark"` on `<html>` → forces dark regardless of OS.

---

## 4. Changing — Token values (FR-001)

Token **names** are part of the contract and are preserved, so a consuming app that overrides
`--color-brand` or composes `bg-surface` through `className` keeps working. Token **values**
change, and new token names are added (see data-model.md).

**Consumer-visible consequence**: an app that hardcoded a colour to *match* the old blue accent
will now visually clash. This is expected and is the intended effect of the feature; it is
called out in the spec's Edge Cases.

---

## 5. Changing — Stylesheet entry point

`@hydra/ui/styles.css` remains the single stylesheet consumers import. It is still not imported
from `src/index.ts` — doing so would make every consumer pay for it and break tree-shaking.
This existing decision is preserved.

---

## 6. Additive — Showcase story (FR-017)

A new Storybook story renders every primitive in every variant and state on one surface. It is
a development artifact under `hydra-ui/stories/`; it is **not** exported from the package and
adds nothing to the public surface.

---

## 7. Non-contract — Demo application

`hydra-ui/demo/` is a reference application, not part of the published package (`files` in
`package.json` ships only `dist` and `README.md`). Its restructuring (FR-016, FR-018, FR-019)
is therefore unconstrained by this contract.
