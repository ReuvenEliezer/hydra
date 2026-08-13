import type { ReactNode } from "react";
import { HydraProvider } from "../src/components/HydraProvider";

/**
 * Stories point at a REAL locally-running auth-service/order-service rather than a mock
 * layer. The whole point of the Storybook pass in quickstart.md §2 is to watch the
 * production refresh flow happen in a browser's network tab — against a fake it would
 * prove nothing about the cookie, CORS, or the rotation.
 *
 * The defaults below match the services' own dev configuration: auth-service on 8083,
 * order-service on 8082, and `hydra.cors.allowed-origins` defaulting to
 * http://localhost:5173, which is where Storybook must be served from for the
 * credentialed requests to be allowed.
 */
export const STORY_AUTH_BASE_URL =
  import.meta.env["VITE_HYDRA_AUTH_URL"] ?? "http://localhost:8083";
export const STORY_ORDERS_BASE_URL =
  import.meta.env["VITE_HYDRA_ORDERS_URL"] ?? "http://localhost:8082";
export const STORY_TENANT_ID =
  import.meta.env["VITE_HYDRA_TENANT_ID"] ?? "00000000-0000-0000-0000-000000000000";

export function withHydra(children: ReactNode) {
  return (
    <HydraProvider
      apiBaseUrl={STORY_AUTH_BASE_URL}
      ordersBaseUrl={STORY_ORDERS_BASE_URL}
      tenantId={STORY_TENANT_ID}
    >
      {children}
    </HydraProvider>
  );
}
