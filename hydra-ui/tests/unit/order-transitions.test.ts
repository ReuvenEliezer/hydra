import { describe, expect, it } from "vitest";
import { allowedTransitions, canCancel, isTerminalStatus } from "../../src/lib/order-transitions";
import { ORDER_STATUSES } from "../../src/types/order";

/**
 * SC-007: the UI must never offer a transition the backend rejects. This asserts the
 * table against `OrderService.validateStatusTransition` for all four statuses,
 * including that the terminal ones offer nothing at all.
 */
describe("allowedTransitions", () => {
  it("matches the backend's state machine exactly", () => {
    expect(allowedTransitions("PENDING")).toEqual(["SHIPPED", "CANCELLED"]);
    expect(allowedTransitions("SHIPPED")).toEqual(["DELIVERED", "CANCELLED"]);
    expect(allowedTransitions("DELIVERED")).toEqual([]);
    expect(allowedTransitions("CANCELLED")).toEqual([]);
  });

  it("covers every status in the enum, so a new one cannot be silently unhandled", () => {
    for (const status of ORDER_STATUSES) {
      expect(Array.isArray(allowedTransitions(status))).toBe(true);
    }
  });

  it("never offers a self-transition", () => {
    for (const status of ORDER_STATUSES) {
      expect(allowedTransitions(status)).not.toContain(status);
    }
  });

  it("returns a fresh array so a caller cannot mutate the table", () => {
    const first = allowedTransitions("PENDING");
    first.push("DELIVERED");
    expect(allowedTransitions("PENDING")).toEqual(["SHIPPED", "CANCELLED"]);
  });

  it("marks exactly the terminal statuses as terminal", () => {
    expect(isTerminalStatus("PENDING")).toBe(false);
    expect(isTerminalStatus("SHIPPED")).toBe(false);
    expect(isTerminalStatus("DELIVERED")).toBe(true);
    expect(isTerminalStatus("CANCELLED")).toBe(true);
  });

  it("tracks cancel's own rule, which is not the transition table", () => {
    // Cancel is allowed from SHIPPED even though it is a separate endpoint, and refused
    // for DELIVERED/CANCELLED with a 422.
    expect(canCancel("PENDING")).toBe(true);
    expect(canCancel("SHIPPED")).toBe(true);
    expect(canCancel("DELIVERED")).toBe(false);
    expect(canCancel("CANCELLED")).toBe(false);
  });
});
