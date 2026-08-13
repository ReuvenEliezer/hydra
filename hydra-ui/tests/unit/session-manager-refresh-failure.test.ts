import { http } from "msw";
import { describe, expect, it } from "vitest";
import { createSessionManager } from "../../src/lib/session-manager";
import { API_BASE_URL, errorShapeA, errorShapeD } from "../mocks/handlers";
import { makeAccessToken } from "../mocks/jwt";
import { server } from "../mocks/server";

/**
 * FR-008: a refresh that comes back 401 means the renewal credential is dead. The only
 * correct response is a clean forced sign-out — no retry, no second attempt, no loop.
 * A retry loop here would hammer the refresh endpoint and trip its own rate limiter.
 */
describe("session-manager forced sign-out on a failed refresh", () => {
  it("clears the session and does not retry when refresh returns 401", async () => {
    let calls = 0;
    server.use(
      http.post(`${API_BASE_URL}/api/v1/auth/refresh`, () => {
        calls += 1;
        return errorShapeA(401, "Unauthorized", "invalid_refresh_token", "/api/v1/auth/refresh");
      }),
    );

    const manager = createSessionManager({ apiBaseUrl: API_BASE_URL });
    manager.adoptAccessToken(makeAccessToken());

    const result = await manager.refresh();

    expect(result).toBeNull();
    expect(calls).toBe(1);
    expect(manager.getAccessToken()).toBeNull();
    expect(manager.getState()).toEqual({ status: "expired", user: null });
  });

  it("treats the cookieless bare-{message} 401 the same way", async () => {
    server.use(http.post(`${API_BASE_URL}/api/v1/auth/refresh`, () => errorShapeD()));

    const manager = createSessionManager({ apiBaseUrl: API_BASE_URL });
    manager.adoptAccessToken(makeAccessToken());

    expect(await manager.refresh()).toBeNull();
    expect(manager.getState().status).toBe("expired");
  });

  it("does not keep issuing refreshes once the session is dead", async () => {
    let calls = 0;
    server.use(
      http.post(`${API_BASE_URL}/api/v1/auth/refresh`, () => {
        calls += 1;
        return errorShapeD();
      }),
    );

    const manager = createSessionManager({ apiBaseUrl: API_BASE_URL });
    manager.adoptAccessToken(makeAccessToken());

    await manager.refresh();
    await manager.refresh();

    // Each call is one deliberate attempt: no internal retry multiplied them, and the
    // second attempt is only there because the caller asked again.
    expect(calls).toBe(2);
    expect(manager.getState().status).toBe("expired");
  });

  it("does NOT sign the user out on a 5xx — the session is not proven dead", async () => {
    server.use(
      http.post(`${API_BASE_URL}/api/v1/auth/refresh`, () =>
        errorShapeA(503, "Service Unavailable", "An unexpected error occurred", "/api/v1/auth/refresh"),
      ),
    );

    const manager = createSessionManager({ apiBaseUrl: API_BASE_URL });
    manager.adoptAccessToken(makeAccessToken());

    await expect(manager.refresh()).rejects.toMatchObject({ code: "server_error" });
    expect(manager.getState().status).toBe("authenticated");
    expect(manager.getAccessToken()).not.toBeNull();
  });
});
