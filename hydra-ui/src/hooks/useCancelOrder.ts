import { useCallback, useState } from "react";
import { useOrdersClient } from "../components/HydraProvider";
import { ApiError } from "../types/errors";

export interface UseCancelOrderResult {
  /** Resolves void — the endpoint answers 204 with no body. */
  cancelOrder: (orderId: string) => Promise<void>;
  isPending: boolean;
  error: ApiError | null;
  reset: () => void;
}

/**
 * Wraps `DELETE /api/orders/{id}` (FR-014, FR-015).
 *
 * Despite the verb this is a SOFT cancel: `OrderService.cancelOrder` sets the status to
 * `CANCELLED` and keeps the record. The response is 204 with no body, so there is no
 * updated order to return — callers must refetch to show the new status.
 *
 * Cancelling a DELIVERED or already-CANCELLED order is a 422, not a 404 or a silent
 * success.
 */
export function useCancelOrder(): UseCancelOrderResult {
  const client = useOrdersClient();
  const [isPending, setIsPending] = useState(false);
  const [error, setError] = useState<ApiError | null>(null);

  const cancelOrder = useCallback(
    async (orderId: string): Promise<void> => {
      setIsPending(true);
      setError(null);
      try {
        await client.request<void>(`/api/orders/${orderId}`, { method: "DELETE" });
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

  return { cancelOrder, isPending, error, reset };
}
