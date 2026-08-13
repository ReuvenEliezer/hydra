import { describe, expect, it } from "vitest";
import { normalizeError } from "../../src/lib/normalize-error";

/**
 * One fixture per wire shape the backend actually produces (FR-020). These four are not
 * variations on a theme — they disagree about which field holds the machine code, and
 * one of them has no message field at all.
 */
function responseLike(status: number, headers: Record<string, string> = {}) {
  return {
    status,
    headers: {
      get: (name: string) => headers[name] ?? null,
    },
  };
}

describe("normalizeError", () => {
  it("shape A (GlobalExceptionHandler): reads the machine code out of `message`", () => {
    const error = normalizeError(responseLike(401), {
      status: 401,
      error: "Unauthorized",
      message: "invalid_refresh_token",
      path: "/api/v1/auth/refresh",
      timestamp: "2026-08-13T09:15:00Z",
    });

    expect(error.code).toBe("invalid_refresh_token");
    expect(error.status).toBe(401);
    expect(error.path).toBe("/api/v1/auth/refresh");
    // `message` held the code, not display text, so a default message is substituted.
    expect(error.message).not.toBe("invalid_refresh_token");
    expect(error.message.length).toBeGreaterThan(0);
  });

  it("shape A: a reuse-detection body maps to its own code, not a generic 401", () => {
    const error = normalizeError(responseLike(401), {
      status: 401,
      error: "Unauthorized",
      message: "refresh_token_reuse_detected",
      path: "/api/v1/auth/refresh",
    });

    expect(error.code).toBe("refresh_token_reuse_detected");
  });

  it("shape B (RateLimitExceptionHandler): reads the code out of `error` and the delay out of the header", () => {
    const error = normalizeError(responseLike(429, { "Retry-After": "42" }), {
      status: 429,
      error: "rate_limit_exceeded",
      message: "Too many requests, please slow down",
      path: "/api/v1/auth/login",
    });

    expect(error.code).toBe("rate_limit_exceeded");
    expect(error.retryAfterSeconds).toBe(42);
    // Here `message` IS human text, so it is kept for display.
    expect(error.message).toBe("Too many requests, please slow down");
  });

  it("shape C (security filter chain): derives the code from the status when the body has no message at all", () => {
    const error = normalizeError(responseLike(401), {
      timestamp: "2026-08-13T09:15:00Z",
      status: 401,
      error: "Unauthorized",
      path: "/api/orders",
    });

    expect(error.code).toBe("invalid_credentials");
    expect(error.status).toBe(401);
    expect(error.message.length).toBeGreaterThan(0);
  });

  it("shape C: a filter-level 403 becomes permission_denied", () => {
    const error = normalizeError(responseLike(403), {
      timestamp: "2026-08-13T09:15:00Z",
      status: 403,
      error: "Forbidden",
      path: "/api/orders/1/status",
    });

    expect(error.code).toBe("permission_denied");
  });

  it("shape D (cookieless refresh): a bare {message} body still resolves its code", () => {
    const error = normalizeError(responseLike(401), { message: "invalid_refresh_token" });

    expect(error.code).toBe("invalid_refresh_token");
    expect(error.status).toBe(401);
    expect(error.path).toBeUndefined();
  });

  it("takes the status from the response, never from the body", () => {
    // A body claiming a different status than the response must not win.
    const error = normalizeError(responseLike(422), { status: 200, message: "Cannot cancel a delivered order" });

    expect(error.status).toBe(422);
    expect(error.code).toBe("business_rule_violation");
    expect(error.message).toBe("Cannot cancel a delivered order");
  });

  it("survives an empty or non-object body", () => {
    expect(normalizeError(responseLike(500), null).code).toBe("server_error");
    expect(normalizeError(responseLike(404), "<html>Not Found</html>").code).toBe("not_found");
  });
});
