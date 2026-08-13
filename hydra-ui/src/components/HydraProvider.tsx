import { createContext, useContext, useEffect, useMemo, useRef, type ReactNode } from "react";
import { createHttpClient, type HttpClient } from "../lib/http-client";
import { createSessionManager, type SessionManager } from "../lib/session-manager";

export interface HydraContextValue {
  sessionManager: SessionManager;
  httpClient: HttpClient;
  ordersBaseUrl: string;
  /** Provider-level default; `LoginForm` prefills its editable field from this. */
  tenantId: string;
}

const HydraContext = createContext<HydraContextValue | null>(null);

export interface HydraProviderProps {
  /** auth-service origin, e.g. "https://auth.hydra.example.com". No default by design. */
  apiBaseUrl: string;
  /**
   * REQUIRED. Sent as `X-Tenant-ID` on the login request only.
   * `AuthController.login` declares the header with no default, so a missing one is
   * rejected with 400 before the credentials are even looked at. How the app *obtains*
   * the tenant is its own concern; supplying it is not optional.
   */
  tenantId: string;
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
 * On mount it performs exactly ONE silent `restoreSession()`. That call is the entire
 * mechanism by which a page reload keeps the user signed in (FR-003) — the access token
 * is deliberately never persisted (FR-006), so there is nothing to read back except the
 * httpOnly refresh cookie. Session status stays `authenticating` until it settles, so
 * consumers never flash a signed-out UI on the way to a restored session (SC-001).
 */
export function HydraProvider({
  apiBaseUrl,
  tenantId,
  ordersBaseUrl,
  children,
}: HydraProviderProps) {
  const value = useMemo<HydraContextValue>(() => {
    const sessionManager = createSessionManager({ apiBaseUrl });
    const httpClient = createHttpClient({ apiBaseUrl, tenantId, sessionManager });
    return { sessionManager, httpClient, ordersBaseUrl: ordersBaseUrl ?? apiBaseUrl, tenantId };
  }, [apiBaseUrl, tenantId, ordersBaseUrl]);

  // Guards against React 18+ StrictMode's deliberate double-invocation of effects in
  // development, which would otherwise fire two refresh calls at mount — visible in the
  // network tab and, against the per-token rate limit, occasionally a real 429.
  const restoredFor = useRef<HydraContextValue | null>(null);

  useEffect(() => {
    if (restoredFor.current === value) return;
    restoredFor.current = value;
    void value.sessionManager.restoreSession();
  }, [value]);

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
    () =>
      createHttpClient({
        apiBaseUrl: ordersBaseUrl,
        // order-service never reads X-Tenant-ID (it derives the tenant from the JWT) and
        // does not allow the header through CORS, so nothing here ever sends it.
        tenantId: "",
        sessionManager,
      }),
    [ordersBaseUrl, sessionManager],
  );
}
