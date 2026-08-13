import type { ReactNode } from "react";
import { useSession } from "../../hooks/useSession";

export interface SessionGateProps {
  children: ReactNode;
  /** Rendered when there is no session — typically a `<LoginForm />`. */
  fallback: ReactNode;
  /** Rendered only during the initial mount-time restore, before anything is known. */
  pending?: ReactNode;
}

/**
 * Renders `children` for an authenticated session and `fallback` otherwise.
 *
 * The `"refreshing"` case renders CHILDREN, not the fallback: a silent token renewal is
 * not a sign-out, and swapping to a login form for the length of one round trip is
 * exactly the flicker SC-001 forbids. Only `"authenticating"` — the initial restore,
 * where nothing is known yet — shows the pending state, and only if one was supplied.
 */
export function SessionGate({ children, fallback, pending }: SessionGateProps) {
  const { status } = useSession();

  if (status === "authenticated" || status === "refreshing") return <>{children}</>;
  if (status === "authenticating") return <>{pending ?? null}</>;
  return <>{fallback}</>;
}
