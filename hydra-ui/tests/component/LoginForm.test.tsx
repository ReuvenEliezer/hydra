import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { http } from "msw";
import { describe, expect, it } from "vitest";
import { LoginForm } from "../../src/components/hydra/LoginForm";
import {
  API_BASE_URL,
  TENANT_DISPLAY_NAME,
  VALID_PASSWORD,
  VALID_USERNAME,
  errorShapeA,
  errorShapeB,
  tenantInactive,
  tenantLookupFails,
  tenantUnknown,
} from "../mocks/handlers";
import { server } from "../mocks/server";
import { startSignedOut, wrapper } from "../test-utils";

/** SC-006 made mechanical: no state may render anything UUID-shaped. */
const UUID_SHAPED = /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/i;

async function signIn(username: string, password: string) {
  const user = userEvent.setup();
  // findBy, not getBy: the form does not exist until the tenant lookup resolves.
  await user.type(await screen.findByLabelText("Username"), username);
  await user.type(screen.getByLabelText("Password"), password);
  await user.click(screen.getByRole("button", { name: /sign in/i }));
}

/**
 * The two properties that must hold in EVERY state, checked against the rendered markup
 * rather than against named fields — a tenant input added under a different label, or a UUID
 * rendered into a data attribute, would still be caught.
 */
function expectNoTenantInputAndNoUuid(container: HTMLElement) {
  expect(container.querySelector('[name="tenantId"]')).toBeNull();
  expect(screen.queryByLabelText(/tenant/i)).not.toBeInTheDocument();
  expect(UUID_SHAPED.test(container.innerHTML)).toBe(false);
}

describe("LoginForm — tenant resolution states", () => {
  it("heads the form with the resolved organization's name", async () => {
    startSignedOut();
    const { container } = render(<LoginForm />, { wrapper });

    expect(
      await screen.findByRole("heading", { name: `Sign in to ${TENANT_DISPLAY_NAME}` }),
    ).toBeInTheDocument();
    expectNoTenantInputAndNoUuid(container);
  });

  it("renders exactly the username and password inputs — nothing tenant-related", async () => {
    startSignedOut();
    const { container } = render(<LoginForm />, { wrapper });

    await screen.findByLabelText("Username");
    expect(container.querySelectorAll("input")).toHaveLength(2);
    expect(screen.getByLabelText("Password")).toBeInTheDocument();
    expectNoTenantInputAndNoUuid(container);
  });

  it("lets an explicit title override the organization heading", async () => {
    startSignedOut();
    render(<LoginForm title="Welcome back" />, { wrapper });

    expect(await screen.findByRole("heading", { name: "Welcome back" })).toBeInTheDocument();
    expect(screen.queryByText(new RegExp(TENANT_DISPLAY_NAME))).not.toBeInTheDocument();
  });

  it("shows a neutral loading state while resolving — never a form, never an error", async () => {
    startSignedOut();
    // A lookup that never settles keeps the component in `resolving` for the assertion.
    server.use(http.get(`${API_BASE_URL}/api/v1/tenant`, () => new Promise(() => {})));

    const { container } = render(<LoginForm />, { wrapper });

    expect(await screen.findByRole("status")).toBeInTheDocument();
    expect(screen.queryByLabelText("Username")).not.toBeInTheDocument();
    expect(screen.queryByRole("alert")).not.toBeInTheDocument();
    expectNoTenantInputAndNoUuid(container);
  });

  it.each([
    ["unknown", tenantUnknown, /isn't recognized/i],
    ["inactive", tenantInactive, /inactive/i],
    ["error", tenantLookupFails, /couldn't reach/i],
  ])("renders %s as its own message with NO form at all", async (status, handler, copy) => {
    startSignedOut();
    server.use(handler());

    const { container } = render(<LoginForm />, { wrapper });

    const alert = await screen.findByRole("alert");
    expect(alert).toHaveAttribute("data-tenant-status", status);
    expect(alert.textContent).toMatch(copy);

    // Not a disabled button — no submission path may exist at all.
    expect(screen.queryByLabelText("Username")).not.toBeInTheDocument();
    expect(screen.queryByLabelText("Password")).not.toBeInTheDocument();
    expect(screen.queryByRole("button", { name: /sign in/i })).not.toBeInTheDocument();
    expect(container.querySelector("form")).toBeNull();
    expectNoTenantInputAndNoUuid(container);
  });

  it("distinguishes a failed lookup from an unrecognized address", async () => {
    startSignedOut();
    server.use(tenantUnknown());
    const unknownRender = render(<LoginForm />, { wrapper });
    const unknownCopy = (await screen.findByRole("alert")).textContent;
    unknownRender.unmount();

    server.use(tenantLookupFails());
    render(<LoginForm />, { wrapper });
    const errorCopy = (await screen.findByRole("alert")).textContent;

    // Telling a user their address is wrong because the API blinked is a misdiagnosis
    // they cannot act on, so the two must never share copy.
    expect(errorCopy).not.toBe(unknownCopy);
  });
});

describe("LoginForm — credentials", () => {
  it("renders a distinct message per error code", async () => {
    startSignedOut();
    server.use(
      http.post(`${API_BASE_URL}/api/v1/auth/login`, () => errorShapeB("/api/v1/auth/login", 30)),
    );

    render(<LoginForm />, { wrapper });
    await signIn(VALID_USERNAME, VALID_PASSWORD);

    const alert = await screen.findByRole("alert");
    expect(alert).toHaveAttribute("data-error-code", "rate_limit_exceeded");
    // The countdown is the point of FR-021: "too many attempts" without a number is
    // indistinguishable from a generic failure.
    expect(alert).toHaveTextContent(/30 seconds/);
  });

  it("never reveals which credential was wrong", async () => {
    startSignedOut();
    render(<LoginForm />, { wrapper });

    await signIn(VALID_USERNAME, "definitely-wrong");

    const alert = await screen.findByRole("alert");
    expect(alert).toHaveAttribute("data-error-code", "invalid_credentials");
    const text = alert.textContent?.toLowerCase() ?? "";
    expect(text).toContain("username or password");
    expect(text).not.toMatch(/unknown user|no such user|user not found|wrong password/);
  });

  it("surfaces an address that stopped resolving between page load and submit", async () => {
    startSignedOut();
    // The page resolved fine; by submit time the address no longer does. The user must not
    // be told their password is wrong for something that is not about their password.
    server.use(
      http.post(`${API_BASE_URL}/api/v1/auth/login`, () =>
        errorShapeA(400, "Bad Request", "unknown_tenant_address", "/api/v1/auth/login"),
      ),
    );

    render(<LoginForm />, { wrapper });
    await signIn(VALID_USERNAME, VALID_PASSWORD);

    const alert = await screen.findByRole("alert");
    expect(alert).toHaveAttribute("data-error-code", "unknown_tenant_address");
    expect(alert.textContent?.toLowerCase()).not.toContain("username or password");
  });

  it("surfaces an inactive tenant at submit time distinctly from bad credentials", async () => {
    startSignedOut();
    server.use(
      http.post(`${API_BASE_URL}/api/v1/auth/login`, () =>
        errorShapeA(403, "Forbidden", "tenant_inactive", "/api/v1/auth/login"),
      ),
    );

    render(<LoginForm />, { wrapper });
    await signIn(VALID_USERNAME, VALID_PASSWORD);

    const alert = await screen.findByRole("alert");
    expect(alert).toHaveAttribute("data-error-code", "tenant_inactive");
  });

  it("labels a server-side 400 as a validation error, not as bad credentials", async () => {
    startSignedOut();
    server.use(
      http.post(`${API_BASE_URL}/api/v1/auth/login`, () =>
        errorShapeA(400, "Bad Request", "Username cannot be blank", "/api/v1/auth/login"),
      ),
    );

    render(<LoginForm />, { wrapper });
    await signIn(VALID_USERNAME, VALID_PASSWORD);

    const alert = await screen.findByRole("alert");
    expect(alert).toHaveAttribute("data-error-code", "validation_error");
    expect(alert).toHaveTextContent("Username cannot be blank");
  });

  it("blocks the request entirely when client-side validation fails", async () => {
    startSignedOut();
    let loginCalls = 0;
    server.use(
      http.post(`${API_BASE_URL}/api/v1/auth/login`, () => {
        loginCalls += 1;
        return errorShapeA(401, "Unauthorized", "Invalid credentials", "/api/v1/auth/login");
      }),
    );

    render(<LoginForm />, { wrapper });
    await signIn("ab", "short");

    expect(await screen.findByText(/between 3 and 50 characters/)).toBeInTheDocument();
    expect(screen.getByText(/at least 8 characters/)).toBeInTheDocument();
    expect(loginCalls).toBe(0);
  });

  it("calls onSuccess and clears the password field after signing in", async () => {
    startSignedOut();
    let succeeded = false;

    render(<LoginForm onSuccess={() => (succeeded = true)} />, { wrapper });
    await signIn(VALID_USERNAME, VALID_PASSWORD);

    await waitFor(() => expect(succeeded).toBe(true));
    expect(screen.getByLabelText("Password")).toHaveValue("");
    expect(screen.queryByRole("alert")).not.toBeInTheDocument();
  });
});
