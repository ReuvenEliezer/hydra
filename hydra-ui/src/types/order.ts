/** Mirrors `OrderStatus` in order-service exactly. */
export type OrderStatus = "PENDING" | "SHIPPED" | "DELIVERED" | "CANCELLED";

export const ORDER_STATUSES: readonly OrderStatus[] = [
  "PENDING",
  "SHIPPED",
  "DELIVERED",
  "CANCELLED",
];

/**
 * Mirrors `OrderResponse` field for field.
 *
 * `totalAmount` is a `string` here even though the backend serializes the `BigDecimal`
 * as a JSON number: money that round-trips through a JS `number` is money that can pick
 * up float artefacts on the way to a form field. The wire value is captured as text at
 * the boundary (`normalizeOrder`) and never re-parsed for display.
 *
 * `createdAt`/`updatedAt` are `LocalDateTime` server-side, so they arrive as ISO-8601
 * WITHOUT a timezone offset (e.g. "2026-08-13T09:15:00"). Treat them as server-local
 * wall-clock time; do not assume UTC.
 */
export interface Order {
  id: string;
  tenantId: string;
  orderNumber: string;
  totalAmount: string;
  status: OrderStatus;
  createdBy: string;
  createdAt: string;
  updatedAt: string;
}

export interface CreateOrderInput {
  orderNumber: string;
  totalAmount: string;
}

function asString(value: unknown): string {
  return typeof value === "string" ? value : String(value ?? "");
}

/** Converts one raw `OrderResponse` body into an `Order`. */
export function normalizeOrder(raw: unknown): Order {
  const body = (raw ?? {}) as Record<string, unknown>;
  return {
    id: asString(body["id"]),
    tenantId: asString(body["tenantId"]),
    orderNumber: asString(body["orderNumber"]),
    totalAmount: asString(body["totalAmount"]),
    status: body["status"] as OrderStatus,
    createdBy: asString(body["createdBy"]),
    createdAt: asString(body["createdAt"]),
    updatedAt: asString(body["updatedAt"]),
  };
}
