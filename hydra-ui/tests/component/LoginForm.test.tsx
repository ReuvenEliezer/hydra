import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { http } from "msw";
import { describe, expect, it } from "vitest";
import { LoginForm } from "../../src/components/hydra/LoginForm";
import { API_BASE_URL, VALID_PASSWORD, VALID_USERNAME, errorShapeA, errorShapeB } from "../mocks/handlers";
import { server } from "../mocks/server";
import { startSignedOut, wrapper } from "../test-utils";

async function signIn(username: string, password: string) {
  const user = userEvent.setup();
  await user.type(screen.getByLabelText("Username"), username);
  await user.type(screen.getByLabelText("Password"), password);
  await user.click(screen.getByRole("button", { name: /sign in/i }));
}

describe("LoginForm", () => {
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
