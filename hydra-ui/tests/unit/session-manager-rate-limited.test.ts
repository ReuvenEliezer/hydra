import { HttpResponse, http } from "msw";
import { describe, expect, it, vi } from "vitest";
import { createSessionManager } from "../../src/lib/session-manager";
import { API_BASE_URL, errorShapeB } from "../mocks/handlers";
import { makeAccessToken, TEST_USER_ID } from "../mocks/jwt";
import { server } from "../mocks/server";

/**
 * FR-021: the refresh endpoint is throttled per-IP AND per-token-hash, so a 429 there is
 * expected under load. It means "wait", not "your session is over" — signing users out
 * on a 429 would drop live sessions and lose their work, which is the failure this test
 * exists to prevent.
 */
describe("session-manager under a rate-limited refresh", () => {
  it("keeps the session alive, waits Retry-After, and retries once", async () => {
    const delays: number[] = [];
    const sleep = vi.fn(async (ms: number) => {
      delays.push(ms);
    });

    let calls = 0;
    server.use(
      http.post(`${API_BASE_URL}/api/v1/auth/refresh`, () => {
        calls += 1;
        if (calls === 1) return errorShapeB("/api/v1/auth/refresh", 3);
        return HttpResponse.json({ userId: TEST_USER_ID, token: makeAccessToken() });
      }),
    );

    const manager = createSessionManager({ apiBaseUrl: API_BASE_URL, sleep });
    manager.adoptAccessToken(makeAccessToken());

    const token = await manager.refresh();

    expect(calls).toBe(2);
    expect(delays).toEqual([3000]);
    expect(token).not.toBeNull();
    expect(manager.getState().status).toBe("authenticated");
  });

  it("never signs the user out when the retry is rate-limited too", async () => {
    const sleep = vi.fn(async () => undefined);
    server.use(
      http.post(`${API_BASE_URL}/api/v1/auth/refresh`, () => errorShapeB("/api/v1/auth/refresh", 1)),
    );

    const manager = createSessionManager({ apiBaseUrl: API_BASE_URL, sleep });
    manager.adoptAccessToken(makeAccessToken());

    await expect(manager.refresh()).rejects.toMatchObject({
      code: "rate_limit_exceeded",
      retryAfterSeconds: 1,
    });

    // Still signed in: a throttled renewal is a retryable error, not a dead session.
    expect(manager.getState().status).toBe("authenticated");
    expect(manager.getAccessToken()).not.toBeNull();
  });

  it("falls back to a one-second wait when Retry-After is unreadable", async () => {
    const delays: number[] = [];
    const sleep = vi.fn(async (ms: number) => {
      delays.push(ms);
    });

    let calls = 0;
    server.use(
      http.post(`${API_BASE_URL}/api/v1/auth/refresh`, () => {
        calls += 1;
        if (calls === 1) {
          // Cross-origin without `Access-Control-Expose-Headers: Retry-After`, the
          // browser hides the header even though the server sent it.
          return HttpResponse.json(
            { status: 429, error: "rate_limit_exceeded", message: "Slow down" },
            { status: 429 },
          );
        }
        return HttpResponse.json({ userId: TEST_USER_ID, token: makeAccessToken() });
      }),
    );

    const manager = createSessionManager({ apiBaseUrl: API_BASE_URL, sleep });
    manager.adoptAccessToken(makeAccessToken());

    await manager.refresh();

    expect(delays).toEqual([1000]);
  });
});
