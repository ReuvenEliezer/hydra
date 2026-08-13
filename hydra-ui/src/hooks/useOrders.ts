import { useCallback, useEffect, useState } from "react";
import { useOrdersClient } from "../components/HydraProvider";
import { ApiError } from "../types/errors";
import { normalizeOrder, type Order, type OrderStatus } from "../types/order";
import { EMPTY_PAGE_META, normalizePage, type PageMeta } from "../types/page";

export interface UseOrdersFilters {
  status?: OrderStatus;
  size?: number;
}

export interface UseOrdersResult {
  orders: Order[];
  page: PageMeta;
  isLoading: boolean;
  error: ApiError | null;
  loadPage: (pageNumber: number) => void;
  refetch: () => void;
}

/**
 * Wraps `GET /api/orders`.
 *
 * `sort=createdAt,desc` is sent EXPLICITLY on every call. The controller's
 * `@PageableDefault(size = 20, sort = "createdAt")` sorts ASCENDING, so relying on the
 * default would quietly show the oldest orders first and violate FR-009 — a bug that
 * looks like nothing at all until someone has more than a page of orders.
 */
export function useOrders(filters: UseOrdersFilters = {}): UseOrdersResult {
  const client = useOrdersClient();
  const { status, size = 20 } = filters;

  const [orders, setOrders] = useState<Order[]>([]);
  const [page, setPage] = useState<PageMeta>(EMPTY_PAGE_META);
  const [pageNumber, setPageNumber] = useState(0);
  const [isLoading, setIsLoading] = useState(true);
  const [error, setError] = useState<ApiError | null>(null);
  const [reloadToken, setReloadToken] = useState(0);

  // A filter change must not leave the user paging through results that no longer
  // exist, so any change resets to the first page.
  useEffect(() => {
    setPageNumber(0);
  }, [status, size]);

  useEffect(() => {
    const controller = new AbortController();
    setIsLoading(true);
    setError(null);

    client
      .request<unknown>("/api/orders", {
        query: { page: pageNumber, size, sort: "createdAt,desc", status },
        signal: controller.signal,
      })
      .then((body) => {
        if (controller.signal.aborted) return;
        const normalized = normalizePage(body, normalizeOrder);
        setOrders(normalized.content);
        setPage(normalized.page);
      })
      .catch((caught: unknown) => {
        if (controller.signal.aborted) return;
        setError(caught instanceof ApiError ? caught : null);
        setOrders([]);
        setPage(EMPTY_PAGE_META);
      })
      .finally(() => {
        if (!controller.signal.aborted) setIsLoading(false);
      });

    return () => controller.abort();
  }, [client, pageNumber, size, status, reloadToken]);

  const loadPage = useCallback((next: number) => setPageNumber(Math.max(0, next)), []);
  const refetch = useCallback(() => setReloadToken((token) => token + 1), []);

  return { orders, page, isLoading, error, loadPage, refetch };
}
