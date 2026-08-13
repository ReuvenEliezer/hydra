import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { http } from "msw";
import { describe, expect, it } from "vitest";
import { RegisterAdminForm } from "../../src/components/hydra/RegisterAdminForm";
import { RegisterUserForm } from "../../src/components/hydra/RegisterUserForm";
import { API_BASE_URL } from "../mocks/handlers";
import { TEST_TENANT_ID } from "../mocks/jwt";
import { server } from "../mocks/server";
import { SessionStatusProbe, startSignedInAs, wrapper } from "../test-utils";

/**
 * FR-018: registering admins is super-admin-only. An ordinary admin must not see the
 * form — and, because the whole form is unmounted rather than merely disabled, must have
 * no path to submit it either. The request counter is what actually proves the second
 * half.
 */
describe("RegisterAdminForm role gating", () => {
  it("is not rendered for a ROLE_ADMIN session, and no request is ever attempted", async () => {
    startSignedInAs("ROLE_ADMIN");
    let registerAdminCalls = 0;
    server.use(
      http.post(`${API_BASE_URL}/api/v1/admin/:tenantId/register-admin`, () => {
        registerAdminCalls += 1;
        return Response.json({ userId: "x", message: "TENANT_ADMIN_CREATED" }, { status: 201 });
      }),
    );

    render(
      <>
        <SessionStatusProbe />
        <RegisterAdminForm />
      </>,
      { wrapper },
    );

    await waitFor(() => {
      expect(screen.getByTestId("session-status")).toHaveTextContent("session:authenticated");
    });

    expect(screen.queryByText("Add a tenant admin")).not.toBeInTheDocument();
    expect(screen.queryByLabelText("Tenant ID")).not.toBeInTheDocument();
    expect(screen.queryByRole("button", { name: /create admin/i })).not.toBeInTheDocument();
    expect(registerAdminCalls).toBe(0);
  });

  it("is rendered for a ROLE_SUPER_ADMIN session", async () => {
    startSignedInAs("ROLE_SUPER_ADMIN");

    render(<RegisterAdminForm />, { wrapper });

    expect(await screen.findByRole("button", { name: /create admin/i })).toBeInTheDocument();
  });

  it("creates an admin for the given tenant", async () => {
    startSignedInAs("ROLE_SUPER_ADMIN");
    let requestedTenant: string | undefined;
    server.use(
      http.post(`${API_BASE_URL}/api/v1/admin/:tenantId/register-admin`, ({ params }) => {
        requestedTenant = String(params["tenantId"]);
        return Response.json({ userId: "new-id", message: "TENANT_ADMIN_CREATED" }, { status: 201 });
      }),
    );

    render(<RegisterAdminForm defaultTenantId={TEST_TENANT_ID} />, { wrapper });
    const user = userEvent.setup();

    await user.type(await screen.findByLabelText("Username"), "new-admin");
    await user.type(screen.getByLabelText("Password"), "a-good-password");
    await user.click(screen.getByRole("button", { name: /create admin/i }));

    expect(await screen.findByRole("status")).toHaveTextContent("new-admin");
    expect(requestedTenant).toBe(TEST_TENANT_ID);
  });

  it("still shows RegisterUserForm to a plain admin — only the admin form is restricted", async () => {
    startSignedInAs("ROLE_ADMIN");

    render(
      <>
        <RegisterUserForm />
        <RegisterAdminForm />
      </>,
      { wrapper },
    );

    expect(await screen.findByRole("button", { name: /create user/i })).toBeInTheDocument();
    expect(screen.queryByRole("button", { name: /create admin/i })).not.toBeInTheDocument();
  });
});
