# Contract: Public Components API

Domain components (`src/components/hydra/`) are thin, styleable wrappers around the hooks in `hooks.md` — they own no logic the hooks don't already expose, so a consuming app can always drop to the hooks directly for a custom UI (FR-022).

| Component | Backing hook(s) | Renders |
|---|---|---|
| `LoginForm` | `useLogin` | Username/password fields, submit button, inline error per `AuthError.code`. |
| `SessionGate` | `useSession` | Renders `children` only when `status === "authenticated"`; otherwise renders its `fallback` prop (typically `LoginForm`). Handles the "silent renewal in progress" case by rendering children through a `"refreshing"` status without flicker (SC-001). |
| `RequireRole` | `useSession().hasRole` | Renders `children` only if the current user meets the given `role`; otherwise renders `fallback` (default: nothing) — the mechanism `OrderStatusControl`/`RegisterAdminForm` use internally to satisfy FR-015/FR-018. |
| `OrderList` | `useOrders` | Paginated table with a status filter control. |
| `OrderDetail` | `useOrder` | Full single-order view. |
| `CreateOrderForm` | `useCreateOrder` | Order number + amount fields, client + server validation errors. |
| `OrderStatusControl` | `useUpdateOrderStatus`, wrapped in `RequireRole("ROLE_ADMIN")` | Status dropdown populated from `allowedTransitions(order.status)` — never the full enum, so an invalid transition cannot be selected (FR-013, SC-007). Renders nothing actionable for terminal statuses (Delivered/Cancelled). Hidden entirely for non-admins per FR-015. |
| `CancelOrderButton` | `useCancelOrder`, wrapped in `RequireRole("ROLE_ADMIN")` | Confirm-then-cancel action; disabled when the order is already Delivered or Cancelled. Refetches after success since the cancel response carries no body. Hidden entirely for non-admins. |
| `RegisterUserForm` | `useRegisterUser`, wrapped in `RequireRole("ROLE_ADMIN")` | Username/password fields for new standard users. |
| `RegisterAdminForm` | `useRegisterAdmin`, wrapped in `RequireRole("ROLE_SUPER_ADMIN")` | Tenant + username/password fields; hidden entirely for non-super-admins per FR-018. |

Primitive components (`src/components/ui/`) — `Button`, `Input`, `Card`, `Dialog`, `Select`, `Table`, `Toast` — are unstyled-Radix-plus-Tailwind building blocks with no HYDRA-specific logic; every domain component above is composed from these.

All components accept a `className` prop (merged via `cn`) so consuming apps can restyle without forking.

Every form component surfaces its error state from the normalized `ApiError` code, so a business-rule rejection (duplicate order number, invalid transition) reads as its own specific message rather than a generic failure (FR-023).
