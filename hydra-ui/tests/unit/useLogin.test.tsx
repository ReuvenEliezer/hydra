import { act, renderHook, waitFor } from "@testing-library/react";
import { HttpResponse, http } from "msw";
import { describe, expect, it } from "vitest";
import { useLogin } from "../../src/hooks/useLogin";
import { useSession } from "../../src/hooks/useSession";
import {
  API_BASE_URL,
  VALID_PASSWORD,
  VALID_USERNAME,
  errorShapeA,
  errorShapeB,
} from "../mocks/handlers";
import { TEST_TENANT_ID } from "../mocks/jwt";
import { server } from "../mocks/server";
import { startSignedOut, wrapper } from "../test-utils";

function useLoginWithSession() {
  return { login: useLogin(), session: useSession() };
}

describe("useLogin", () => {
  it("authenticates the session on success", async () => {
    startSignedOut();
    const { result } = renderHook(() => useLoginWithSession(), { wrapper });
    await waitFor(() => expect(result.current.session.status).toBe("anonymous"));

    await act(async () => {
      await result.current.login.login(VALID_USERNAME, VALID_PASSWORD);
    });

    expect(result.current.session.status).toBe("authenticated");
    expect(result.current.login.error).toBeNull();
    expect(result.current.login.isPending).toBe(false);
  });

  it("sends X-Tenant-ID — without it the backend rejects the call before checking credentials", async () => {
    startSignedOut();
    let sentTenantId: string | null = null;
    server.use(
      http.post(`${API_BASE_URL}/api/v1/auth/login`, ({ request }) => {
        sentTenantId = request.headers.get("X-Tenant-ID");
        return HttpResponse.json({ userId: "id", token: "a.b.c" });
      }),
    );

    const { result } = renderHook(() => useLoginWithSession(), { wrapper });
    await waitFor(() => expect(result.current.session.status).toBe("anonymous"));

    await act(async () => {
      await result.current.login.login(VALID_USERNAME, VALID_PASSWORD);
    });

    expect(sentTenantId).toBe(TEST_TENANT_ID);
  });

  it("surfaces invalid credentials without revealing which field was wrong", async () => {
    startSignedOut();
    const { result } = renderHook(() => useLoginWithSession(), { wrapper });
    await waitFor(() => expect(result.current.session.status).toBe("anonymous"));

    await act(async () => {
      await expect(result.current.login.login(VALID_USERNAME, "wrong-password")).rejects.toThrow();
    });

    expect(result.current.login.error?.code).toBe("invalid_credentials");
    expect(result.current.session.status).toBe("anonymous");
    const message = result.current.login.error?.message.toLowerCase() ?? "";
    expect(message).not.toContain("password is");
    expect(message).not.toContain("no such user");
  });

  it("surfaces a validation error distinctly from bad credentials", async () => {
    startSignedOut();
    server.use(
      http.post(`${API_BASE_URL}/api/v1/auth/login`, () =>
        errorShapeA(
          400,
          "Bad Request",
          "Username must be between 3 and 50 characters",
          "/api/v1/auth/login",
        ),
      ),
    );

    const { result } = renderHook(() => useLoginWithSession(), { wrapper });
    await waitFor(() => expect(result.current.session.status).toBe("anonymous"));

    await act(async () => {
      await expect(result.current.login.login("ab", VALID_PASSWORD)).rejects.toThrow();
    });

    expect(result.current.login.error?.code).toBe("validation_error");
    expect(result.current.login.error?.message).toContain("between 3 and 50");
  });

  it("surfaces a rate limit with its retry delay", async () => {
    startSignedOut();
    server.use(
      http.post(`${API_BASE_URL}/api/v1/auth/login`, () => errorShapeB("/api/v1/auth/login", 30)),
    );

    const { result } = renderHook(() => useLoginWithSession(), { wrapper });
    await waitFor(() => expect(result.current.session.status).toBe("anonymous"));

    await act(async () => {
      await expect(result.current.login.login(VALID_USERNAME, VALID_PASSWORD)).rejects.toThrow();
    });

    expect(result.current.login.error?.code).toBe("rate_limit_exceeded");
    expect(result.current.login.error?.retryAfterSeconds).toBe(30);
  });

  it("reports a network failure as such rather than as a rejected sign-in", async () => {
    startSignedOut();
    server.use(http.post(`${API_BASE_URL}/api/v1/auth/login`, () => HttpResponse.error()));

    const { result } = renderHook(() => useLoginWithSession(), { wrapper });
    await waitFor(() => expect(result.current.session.status).toBe("anonymous"));

    await act(async () => {
      await expect(result.current.login.login(VALID_USERNAME, VALID_PASSWORD)).rejects.toThrow();
    });

    expect(result.current.login.error?.code).toBe("network_error");
  });

  it("does not attempt a token refresh when login itself returns 401", async () => {
    startSignedOut();
    let refreshCalls = 0;
    server.use(
      http.post(`${API_BASE_URL}/api/v1/auth/refresh`, () => {
        refreshCalls += 1;
        return errorShapeA(401, "Unauthorized", "invalid_refresh_token", "/api/v1/auth/refresh");
      }),
    );

    const { result } = renderHook(() => useLoginWithSession(), { wrapper });
    await waitFor(() => expect(result.current.session.status).toBe("anonymous"));
    const afterMount = refreshCalls;

    await act(async () => {
      await expect(result.current.login.login(VALID_USERNAME, "wrong-password")).rejects.toThrow();
    });

    // A 401 on login means "wrong password", not "expired token" — renewing here would
    // be nonsense and would burn the refresh endpoint's rate limit on every typo.
    expect(refreshCalls).toBe(afterMount);
  });
});
