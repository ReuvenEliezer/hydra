import { useCallback, useSyncExternalStore } from "react";
import { useHydraContext } from "../components/HydraProvider";
import { roleSatisfies, type Role, type SessionStatus, type SessionUser } from "../types/session";

export interface UseSessionResult {
  status: SessionStatus;
  user: SessionUser | null;
  /**
   * UI affordance only — the backend's `@PreAuthorize` is the real gate. Respects the
   * role hierarchy: an admin satisfies `hasRole("ROLE_USER")`.
   */
  hasRole: (role: Role) => boolean;
  /** True while a session is being established or transparently renewed. */
  isPending: boolean;
}

/**
 * Read-only view of session state. Re-renders on every transition, including the
 * `authenticated → refreshing → authenticated` round trip a silent renewal produces.
 *
 * `useSyncExternalStore` rather than `useState` + an effect: the session manager is the
 * source of truth and lives outside React, and this is the API that gets tearing right
 * when several components read it during the same render pass.
 */
export function useSession(): UseSessionResult {
  const { sessionManager } = useHydraContext();

  const state = useSyncExternalStore(
    sessionManager.subscribe,
    sessionManager.getState,
    sessionManager.getState,
  );

  const hasRole = useCallback(
    (role: Role) => (state.user === null ? false : roleSatisfies(state.user.roles, role)),
    [state.user],
  );

  return {
    status: state.status,
    user: state.user,
    hasRole,
    isPending: state.status === "authenticating" || state.status === "refreshing",
  };
}
