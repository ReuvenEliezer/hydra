import { render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { http } from "msw";
import { describe, expect, it } from "vitest";
import { LoginForm } from "../../src/components/hydra/LoginForm";
import { RegisterAdminForm } from "../../src/components/hydra/RegisterAdminForm";
import { RegisterUserForm } from "../../src/components/hydra/RegisterUserForm";
import {
  PASSWORD_MAX_LENGTH,
  PASSWORD_MIN_LENGTH,
  USERNAME_MAX_LENGTH,
  USERNAME_MIN_LENGTH,
  validatePassword,
  validateUsername,
} from "../../src/lib/credential-validation";
import { API_BASE_URL } from "../mocks/handlers";
import { TEST_TENANT_ID } from "../mocks/jwt";
import { server } from "../mocks/server";
import { startSignedInAs, startSignedOut, wrapper } from "../test-utils";

/**
 * FR-019: the client-side bounds must mirror the backend's `@Size` constraints exactly.
 *
 * The 100-character password MAXIMUM is the one that gets dropped — it is enforced
 * server-side (`@Size(min = 8, max = 100)`), so leaving it out here doesn't relax
 * anything, it just turns an inline message into a confusing 400 after submit. Each form
 * is checked separately because "same validation" is an intention, not a guarantee.
 */
const TOO_LONG_USERNAME = "u".repeat(USERNAME_MAX_LENGTH + 1);
const TOO_LONG_PASSWORD = "p".repeat(PASSWORD_MAX_LENGTH + 1);

describe("credential bounds", () => {
  it("matches the backend's username bounds at every boundary", () => {
    expect(validateUsername("u".repeat(USERNAME_MIN_LENGTH - 1))).toBeDefined();
    expect(validateUsername("u".repeat(USERNAME_MIN_LENGTH))).toBeUndefined();
    expect(validateUsername("u".repeat(USERNAME_MAX_LENGTH))).toBeUndefined();
    expect(validateUsername(TOO_LONG_USERNAME)).toBeDefined();
    expect(validateUsername("   ")).toBeDefined();
  });

  it("matches the backend's password bounds at every boundary, including the maximum", () => {
    expect(validatePassword("p".repeat(PASSWORD_MIN_LENGTH - 1))).toBeDefined();
    expect(validatePassword("p".repeat(PASSWORD_MIN_LENGTH))).toBeUndefined();
    expect(validatePassword("p".repeat(PASSWORD_MAX_LENGTH))).toBeUndefined();
    expect(validatePassword(TOO_LONG_PASSWORD)).toBeDefined();
  });

  it("uses exactly the backend's numbers", () => {
    expect([USERNAME_MIN_LENGTH, USERNAME_MAX_LENGTH]).toEqual([3, 50]);
    expect([PASSWORD_MIN_LENGTH, PASSWORD_MAX_LENGTH]).toEqual([8, 100]);
  });
});

describe("the same rules apply in every credential form", () => {
  it("LoginForm rejects an over-long password without calling the server", async () => {
    startSignedOut();
    let calls = 0;
    server.use(
      http.post(`${API_BASE_URL}/api/v1/auth/login`, () => {
        calls += 1;
        return Response.json({ userId: "x", token: "a.b.c" });
      }),
    );

    render(<LoginForm />, { wrapper });
    const user = userEvent.setup();
    await user.type(screen.getByLabelText("Username"), "good-username");
    await user.type(screen.getByLabelText("Password"), TOO_LONG_PASSWORD);
    await user.click(screen.getByRole("button", { name: /sign in/i }));

    expect(await screen.findByText(/at most 100 characters/i)).toBeInTheDocument();
    expect(calls).toBe(0);
  });

  it("RegisterUserForm rejects an over-long username without calling the server", async () => {
    startSignedInAs("ROLE_ADMIN");
    let calls = 0;
    server.use(
      http.post(`${API_BASE_URL}/api/v1/admin/register-user`, () => {
        calls += 1;
        return Response.json({ userId: "x", message: "USER_CREATED" }, { status: 201 });
      }),
    );

    render(<RegisterUserForm />, { wrapper });
    const user = userEvent.setup();
    await user.type(await screen.findByLabelText("Username"), TOO_LONG_USERNAME);
    await user.type(screen.getByLabelText("Password"), "a-good-password");
    await user.click(screen.getByRole("button", { name: /create user/i }));

    expect(await screen.findByText(/between 3 and 50 characters/i)).toBeInTheDocument();
    expect(calls).toBe(0);
  });

  it("RegisterAdminForm rejects a too-short password without calling the server", async () => {
    startSignedInAs("ROLE_SUPER_ADMIN");
    let calls = 0;
    server.use(
      http.post(`${API_BASE_URL}/api/v1/admin/:tenantId/register-admin`, () => {
        calls += 1;
        return Response.json({ userId: "x", message: "TENANT_ADMIN_CREATED" }, { status: 201 });
      }),
    );

    render(<RegisterAdminForm defaultTenantId={TEST_TENANT_ID} />, { wrapper });
    const user = userEvent.setup();
    await user.type(await screen.findByLabelText("Username"), "new-admin");
    await user.type(screen.getByLabelText("Password"), "short");
    await user.click(screen.getByRole("button", { name: /create admin/i }));

    expect(await screen.findByText(/at least 8 characters/i)).toBeInTheDocument();
    expect(calls).toBe(0);
  });
});
