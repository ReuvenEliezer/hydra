import type { ReactNode } from "react";
import { useSession } from "../../hooks/useSession";
import type { Role } from "../../types/session";

export interface RequireRoleProps {
  role: Role;
  children: ReactNode;
  /** Rendered when the role is not held. Defaults to nothing at all. */
  fallback?: ReactNode;
}

/**
 * Renders `children` only when the session holds at least `role`.
 *
 * This is the mechanism behind FR-015 and FR-018, and it is a UI affordance, not a
 * security control: the roles come from an unverified client-side decode of the access
 * token, and the actual gate is the backend's `@PreAuthorize`. Hiding a control that
 * would 403 is a courtesy to the user; a tampered token buys nothing but a button that
 * fails.
 */
export function RequireRole({ role, children, fallback = null }: RequireRoleProps) {
  const { hasRole } = useSession();
  return <>{hasRole(role) ? children : fallback}</>;
}
