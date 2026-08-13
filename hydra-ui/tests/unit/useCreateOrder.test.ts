import { act, renderHook, waitFor } from "@testing-library/react";
import { http } from "msw";
import { describe, expect, it } from "vitest";
import { useCreateOrder, validateCreateOrder } from "../../src/hooks/useCreateOrder";
import { useSession } from "../../src/hooks/useSession";
import { ORDERS_BASE_URL, errorShapeA } from "../mocks/handlers";
import { server } from "../mocks/server";
import { startSignedInAs, wrapper } from "../test-utils";

/**
 * FR-011: invalid input must be rejected before any request is sent — not merely
 * rejected by the server. The counter below is the actual assertion; a message on
 * screen would not prove the network was never touched.
 */
describe("validateCreateOrder", () => {
  it("rejects a blank order number", () => {
    expect(validateCreateOrder({ orderNumber: "", totalAmount: "10" }).orderNumber).toBeDefined();
    expect(validateCreateOrder({ orderNumber: "   ", totalAmount: "10" }).orderNumber).toBeDefined();
  });

  it("rejects a non-positive or non-numeric amount, matching @DecimalMin(\"0.01\")", () => {
    expect(validateCreateOrder({ orderNumber: "A", totalAmount: "0" }).totalAmount).toBeDefined();
    expect(validateCreateOrder({ orderNumber: "A", totalAmount: "0.009" }).totalAmount).toBeDefined();
    expect(validateCreateOrder({ orderNumber: "A", totalAmount: "-5" }).totalAmount).toBeDefined();
    expect(validateCreateOrder({ orderNumber: "A", totalAmount: "abc" }).totalAmount).toBeDefined();
    expect(validateCreateOrder({ orderNumber: "A", totalAmount: "" }).totalAmount).toBeDefined();
  });

  it("accepts the boundary value the backend accepts", () => {
    expect(validateCreateOrder({ orderNumber: "ORD-1", totalAmount: "0.01" })).toEqual({});
    expect(validateCreateOrder({ orderNumber: "ORD-1", totalAmount: "129.99" })).toEqual({});
  });
});

describe("useCreateOrder", () => {
  it("sends no request at all when validation fails", async () => {
    startSignedInAs("ROLE_USER");
    let requests = 0;
    server.use(
      http.post(`${ORDERS_BASE_URL}/api/orders`, () => {
        requests += 1;
        return Response.json({}, { status: 201 });
      }),
    );

    const { result } = renderHook(() => ({ create: useCreateOrder(), session: useSession() }), {
      wrapper,
    });
    await waitFor(() => expect(result.current.session.status).toBe("authenticated"));

    await act(async () => {
      await expect(
        result.current.create.createOrder({ orderNumber: "", totalAmount: "0" }),
      ).rejects.toMatchObject({ code: "validation_error" });
    });

    expect(requests).toBe(0);
    expect(result.current.create.fieldErrors.orderNumber).toBeDefined();
    expect(result.current.create.fieldErrors.totalAmount).toBeDefined();
  });

  it("creates an order when the input is valid", async () => {
    startSignedInAs("ROLE_USER");
    const { result } = renderHook(() => ({ create: useCreateOrder(), session: useSession() }), {
      wrapper,
    });
    await waitFor(() => expect(result.current.session.status).toBe("authenticated"));

    let created: { orderNumber: string } | undefined;
    await act(async () => {
      created = await result.current.create.createOrder({
        orderNumber: "ORD-2001",
        totalAmount: "49.50",
      });
    });

    expect(created?.orderNumber).toBe("ORD-2001");
    expect(result.current.create.error).toBeNull();
  });

  it("surfaces a duplicate order number as a business-rule violation, not a validation error", async () => {
    startSignedInAs("ROLE_USER");
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

    const { result } = renderHook(() => ({ create: useCreateOrder(), session: useSession() }), {
      wrapper,
    });
    await waitFor(() => expect(result.current.session.status).toBe("authenticated"));

    await act(async () => {
      await expect(
        result.current.create.createOrder({ orderNumber: "ORD-1001", totalAmount: "10.00" }),
      ).rejects.toMatchObject({ code: "business_rule_violation" });
    });

    expect(result.current.create.error?.message).toContain("already exists");
  });
});
