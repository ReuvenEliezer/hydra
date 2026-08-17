import { HttpResponse, http } from "msw";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { createSessionManager } from "../../src/lib/session-manager";
import { API_BASE_URL } from "../mocks/handlers";
import { makeAccessToken, TEST_TENANT_ID, TEST_USER_ID, TEST_USERNAME } from "../mocks/jwt";
import { server } from "../mocks/server";

/**
 * SC-005: N concurrent post-expiry requests must produce exactly ONE refresh call, and
 * every one of them must eventually resolve.
 *
 * The refresh handler below only resolves once the test releases it, so all N callers
 * are genuinely in flight at the same moment — a handler that answered immediately
 * would let the calls serialize and the test would pass without proving anything.
 */
describe("session-manager refresh coalescing", () => {
  let refreshCallCount = 0;

  beforeEach(() => {
    refreshCallCount = 0;
  });

  function installGatedRefresh(): { release: () => void } {
    let release!: () => void;
    const gate = new Promise<void>((resolve) => {
      release = resolve;
    });

    server.use(
      http.post(`${API_BASE_URL}/api/v1/auth/refresh`, async () => {
        refreshCallCount += 1;
        await gate;
        return HttpResponse.json({ userId: TEST_USER_ID, token: makeAccessToken() });
      }),
    );

    return { release };
  }

  it("coalesces 10 concurrent refreshes into one network call and resolves all of them", async () => {
    const { release } = installGatedRefresh();
    const manager = createSessionManager({ apiBaseUrl: API_BASE_URL });
    manager.adoptAccessToken(makeAccessToken());

    const pending = Array.from({ length: 10 }, () => manager.refresh());
    expect(manager.getState().status).toBe("refreshing");

    release();
    const tokens = await Promise.all(pending);

    expect(refreshCallCount).toBe(1);
    expect(tokens).toHaveLength(10);
    for (const token of tokens) expect(typeof token).toBe("string");
    // All ten callers received the SAME token — i.e. they shared one result rather than
    // each racing their own renewal.
    expect(new Set(tokens).size).toBe(1);
    expect(manager.getState().status).toBe("authenticated");
  });

  it("allows a fresh refresh after the previous one settles", async () => {
    const manager = createSessionManager({ apiBaseUrl: API_BASE_URL });
    manager.adoptAccessToken(makeAccessToken());

    await manager.refresh();
    await manager.refresh();

    // Coalescing is per-burst, not a permanent latch: a later expiry must be able to
    // renew again.
    expect(manager.getState().status).toBe("authenticated");
  });

  it("populates user identity and roles from the token's claims", async () => {
    server.use(
      http.post(`${API_BASE_URL}/api/v1/auth/refresh`, () =>
        HttpResponse.json({
          userId: TEST_USER_ID,
          token: makeAccessToken({ roles: ["ROLE_ADMIN"] }),
        }),
      ),
    );

    const manager = createSessionManager({ apiBaseUrl: API_BASE_URL });
    await manager.refresh();

    expect(manager.getState().user).toEqual({
      id: TEST_USER_ID,
      tenantId: TEST_TENANT_ID,
      username: TEST_USERNAME,
      roles: ["ROLE_ADMIN"],
    });
  });

  it("sends credentials so the browser attaches the httpOnly refresh cookie", async () => {
    const fetchSpy = vi.fn(globalThis.fetch);
    const manager = createSessionManager({ apiBaseUrl: API_BASE_URL, fetchImpl: fetchSpy });

    await manager.refresh();

    const [, init] = fetchSpy.mock.calls[0] ?? [];
    expect((init as RequestInit).credentials).toBe("include");
  });
});
