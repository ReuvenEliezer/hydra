import { render, screen, waitFor } from "@testing-library/react";
import { describe, expect, it } from "vitest";
import { CancelOrderButton } from "../../src/components/hydra/CancelOrderButton";
import { OrderStatusControl } from "../../src/components/hydra/OrderStatusControl";
import { RequireRole } from "../../src/components/hydra/RequireRole";
import { normalizeOrder } from "../../src/types/order";
import { makeOrder } from "../mocks/handlers";
import { SessionStatusProbe, startSignedInAs, startSignedOut, wrapper } from "../test-utils";

const pendingOrder = normalizeOrder(makeOrder({ status: "PENDING" }));

describe("RequireRole", () => {
  it("hides admin-only order controls from a ROLE_USER session (FR-015)", async () => {
    startSignedInAs("ROLE_USER");

    render(
      <>
        <SessionStatusProbe />
        <OrderStatusControl order={pendingOrder} />
        <CancelOrderButton order={pendingOrder} />
      </>,
      { wrapper },
    );

    // The session must be fully established before asserting an absence — otherwise
    // this passes while the restore is still in flight and proves nothing.
    await waitFor(() => {
      expect(screen.getByTestId("session-status")).toHaveTextContent("session:authenticated");
    });

    expect(screen.queryByRole("button", { name: /cancel order/i })).not.toBeInTheDocument();
    expect(screen.queryByText(/change status to/i)).not.toBeInTheDocument();
  });

  it("shows them for a ROLE_ADMIN session", async () => {
    startSignedInAs("ROLE_ADMIN");

    render(
      <>
        <OrderStatusControl order={pendingOrder} />
        <CancelOrderButton order={pendingOrder} />
      </>,
      { wrapper },
    );

    expect(await screen.findByRole("button", { name: /cancel order/i })).toBeInTheDocument();
    expect(screen.getByText(/change status to/i)).toBeInTheDocument();
  });

  it("honours the role hierarchy: ROLE_SUPER_ADMIN satisfies ROLE_ADMIN and ROLE_USER", async () => {
    startSignedInAs("ROLE_SUPER_ADMIN");

    render(
      <>
        <RequireRole role="ROLE_USER">
          <p>user area</p>
        </RequireRole>
        <RequireRole role="ROLE_ADMIN">
          <p>admin area</p>
        </RequireRole>
        <RequireRole role="ROLE_SUPER_ADMIN">
          <p>super admin area</p>
        </RequireRole>
      </>,
      { wrapper },
    );

    expect(await screen.findByText("user area")).toBeInTheDocument();
    expect(screen.getByText("admin area")).toBeInTheDocument();
    expect(screen.getByText("super admin area")).toBeInTheDocument();
  });

  it("does not let a lower role satisfy a higher one", async () => {
    startSignedInAs("ROLE_ADMIN");

    render(
      <RequireRole role="ROLE_SUPER_ADMIN" fallback={<p>not allowed</p>}>
        <p>super admin area</p>
      </RequireRole>,
      { wrapper },
    );

    expect(await screen.findByText("not allowed")).toBeInTheDocument();
    expect(screen.queryByText("super admin area")).not.toBeInTheDocument();
  });

  it("renders the fallback when there is no session at all", async () => {
    startSignedOut();

    render(
      <RequireRole role="ROLE_USER" fallback={<p>sign in first</p>}>
        <p>user area</p>
      </RequireRole>,
      { wrapper },
    );

    expect(await screen.findByText("sign in first")).toBeInTheDocument();
  });
});
