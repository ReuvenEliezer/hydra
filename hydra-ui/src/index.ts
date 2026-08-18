/**
 * Public surface of `@hydra/ui`.
 *
 * Hooks are the primary interface (FR-022): every domain component below is a thin
 * wrapper over one of them, so an app that needs a different UI can drop to the hook
 * rather than fork the component.
 *
 * The stylesheet is NOT imported here. Doing so would make every consumer pay for it
 * whether or not they use the components, and would break tree-shaking; apps import
 * `@hydra/ui/styles.css` themselves.
 */

// Provider
export { HydraProvider, useHydraContext, useOrdersClient } from "./components/HydraProvider";
export type { HydraProviderProps, HydraContextValue } from "./components/HydraProvider";

// Session hooks
export { useSession } from "./hooks/useSession";
export type { UseSessionResult } from "./hooks/useSession";
export { useLogin } from "./hooks/useLogin";
export type { UseLoginResult } from "./hooks/useLogin";
export { useLogout } from "./hooks/useLogout";
export type { UseLogoutResult } from "./hooks/useLogout";
export { useTenant } from "./hooks/useTenant";
export type { TenantState, TenantStatus } from "./hooks/useTenant";

// Order hooks
export { useOrders } from "./hooks/useOrders";
export type { UseOrdersResult, UseOrdersFilters } from "./hooks/useOrders";
export { useOrder } from "./hooks/useOrder";
export type { UseOrderResult } from "./hooks/useOrder";
export { useCreateOrder, validateCreateOrder, hasCreateOrderErrors } from "./hooks/useCreateOrder";
export type { UseCreateOrderResult, CreateOrderFieldErrors } from "./hooks/useCreateOrder";
export { useUpdateOrderStatus } from "./hooks/useUpdateOrderStatus";
export type { UseUpdateOrderStatusResult } from "./hooks/useUpdateOrderStatus";
export { useCancelOrder } from "./hooks/useCancelOrder";
export type { UseCancelOrderResult } from "./hooks/useCancelOrder";

// Provisioning hooks
export { useRegisterUser } from "./hooks/useRegisterUser";
export type { UseRegisterUserResult } from "./hooks/useRegisterUser";
export { useRegisterAdmin } from "./hooks/useRegisterAdmin";
export type { UseRegisterAdminResult } from "./hooks/useRegisterAdmin";

// Domain components
export { LoginForm } from "./components/hydra/LoginForm";
export type { LoginFormProps } from "./components/hydra/LoginForm";
export { SessionGate } from "./components/hydra/SessionGate";
export type { SessionGateProps } from "./components/hydra/SessionGate";
export { RequireRole } from "./components/hydra/RequireRole";
export type { RequireRoleProps } from "./components/hydra/RequireRole";
export { OrderList } from "./components/hydra/OrderList";
export type { OrderListProps } from "./components/hydra/OrderList";
export { OrderDetail } from "./components/hydra/OrderDetail";
export type { OrderDetailProps } from "./components/hydra/OrderDetail";
export { CreateOrderForm } from "./components/hydra/CreateOrderForm";
export type { CreateOrderFormProps } from "./components/hydra/CreateOrderForm";
export { OrderStatusControl } from "./components/hydra/OrderStatusControl";
export type { OrderStatusControlProps } from "./components/hydra/OrderStatusControl";
export { CancelOrderButton } from "./components/hydra/CancelOrderButton";
export type { CancelOrderButtonProps } from "./components/hydra/CancelOrderButton";
export { RegisterUserForm } from "./components/hydra/RegisterUserForm";
export type { RegisterUserFormProps } from "./components/hydra/RegisterUserForm";
export { RegisterAdminForm } from "./components/hydra/RegisterAdminForm";
export type { RegisterAdminFormProps } from "./components/hydra/RegisterAdminForm";
export { OrderStatusBadge, ORDER_STATUS_LABELS } from "./components/hydra/OrderStatusBadge";
export type { OrderStatusBadgeProps } from "./components/hydra/OrderStatusBadge";

// UI primitives — exported so consuming apps can compose their own domain components
// in the same visual language instead of reimplementing them.
export { Button } from "./components/ui/Button";
export type { ButtonProps, ButtonVariant, ButtonSize } from "./components/ui/Button";
export { Input } from "./components/ui/Input";
export type { InputProps } from "./components/ui/Input";
export { Card } from "./components/ui/Card";
export type { CardProps } from "./components/ui/Card";
export { Dialog, DialogClose } from "./components/ui/Dialog";
export type { DialogProps } from "./components/ui/Dialog";
export { Select } from "./components/ui/Select";
export type { SelectProps, SelectOption } from "./components/ui/Select";
export { Table } from "./components/ui/Table";
export type { TableProps, TableColumn } from "./components/ui/Table";

// Helpers
export { cn } from "./lib/cn";
export { allowedTransitions, isTerminalStatus, canCancel } from "./lib/order-transitions";
export {
  validateCredentials,
  validateUsername,
  validatePassword,
  hasCredentialErrors,
  USERNAME_MIN_LENGTH,
  USERNAME_MAX_LENGTH,
  PASSWORD_MIN_LENGTH,
  PASSWORD_MAX_LENGTH,
} from "./lib/credential-validation";
export type { CredentialErrors } from "./lib/credential-validation";

// Types
export { ApiError, isApiError, isValidationError, isPermissionError, isBusinessRuleError, isRateLimitError, isSessionDeadError } from "./types/errors";
export type {
  ApiErrorCode,
  AuthError,
  ValidationError,
  PermissionError,
  BusinessRuleError,
  RateLimitError,
} from "./types/errors";
export type { Role, SessionStatus, SessionState, SessionUser } from "./types/session";
export { ORDER_STATUSES } from "./types/order";
export type { Order, OrderStatus, CreateOrderInput } from "./types/order";
export type { Page, PageMeta } from "./types/page";
export type { Account, RegisterInput, RegistrationOutcome } from "./types/account";
