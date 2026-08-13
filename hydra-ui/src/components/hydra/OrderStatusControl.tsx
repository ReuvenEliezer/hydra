import { useState } from "react";
import { useUpdateOrderStatus } from "../../hooks/useUpdateOrderStatus";
import { cn } from "../../lib/cn";
import { allowedTransitions } from "../../lib/order-transitions";
import type { Order, OrderStatus } from "../../types/order";
import { Button } from "../ui/Button";
import { Select, type SelectOption } from "../ui/Select";
import { RequireRole } from "./RequireRole";
import { ORDER_STATUS_LABELS } from "./OrderStatusBadge";

export interface OrderStatusControlProps {
  order: Order;
  className?: string;
  onUpdated?: (order: Order) => void;
}

/**
 * Options come from `allowedTransitions(order.status)`, never from the full enum. An
 * invalid transition is therefore not something the user can pick and get a 422 for —
 * it is not offered at all (SC-007). Terminal statuses render a plain statement instead
 * of a disabled dropdown, because there is nothing to choose.
 *
 * Wrapped in `RequireRole("ROLE_ADMIN")` per FR-015: a standard user sees nothing here.
 */
export function OrderStatusControl({ order, className, onUpdated }: OrderStatusControlProps) {
  const { updateStatus, isPending, error } = useUpdateOrderStatus();
  const [selected, setSelected] = useState<OrderStatus | undefined>(undefined);

  const transitions = allowedTransitions(order.status);
  const options: SelectOption<OrderStatus>[] = transitions.map((status) => ({
    value: status,
    label: ORDER_STATUS_LABELS[status],
  }));

  async function handleApply(): Promise<void> {
    if (selected === undefined) return;
    try {
      const updated = await updateStatus(order.id, selected);
      setSelected(undefined);
      onUpdated?.(updated);
    } catch {
      // Rendered from the hook's `error`.
    }
  }

  return (
    <RequireRole role="ROLE_ADMIN">
      <div className={cn("flex flex-col gap-2", className)}>
        {transitions.length === 0 ? (
          <p className="text-content-muted text-sm">
            {ORDER_STATUS_LABELS[order.status]} orders can't change status.
          </p>
        ) : (
          <div className="flex items-end gap-2">
            <Select
              label="Change status to"
              value={selected}
              onValueChange={setSelected}
              options={options}
              placeholder="Choose a status…"
              disabled={isPending}
              className="w-44"
            />
            <Button
              size="sm"
              onClick={handleApply}
              disabled={selected === undefined}
              isPending={isPending}
            >
              Apply
            </Button>
          </div>
        )}

        {error !== null && (
          <p role="alert" data-error-code={error.code} className="text-danger text-sm">
            {error.message}
          </p>
        )}
      </div>
    </RequireRole>
  );
}
