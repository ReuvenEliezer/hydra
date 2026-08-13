import { render, screen, waitFor } from "@testing-library/react";
import { http } from "msw";
import { describe, expect, it } from "vitest";
import { SessionGate } from "../../src/components/hydra/SessionGate";
import { useSession } from "../../src/hooks/useSession";
import { API_BASE_URL, errorShapeD } from "../mocks/handlers";
import { server } from "../mocks/server";
import { startSignedInAs, wrapper } from "../test-utils";

/**
 * FR-003 / US1 Acceptance Scenario 4.
 *
 * A page reload wipes the in-memory access token by definition — it is never persisted
 * (FR-006). Staying signed in therefore depends entirely on the provider's mount-time
 * silent refresh rehydrating it from the httpOnly cookie, with no user interaction.
 * Mounting a fresh provider is exactly what a reload does.
 */
function SessionProbe() {
  const { status, user } = useSession();
  return (
    <div>
      <span data-testid="status">{status}</span>
      <span data-testid="user">{user?.id ?? "none"}</span>
    </div>
  );
}

describe("session restore on mount", () => {
  it("restores an authenticated session from the refresh cookie alone", async () => {
    startSignedInAs("ROLE_USER");

    render(<SessionProbe />, { wrapper });

    await waitFor(() => {
      expect(screen.getByTestId("status")).toHaveTextContent("authenticated");
    });
    expect(screen.getByTestId("user")).not.toHaveTextContent("none");
  });

  it("settles on anonymous when there is no valid refresh cookie", async () => {
    server.use(http.post(`${API_BASE_URL}/api/v1/auth/refresh`, () => errorShapeD()));

    render(<SessionProbe />, { wrapper });

    await waitFor(() => {
      expect(screen.getByTestId("status")).toHaveTextContent("anonymous");
    });
  });

  it("never flashes the signed-out UI while the restore is in flight (SC-001)", async () => {
    startSignedInAs("ROLE_USER");

    render(
      <SessionGate fallback={<p>Please sign in</p>} pending={<p>Checking your session…</p>}>
        <p>Your orders</p>
      </SessionGate>,
      { wrapper },
    );

    // The pending branch is what renders first — not the fallback, which would be a
    // visible "you are signed out" flash for a user who is not.
    expect(screen.getByText("Checking your session…")).toBeInTheDocument();
    expect(screen.queryByText("Please sign in")).not.toBeInTheDocument();

    await waitFor(() => {
      expect(screen.getByText("Your orders")).toBeInTheDocument();
    });
    expect(screen.queryByText("Please sign in")).not.toBeInTheDocument();
  });

  it("issues exactly one restore call per provider mount", async () => {
    let calls = 0;
    server.use(
      http.post(`${API_BASE_URL}/api/v1/auth/refresh`, () => {
        calls += 1;
        return errorShapeD();
      }),
    );

    render(<SessionProbe />, { wrapper });

    await waitFor(() => {
      expect(screen.getByTestId("status")).toHaveTextContent("anonymous");
    });
    expect(calls).toBe(1);
  });
});
