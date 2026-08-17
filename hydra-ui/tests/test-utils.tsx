import { http } from "msw";
import type { ReactNode } from "react";
import { HydraProvider } from "../src/components/HydraProvider";
import { useSession } from "../src/hooks/useSession";
import type { Role } from "../src/types/session";
import { API_BASE_URL, ORDERS_BASE_URL, errorShapeD } from "./mocks/handlers";
import { makeAccessToken, TEST_USER_ID } from "./mocks/jwt";
import { server } from "./mocks/server";

/**
 * Every test renders through a real `HydraProvider`, which means every test also runs the
 * mount-time `restoreSession()` AND the mount-time tenant lookup against MSW. That is
 * deliberate: neither is an optional extra — one is how a session exists at all after a
 * reload, the other is how the page knows which organization it belongs to — and a harness
 * that stubbed them out would be exercising a configuration that never ships.
 */
export function wrapper({ children }: { children: ReactNode }) {
  return (
    <HydraProvider apiBaseUrl={API_BASE_URL} ordersBaseUrl={ORDERS_BASE_URL}>
      {children}
    </HydraProvider>
  );
}

/**
 * Makes the mount-time restore fail the way a first-time visitor's does: no refresh
 * cookie, so the provider settles on `anonymous` instead of silently signing in.
 */
export function startSignedOut(): void {
  server.use(http.post(`${API_BASE_URL}/api/v1/auth/refresh`, () => errorShapeD()));
}

/**
 * Renders the current session status. Drop it alongside the component under test and
 * `await screen.findByText("session:authenticated")` before asserting that something is
 * ABSENT — otherwise the assertion passes while the restore is still in flight and
 * proves nothing.
 */
export function SessionStatusProbe() {
  const { status } = useSession();
  return <span data-testid="session-status">session:{status}</span>;
}

/** Makes the mount-time restore succeed with a session holding the given roles. */
export function startSignedInAs(...roles: Role[]): void {
  server.use(
    http.post(`${API_BASE_URL}/api/v1/auth/refresh`, () =>
      Response.json({ userId: TEST_USER_ID, token: makeAccessToken({ roles }) }),
    ),
  );
}
