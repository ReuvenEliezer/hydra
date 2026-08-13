import { useCallback, useEffect, useState } from "react";
import { useOrdersClient } from "../components/HydraProvider";
import { ApiError } from "../types/errors";
import { normalizeOrder, type Order } from "../types/order";

export interface UseOrderResult {
  order: Order | null;
  isLoading: boolean;
  /** `code === "not_found"` is the distinct case for an id that does not exist. */
  error: ApiError | null;
  refetch: () => void;
}

/**
 * Wraps `GET /api/orders/{id}` (FR-012).
 *
 * The backend scopes the lookup by tenant, so an order belonging to another tenant
 * comes back as 404 rather than 403 — from the client's point of view it simply does
 * not exist, which is the correct thing to show.
 */
export function useOrder(orderId: string | null): UseOrderResult {
  const client = useOrdersClient();
  const [order, setOrder] = useState<Order | null>(null);
  const [isLoading, setIsLoading] = useState(orderId !== null);
  const [error, setError] = useState<ApiError | null>(null);
  const [reloadToken, setReloadToken] = useState(0);

  useEffect(() => {
    if (orderId === null) {
      setOrder(null);
      setIsLoading(false);
      setError(null);
      return;
    }

    const controller = new AbortController();
    setIsLoading(true);
    setError(null);

    client
      .request<unknown>(`/api/orders/${orderId}`, { signal: controller.signal })
      .then((body) => {
        if (controller.signal.aborted) return;
        setOrder(normalizeOrder(body));
      })
      .catch((caught: unknown) => {
        if (controller.signal.aborted) return;
        setError(caught instanceof ApiError ? caught : null);
        setOrder(null);
      })
      .finally(() => {
        if (!controller.signal.aborted) setIsLoading(false);
      });

    return () => controller.abort();
  }, [client, orderId, reloadToken]);

  const refetch = useCallback(() => setReloadToken((token) => token + 1), []);

  return { order, isLoading, error, refetch };
}
