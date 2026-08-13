import { useCallback, useState } from "react";
import { useOrdersClient } from "../components/HydraProvider";
import { ApiError } from "../types/errors";
import { normalizeOrder, type Order, type OrderStatus } from "../types/order";

export interface UseUpdateOrderStatusResult {
  updateStatus: (orderId: string, status: OrderStatus) => Promise<Order>;
  isPending: boolean;
  error: ApiError | null;
  reset: () => void;
}

/**
 * Wraps `PATCH /api/orders/{id}/status` (FR-013, FR-015).
 *
 * Two different rejections are possible and they are NOT the same thing:
 *   - 403 `permission_denied` — the caller is not an admin.
 *   - 422 `business_rule_violation` — the caller may change statuses, but not to that
 *     one from this one (`validateStatusTransition`).
 *
 * Callers should drive their control from `allowedTransitions(order.status)` so the
 * second case is unreachable through the UI; it stays handled because a stale page can
 * still submit a transition that was valid when it rendered.
 */
export function useUpdateOrderStatus(): UseUpdateOrderStatusResult {
  const client = useOrdersClient();
  const [isPending, setIsPending] = useState(false);
  const [error, setError] = useState<ApiError | null>(null);

  const updateStatus = useCallback(
    async (orderId: string, status: OrderStatus): Promise<Order> => {
      setIsPending(true);
      setError(null);
      try {
        const body = await client.request<unknown>(`/api/orders/${orderId}/status`, {
          method: "PATCH",
          body: { status },
        });
        return normalizeOrder(body);
      } catch (caught) {
        if (caught instanceof ApiError) setError(caught);
        throw caught;
      } finally {
        setIsPending(false);
      }
    },
    [client],
  );

  const reset = useCallback(() => setError(null), []);

  return { updateStatus, isPending, error, reset };
}
