import { cn } from "../../lib/cn";
import type { OrderStatus } from "../../types/order";

const LABELS: Record<OrderStatus, string> = {
  PENDING: "Pending",
  SHIPPED: "Shipped",
  DELIVERED: "Delivered",
  CANCELLED: "Cancelled",
};

export interface OrderStatusBadgeProps {
  status: OrderStatus;
  className?: string;
}

export function OrderStatusBadge({ status, className }: OrderStatusBadgeProps) {
  return (
    <span
      className={cn(
        "inline-flex items-center rounded-full px-2 py-0.5 text-xs font-medium",
        `hydra-status-${status}`,
        className,
      )}
    >
      {LABELS[status] ?? status}
    </span>
  );
}

export { LABELS as ORDER_STATUS_LABELS };
