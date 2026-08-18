import { useHydraContext } from "../components/HydraProvider";
import type { ApiError } from "../types/errors";

/**
 * The five states a sign-in page can be in with respect to its own address.
 *
 * Three come from the server (`recognized` / `inactive` / `unknown`); `resolving` covers the
 * gap between mount and response; `error` covers the lookup itself failing.
 *
 * `error` is deliberately NOT folded into `unknown`. They call for opposite actions from the
 * person reading them — "check the address you typed" versus "try again in a moment" — and
 * reporting a transient outage as an unrecognized address sends users chasing a problem that
 * does not exist. `resolving` is likewise never rendered as a failure.
 */
export type TenantStatus = "resolving" | "recognized" | "inactive" | "unknown" | "error";

export interface TenantState {
  status: TenantStatus;
  /** The organization's name. Present only when `status === "recognized"`. */
  displayName: string | null;
  /** Present only when `status === "error"` — the lookup itself failed. */
  error: ApiError | null;
}

/**
 * Reads the one load-time tenant resolution performed by `HydraProvider`.
 *
 * Read-only, and it never returns a tenant identifier: the response it reflects has no field
 * that could carry one, which is what keeps the browser unable to name a tenant at all.
 */
export function useTenant(): TenantState {
  return useHydraContext().tenant;
}
