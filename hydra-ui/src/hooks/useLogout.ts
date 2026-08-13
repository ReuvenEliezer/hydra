import { useCallback, useState } from "react";
import { useHydraContext } from "../components/HydraProvider";

export interface UseLogoutResult {
  /** Always resolves. Local state is cleared even when the network call fails. */
  logout: () => Promise<void>;
  isPending: boolean;
}

/**
 * Wraps `POST /api/v1/auth/logout`.
 *
 * Local state is cleared FIRST, before awaiting the server. That ordering is the whole
 * guarantee of FR-007: from the moment the user clicks, the access token is gone and
 * any refresh already in flight is invalidated, so nothing can issue a request on their
 * behalf afterwards — regardless of how long the server takes or whether it answers at
 * all. A failed logout call still leaves the browser signed out locally; the refresh
 * cookie's server-side record is the only thing left, and it expires on its own.
 */
export function useLogout(): UseLogoutResult {
  const { httpClient, sessionManager } = useHydraContext();
  const [isPending, setIsPending] = useState(false);

  const logout = useCallback(async () => {
    setIsPending(true);
    sessionManager.clear("anonymous");
    try {
      await httpClient.request<void>("/api/v1/auth/logout", {
        method: "POST",
        // A 401 here must not trigger a refresh — that would be the package re-creating
        // the very session the user just ended.
        authenticated: false,
      });
    } catch {
      // Network failure on sign-out is not actionable for the user: they are already
      // signed out locally, which is the part that matters.
    } finally {
      setIsPending(false);
    }
  }, [httpClient, sessionManager]);

  return { logout, isPending };
}
