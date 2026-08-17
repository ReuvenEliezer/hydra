import { act, renderHook, waitFor } from "@testing-library/react";
import { http } from "msw";
import { describe, expect, it } from "vitest";
import { useCancelOrder } from "../../src/hooks/useCancelOrder";
import { useCreateOrder } from "../../src/hooks/useCreateOrder";
import { useSession } from "../../src/hooks/useSession";
import { useUpdateOrderStatus } from "../../src/hooks/useUpdateOrderStatus";
import { ORDERS_BASE_URL, errorShapeA, errorShapeB, errorShapeC } from "../mocks/handlers";
import { server } from "../mocks/server";
import { startSignedInAs, wrapper } from "../test-utils";

/**
 * FR-020, FR-021, FR-023 across the hooks that carry them.
 *
 * The property under test is that each condition arrives with its OWN code and its own
 * text — a UI that renders "something went wrong" for a duplicate order number, a
 * forbidden action, and a rate limit alike would satisfy none of these requirements
 * while looking like it worked.
 */
const ORDER_ID = "1f0a1b2c-3d4e-5f60-7182-93a4b5c6d7e8";

async function signedInAdmin<T>(useHook: () => T) {
  const { result } = renderHook(() => ({ hook: useHook(), session: useSession() }), { wrapper });
  await waitFor(() => expect(result.current.session.status).toBe("authenticated"));
  return result;
}

describe("error mapping across hooks", () => {
  it("distinguishes a duplicate order number (422) from a validation failure", async () => {
    startSignedInAs("ROLE_ADMIN");
    server.use(
      http.post(`${ORDERS_BASE_URL}/api/orders`, () =>
        errorShapeA(
          422,
          "Unprocessable Content",
          "Order number already exists in this tenant: ORD-1001",
          "/api/orders",
        ),
      ),
    );

    const result = await signedInAdmin(useCreateOrder);

    await act(async () => {
      await expect(
        result.current.hook.createOrder({ orderNumber: "ORD-1001", totalAmount: "10.00" }),
      ).rejects.toMatchObject({ code: "business_rule_violation", status: 422 });
    });
    expect(result.current.hook.error?.message).toContain("already exists");
  });

  it("distinguishes an invalid status transition (422) from a permission failure (403)", async () => {
    startSignedInAs("ROLE_ADMIN");
    server.use(
      http.patch(`${ORDERS_BASE_URL}/api/orders/:id/status`, () =>
        errorShapeA(
          422,
          "Unprocessable Content",
          "Invalid status transition: DELIVERED -> SHIPPED",
          `/api/orders/${ORDER_ID}/status`,
        ),
      ),
    );

    const result = await signedInAdmin(useUpdateOrderStatus);

    await act(async () => {
      await expect(result.current.hook.updateStatus(ORDER_ID, "SHIPPED")).rejects.toMatchObject({
        code: "business_rule_violation",
      });
    });
    expect(result.current.hook.error?.message).toContain("Invalid status transition");
  });

  it("maps a filter-level 403 to permission_denied even with no message in the body", async () => {
    startSignedInAs("ROLE_USER");
    server.use(
      http.patch(`${ORDERS_BASE_URL}/api/orders/:id/status`, () =>
        errorShapeC(403, "Forbidden", `/api/orders/${ORDER_ID}/status`),
      ),
    );

    const result = await signedInAdmin(useUpdateOrderStatus);

    await act(async () => {
      await expect(result.current.hook.updateStatus(ORDER_ID, "SHIPPED")).rejects.toMatchObject({
        code: "permission_denied",
        status: 403,
      });
    });
    // Shape C carries no text at all, so a usable default has to be supplied.
    expect(result.current.hook.error?.message.length).toBeGreaterThan(0);
  });

  it("maps cancelling a delivered order to its own business-rule message", async () => {
    startSignedInAs("ROLE_ADMIN");
    server.use(
      http.delete(`${ORDERS_BASE_URL}/api/orders/:id`, () =>
        errorShapeA(
          422,
          "Unprocessable Content",
          "Cannot cancel a delivered order",
          `/api/orders/${ORDER_ID}`,
        ),
      ),
    );

    const result = await signedInAdmin(useCancelOrder);

    await act(async () => {
      await expect(result.current.hook.cancelOrder(ORDER_ID)).rejects.toMatchObject({
        code: "business_rule_violation",
      });
    });
    expect(result.current.hook.error?.message).toBe("Cannot cancel a delivered order");
  });

  it("surfaces a rate limit with its Retry-After delay rather than a generic error", async () => {
    startSignedInAs("ROLE_ADMIN");
    server.use(
      http.post(`${ORDERS_BASE_URL}/api/orders`, () => errorShapeB("/api/orders", 15)),
    );

    const result = await signedInAdmin(useCreateOrder);

    await act(async () => {
      await expect(
        result.current.hook.createOrder({ orderNumber: "ORD-9", totalAmount: "1.00" }),
      ).rejects.toMatchObject({ code: "rate_limit_exceeded", retryAfterSeconds: 15 });
    });
  });

  it("maps a not-found order to its own code", async () => {
    startSignedInAs("ROLE_ADMIN");
    server.use(
      http.delete(`${ORDERS_BASE_URL}/api/orders/:id`, () =>
        errorShapeA(404, "Not Found", `Order not found: ${ORDER_ID}`, `/api/orders/${ORDER_ID}`),
      ),
    );

    const result = await signedInAdmin(useCancelOrder);

    await act(async () => {
      await expect(result.current.hook.cancelOrder(ORDER_ID)).rejects.toMatchObject({
        code: "not_found",
      });
    });
  });

  it("gives the two known auth failures distinct codes", async () => {
    // These arrive through the session manager rather than a hook, but they are the two
    // codes FR-020 names explicitly, so they are asserted alongside the rest.
    const { normalizeError } = await import("../../src/lib/normalize-error");
    const headers = { get: () => null };

    expect(normalizeError({ status: 401, headers }, { message: "invalid_refresh_token" }).code).toBe(
      "invalid_refresh_token",
    );
    expect(
      normalizeError({ status: 401, headers }, { message: "refresh_token_reuse_detected" }).code,
    ).toBe("refresh_token_reuse_detected");
  });

  it("gives the two tenant-address failures distinct codes, never invalid_credentials", async () => {
    const { normalizeError } = await import("../../src/lib/normalize-error");
    const headers = { get: () => null };

    expect(normalizeError({ status: 400, headers }, { message: "unknown_tenant_address" }).code)
      .toBe("unknown_tenant_address");
    expect(normalizeError({ status: 403, headers }, { message: "tenant_inactive" }).code)
      .toBe("tenant_inactive");
  });
});
