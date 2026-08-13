import type { OrderStatus } from "../types/order";

/**
 * The single source of truth for which status changes the backend will accept.
 *
 * Mirrors `OrderService.validateStatusTransition` exactly:
 *
 *   PENDING   → SHIPPED | CANCELLED
 *   SHIPPED   → DELIVERED | CANCELLED
 *   DELIVERED → (terminal)
 *   CANCELLED → (terminal)
 *
 * Driving the status control from this instead of the full `OrderStatus` enum is what
 * makes an invalid transition unofferable rather than merely rejected (SC-007). If the
 * server-side rule ever changes, this function and the backend switch statement must
 * change together — a 422 on a control the UI offered is the symptom of them drifting.
 */
const TRANSITIONS: Record<OrderStatus, readonly OrderStatus[]> = {
  PENDING: ["SHIPPED", "CANCELLED"],
  SHIPPED: ["DELIVERED", "CANCELLED"],
  DELIVERED: [],
  CANCELLED: [],
};

export function allowedTransitions(current: OrderStatus): OrderStatus[] {
  return [...(TRANSITIONS[current] ?? [])];
}

/** True when no status change is possible, so the UI should render nothing actionable. */
export function isTerminalStatus(status: OrderStatus): boolean {
  return allowedTransitions(status).length === 0;
}

/**
 * `cancelOrder` has its own server-side rule that is NOT the transition table: it
 * rejects DELIVERED ("Cannot cancel a delivered order") and already-CANCELLED ("Order
 * is already cancelled") with a 422 and allows everything else.
 */
export function canCancel(status: OrderStatus): boolean {
  return status !== "DELIVERED" && status !== "CANCELLED";
}
