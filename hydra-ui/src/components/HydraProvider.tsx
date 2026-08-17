import {
  createContext,
  useContext,
  useEffect,
  useMemo,
  useRef,
  useState,
  type ReactNode,
} from "react";
import { createHttpClient, type HttpClient } from "../lib/http-client";
import { createSessionManager, type SessionManager } from "../lib/session-manager";
import { fetchTenantResolution } from "../lib/tenant-resolution";
import type { TenantState } from "../hooks/useTenant";
import { ApiError } from "../types/errors";

export interface HydraContextValue {
  sessionManager: SessionManager;
  httpClient: HttpClient;
  ordersBaseUrl: string;
  /** The load-time tenant resolution. Read it through `useTenant()`. */
  tenant: TenantState;
}

const HydraContext = createContext<HydraContextValue | null>(null);

const RESOLVING: TenantState = { status: "resolving", displayName: null, error: null };

export interface HydraProviderProps {
  /**
   * auth-service origin, e.g. "https://acme.hydra.example.com".
   *
   * MUST point at the same tenant host the page is served from. The tenant is resolved from
   * the `Host` of the API request, not of the page, so a page on `acme.localhost:5173` must
   * call `http://acme.localhost:8083` — calling `http://localhost:8083` sends a host with no
   * tenant label, and every lookup returns `unknown` while every login fails closed. Behind a
   * path-routing edge this is simply the page's own origin. No default by design.
   */
  apiBaseUrl: string;
  /** order-service origin. Defaults to `apiBaseUrl` for single-origin gateway setups. */
  ordersBaseUrl?: string;
  children: ReactNode;
}

/**
 * Wraps the app once and hosts the session-manager instance every hook reads from.
 *
 * The instance is per-provider rather than module-level on purpose: a module singleton
 * leaks one test's session into the next and makes two providers on one page fight over
 * the same access token.
 *
 * On mount it performs exactly TWO one-shot calls, in parallel:
 *
 *  - a silent `restoreSession()` — the entire mechanism by which a page reload keeps the
 *    user signed in (FR-003), since the access token is deliberately never persisted
 *    (FR-006) and there is nothing to read back except the httpOnly refresh cookie;
 *  - one tenant resolution — which organization this address belongs to. It lives here
 *    rather than in `LoginForm` because it is the only placement where two components
 *    cannot each fire their own call or disagree about the answer.
 */
export function HydraProvider({ apiBaseUrl, ordersBaseUrl, children }: HydraProviderProps) {
  const [tenant, setTenant] = useState<TenantState>(RESOLVING);

  const clients = useMemo(() => {
    const sessionManager = createSessionManager({ apiBaseUrl });
    const httpClient = createHttpClient({ apiBaseUrl, sessionManager });
    return { sessionManager, httpClient, ordersBaseUrl: ordersBaseUrl ?? apiBaseUrl };
  }, [apiBaseUrl, ordersBaseUrl]);

  const value = useMemo<HydraContextValue>(() => ({ ...clients, tenant }), [clients, tenant]);

  // Guards against React 18+ StrictMode's deliberate double-invocation of effects in
  // development, which would otherwise fire two calls at mount — visible in the network tab
  // and, against the per-IP rate limits, occasionally a real 429. Keyed on `clients` rather
  // than `value`, which changes on every resolution update and would re-run the effect.
  const startedFor = useRef<typeof clients | null>(null);

  useEffect(() => {
    if (startedFor.current === clients) return;
    startedFor.current = clients;

    void clients.sessionManager.restoreSession();

    // Deliberately NOT cancelled on cleanup, and the two lines above are why.
    //
    // Aborting here combines with the `startedFor` guard to cancel the only request that
    // guard ever allows: StrictMode runs the effect, cleans it up (aborting the in-flight
    // lookup), then runs it again — and the second run returns early, so nothing replaces
    // what was just aborted. `tenant` then sits on `resolving` forever and the sign-in page
    // renders its loading state permanently, with a single ERR_ABORTED in the network tab as
    // the only clue. Resetting the guard in cleanup instead would fix the hang but reinstate
    // the double call this effect exists to prevent.
    //
    // The cost of not cancelling is a `setTenant` on an unmounted provider if it unmounts
    // mid-flight — a no-op in React 18+, and one lookup is what the guard promises anyway.
    void (async () => {
      try {
        const resolution = await fetchTenantResolution(apiBaseUrl);
        setTenant({
          status: resolution.status,
          displayName: resolution.displayName,
          error: null,
        });
      } catch (caught) {
        setTenant({
          status: "error",
          displayName: null,
          error:
            caught instanceof ApiError
              ? caught
              : new ApiError({
                  code: "network_error",
                  message: "We couldn't reach the server. Check your connection and try again.",
                  status: 0,
                  cause: caught,
                }),
        });
      }
    })();
  }, [clients, apiBaseUrl]);

  return <HydraContext.Provider value={value}>{children}</HydraContext.Provider>;
}

export function useHydraContext(): HydraContextValue {
  const context = useContext(HydraContext);
  if (context === null) {
    throw new Error("@hydra/ui hooks must be used inside a <HydraProvider>.");
  }
  return context;
}

/** The order-service-scoped HTTP client. Same session, different origin. */
export function useOrdersClient(): HttpClient {
  const { ordersBaseUrl, sessionManager } = useHydraContext();
  return useMemo(
    () => createHttpClient({ apiBaseUrl: ordersBaseUrl, sessionManager }),
    [ordersBaseUrl, sessionManager],
  );
}
