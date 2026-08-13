import { render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { describe, expect, it } from "vitest";
import { OrderStatusControl } from "../../src/components/hydra/OrderStatusControl";
import { normalizeOrder, type OrderStatus } from "../../src/types/order";
import { makeOrder } from "../mocks/handlers";
import { startSignedInAs, wrapper } from "../test-utils";

/**
 * SC-007: the control offers exactly the transitions `OrderService.validateStatusTransition`
 * accepts — no more (which would produce an avoidable 422) and no fewer.
 */
async function openStatusMenu(): Promise<string[]> {
  const user = userEvent.setup();
  await user.click(await screen.findByRole("combobox", { name: /change status to/i }));
  const options = await screen.findAllByRole("option");
  return options.map((option) => option.textContent?.trim() ?? "");
}

function renderFor(status: OrderStatus) {
  startSignedInAs("ROLE_ADMIN");
  return render(<OrderStatusControl order={normalizeOrder(makeOrder({ status }))} />, { wrapper });
}

describe("OrderStatusControl", () => {
  it("offers only Shipped and Cancelled for a PENDING order", async () => {
    renderFor("PENDING");

    const options = await openStatusMenu();

    expect(options).toEqual(["Shipped", "Cancelled"]);
    expect(options).not.toContain("Delivered");
    expect(options).not.toContain("Pending");
  });

  it("offers only Delivered and Cancelled for a SHIPPED order", async () => {
    renderFor("SHIPPED");

    const options = await openStatusMenu();

    expect(options).toEqual(["Delivered", "Cancelled"]);
    // PENDING → SHIPPED is valid but SHIPPED → PENDING is not; the backend has no
    // reverse transitions at all.
    expect(options).not.toContain("Pending");
  });

  it("renders nothing actionable for a DELIVERED order", async () => {
    renderFor("DELIVERED");

    expect(await screen.findByText(/can't change status/i)).toBeInTheDocument();
    expect(screen.queryByRole("combobox")).not.toBeInTheDocument();
    expect(screen.queryByRole("button", { name: /apply/i })).not.toBeInTheDocument();
  });

  it("renders nothing actionable for a CANCELLED order", async () => {
    renderFor("CANCELLED");

    expect(await screen.findByText(/can't change status/i)).toBeInTheDocument();
    expect(screen.queryByRole("combobox")).not.toBeInTheDocument();
  });

  it("keeps Apply disabled until a status is chosen", async () => {
    renderFor("PENDING");

    expect(await screen.findByRole("button", { name: /apply/i })).toBeDisabled();
  });
});
