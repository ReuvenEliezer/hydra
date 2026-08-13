import { HttpResponse, http } from "msw";
import { describe, expect, it, vi } from "vitest";
import { createSessionManager } from "../../src/lib/session-manager";
import { API_BASE_URL } from "../mocks/handlers";
import { makeAccessToken, TEST_USER_ID } from "../mocks/jwt";
import { server } from "../mocks/server";

/**
 * FR-007's hard guarantee is that after sign-out nothing happens on the user's behalf.
 * The interesting case is a sign-out that lands WHILE a refresh is already in flight:
 * the refresh must not be allowed to resurrect the session when it comes back.
 */
describe("session teardown on logout", () => {
  it("clears state immediately", () => {
    const manager = createSessionManager({ apiBaseUrl: API_BASE_URL });
    manager.adoptAccessToken(makeAccessToken());

    manager.clear("anonymous");

    expect(manager.getAccessToken()).toBeNull();
    expect(manager.getState()).toEqual({ status: "anonymous", user: null });
  });

  it("ignores an in-flight refresh that resolves after sign-out", async () => {
    let release!: () => void;
    const gate = new Promise<void>((resolve) => {
      release = resolve;
    });

    server.use(
      http.post(`${API_BASE_URL}/api/v1/auth/refresh`, async () => {
        await gate;
        return HttpResponse.json({ userId: TEST_USER_ID, token: makeAccessToken() });
      }),
    );

    const manager = createSessionManager({ apiBaseUrl: API_BASE_URL });
    manager.adoptAccessToken(makeAccessToken());

    const pending = manager.refresh();
    manager.clear("anonymous");
    release();

    // The late response must resolve to "no session" rather than re-authenticating.
    await expect(pending).resolves.toBeNull();
    expect(manager.getAccessToken()).toBeNull();
    expect(manager.getState().status).toBe("anonymous");
  });

  it("aborts the in-flight refresh request rather than leaving it running", async () => {
    const abortSignals: AbortSignal[] = [];
    const fetchImpl = vi.fn((_input: RequestInfo | URL, init?: RequestInit) => {
      if (init?.signal) abortSignals.push(init.signal);
      return new Promise<Response>(() => {
        // Never settles: the only way out is the abort.
      });
    }) as unknown as typeof fetch;

    const manager = createSessionManager({ apiBaseUrl: API_BASE_URL, fetchImpl });
    manager.adoptAccessToken(makeAccessToken());

    void manager.refresh();
    manager.clear("anonymous");

    expect(abortSignals).toHaveLength(1);
    expect(abortSignals[0]?.aborted).toBe(true);
  });

  it("starts from a clean slate for the next sign-in", async () => {
    const manager = createSessionManager({ apiBaseUrl: API_BASE_URL });
    manager.adoptAccessToken(makeAccessToken());
    manager.clear("anonymous");

    const token = await manager.refresh();

    expect(token).not.toBeNull();
    expect(manager.getState().status).toBe("authenticated");
  });
});
