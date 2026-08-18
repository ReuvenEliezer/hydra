import { useState } from "react";
import { AlertCircle } from "lucide-react";
import { useCancelOrder } from "../../hooks/useCancelOrder";
import { canCancel } from "../../lib/order-transitions";
import type { Order } from "../../types/order";
import { Button } from "../ui/Button";
import { Dialog } from "../ui/Dialog";
import { RequireRole } from "./RequireRole";

export interface CancelOrderButtonProps {
  order: Order;
  className?: string;
  /**
   * Called after a successful cancel. The endpoint answers 204 with no body, so there
   * is no updated order to hand back — the caller must refetch to show the new status.
   */
  onCancelled?: () => void;
}

/**
 * Confirm-then-cancel, wrapped in `RequireRole("ROLE_ADMIN")` per FR-015.
 *
 * Disabled for DELIVERED and already-CANCELLED orders, matching
 * `OrderService.cancelOrder`'s own two guards — those are the only two states the server
 * refuses, and it refuses them with a 422.
 */
export function CancelOrderButton({ order, className, onCancelled }: CancelOrderButtonProps) {
  const { cancelOrder, isPending, error } = useCancelOrder();
  const [isConfirmOpen, setIsConfirmOpen] = useState(false);

  const cancellable = canCancel(order.status);

  async function handleConfirm(): Promise<void> {
    try {
      await cancelOrder(order.id);
      setIsConfirmOpen(false);
      onCancelled?.();
    } catch {
      // Keeps the dialog open so the error stays next to the action that caused it.
    }
  }

  return (
    <RequireRole role="ROLE_ADMIN">
      <Button
        variant="danger"
        size="sm"
        className={className}
        disabled={!cancellable}
        onClick={() => setIsConfirmOpen(true)}
      >
        Cancel order
      </Button>

      <Dialog
        open={isConfirmOpen}
        onOpenChange={setIsConfirmOpen}
        title={`Cancel order ${order.orderNumber}?`}
        description="The order is kept on record with a cancelled status. This can't be undone."
        footer={
          <>
            <Button variant="secondary" onClick={() => setIsConfirmOpen(false)} disabled={isPending}>
              Keep order
            </Button>
            <Button variant="danger" onClick={handleConfirm} isPending={isPending}>
              {isPending ? "Cancelling…" : "Cancel order"}
            </Button>
          </>
        }
      >
        {error !== null && (
          <p
            role="alert"
            data-error-code={error.code}
            className="bg-danger-surface text-danger border-danger/30 flex items-start gap-2 rounded-(--radius-control) border px-3.5 py-3 text-sm font-medium"
          >
            <AlertCircle aria-hidden="true" className="mt-px size-4 shrink-0" />
            {error.message}
          </p>
        )}
      </Dialog>
    </RequireRole>
  );
}
