import { useState, type ReactNode } from "react";
import { HydraProvider } from "../src/components/HydraProvider";

/**
 * Stories point at a REAL locally-running auth-service/order-service rather than a mock
 * layer. The whole point of the Storybook pass in quickstart.md §2 is to watch the
 * production refresh flow happen in a browser's network tab — against a fake it would
 * prove nothing about the cookie, CORS, or the rotation.
 *
 * The defaults below match the services' own dev configuration: auth-service on 8083,
 * order-service on 8082, and `hydra.cors.allowed-origin-patterns` covering
 * http://*.localhost:6006, which is where Storybook must be served from for the
 * credentialed requests to be allowed.
 *
 * Serve Storybook from a tenant address (http://acme.localhost:6006) — the origins below are
 * derived from the current hostname because the tenant is the host the API call is addressed
 * to, not the host of the page. A fixed http://localhost:8083 resolves to no tenant at all.
 */
const AUTH_PORT = import.meta.env["VITE_HYDRA_AUTH_PORT"] ?? "8083";
const ORDERS_PORT = import.meta.env["VITE_HYDRA_ORDERS_PORT"] ?? "8082";

export const STORY_AUTH_BASE_URL = `${window.location.protocol}//${window.location.hostname}:${AUTH_PORT}`;
export const STORY_ORDERS_BASE_URL = `${window.location.protocol}//${window.location.hostname}:${ORDERS_PORT}`;

export function withHydra(children: ReactNode) {
  return (
    <HydraProvider apiBaseUrl={STORY_AUTH_BASE_URL} ordersBaseUrl={STORY_ORDERS_BASE_URL}>
      {children}
    </HydraProvider>
  );
}

/** The lookup outcomes a story can pin without a running backend. */
export type MockTenantOutcome = "recognized" | "inactive" | "unknown" | "error" | "pending";

/**
 * Pins `GET /api/v1/tenant` to one outcome so every sign-in state can be viewed without
 * standing up a tenant per state in a real database.
 *
 * The patch is installed during render — before `HydraProvider`'s mount effect fires the
 * lookup — and only intercepts that one path; everything else still reaches the real
 * services, which is the point of these stories.
 */
export function withMockedTenant(outcome: MockTenantOutcome, children: ReactNode) {
  return <MockTenantLookup outcome={outcome}>{children}</MockTenantLookup>;
}

function MockTenantLookup({
  outcome,
  children,
}: {
  outcome: MockTenantOutcome;
  children: ReactNode;
}) {
  // useState's initializer runs during this render, so the patch is in place before any
  // child effect can call fetch.
  useState(() => {
    const realFetch = globalThis.fetch;
    globalThis.fetch = ((input: RequestInfo | URL, init?: RequestInit) => {
      const url = typeof input === "string" ? input : input instanceof URL ? input.href : input.url;
      if (!url.includes("/api/v1/tenant")) return realFetch(input, init);

      if (outcome === "pending") return new Promise<Response>(() => {});
      if (outcome === "error") return Promise.resolve(new Response(null, { status: 503 }));

      const body =
        outcome === "recognized" ? { status: "recognized", displayName: "Acme Corp" } : { status: outcome };
      return Promise.resolve(Response.json(body));
    }) as typeof fetch;
    return outcome;
  });

  return withHydra(children);
}
