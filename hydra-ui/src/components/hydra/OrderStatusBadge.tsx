import { Check, Circle, Truck, X } from "lucide-react";
import type { ComponentType } from "react";
import { cn } from "../../lib/cn";
import type { OrderStatus } from "../../types/order";

const LABELS: Record<OrderStatus, string> = {
  PENDING: "Pending",
  SHIPPED: "Shipped",
  DELIVERED: "Delivered",
  CANCELLED: "Cancelled",
};

/**
 * A shape per status, so status is never carried by colour alone (FR-008). This matters
 * most in dark mode, where the four badge colours previously rendered as thin coloured
 * text on a near-black ground — the weakest contrast in the whole library.
 *
 * Decorative only: the visible label beside it is the accessible text, so these are
 * aria-hidden rather than labelled.
 */
const GLYPHS: Record<OrderStatus, ComponentType<{ className?: string }>> = {
  PENDING: Circle,
  SHIPPED: Truck,
  DELIVERED: Check,
  CANCELLED: X,
};

export interface OrderStatusBadgeProps {
  status: OrderStatus;
  className?: string;
}

export function OrderStatusBadge({ status, className }: OrderStatusBadgeProps) {
  const Glyph = GLYPHS[status];

  return (
    <span
      className={cn(
        "inline-flex items-center gap-1.5 rounded-full border px-2.5 py-1 text-xs font-semibold",
        `hydra-status-${status}`,
        className,
      )}
    >
      {Glyph !== undefined && <Glyph aria-hidden="true" className="size-3.5 shrink-0" />}
      {LABELS[status] ?? status}
    </span>
  );
}

export { LABELS as ORDER_STATUS_LABELS };
