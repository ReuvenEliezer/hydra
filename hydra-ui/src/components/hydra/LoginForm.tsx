import { useState, type FormEvent } from "react";
import { AlertCircle, Loader2, ShieldAlert } from "lucide-react";
import { useLogin } from "../../hooks/useLogin";
import { useTenant } from "../../hooks/useTenant";
import { cn } from "../../lib/cn";
import {
  hasCredentialErrors,
  validateCredentials,
  type CredentialErrors,
} from "../../lib/credential-validation";
import { Button } from "../ui/Button";
import { Card } from "../ui/Card";
import { Input } from "../ui/Input";

export interface LoginFormProps {
  className?: string;
  /** Overrides the default heading, which otherwise names the resolved organization. */
  title?: string;
  description?: string;
  onSuccess?: () => void;
}

/**
 * Renders from the address the page was loaded at. There is no tenant input and no tenant
 * prop: the organization is whatever the sign-in address resolves to, and nothing the user
 * types can change it.
 *
 * The three failure states render NO FORM AT ALL — not a disabled submit button. A form that
 * can be filled in is a submission path, and a submission from an address that resolves to
 * nothing is exactly the misattribution this design exists to prevent. `error` gets its own
 * copy rather than reusing `unknown`: a briefly unreachable API is not a wrong address, and
 * telling the user it is sends them to fix something that is not broken.
 *
 * Note on the credential error copy: every failure mode renders its own message EXCEPT the
 * one that must not. A wrong username and a wrong password both come back as
 * `invalid_credentials` and both render "Incorrect username or password" — the backend
 * deliberately collapses them (`AuthService.login` throws the same `BadCredentialsException`
 * for an unknown user, an inactive user, and a bad password) to prevent username enumeration,
 * and the UI must not undo that by hinting at which one was wrong.
 */
export function LoginForm({ className, title, description, onSuccess }: LoginFormProps) {
  const { login, isPending, error } = useLogin();
  const tenant = useTenant();
  const [username, setUsername] = useState("");
  const [password, setPassword] = useState("");
  const [fieldErrors, setFieldErrors] = useState<CredentialErrors>({});

  async function handleSubmit(event: FormEvent<HTMLFormElement>): Promise<void> {
    event.preventDefault();
    const errors = validateCredentials(username, password);
    setFieldErrors(errors);
    // No request at all until the input is well-formed (FR-019).
    if (hasCredentialErrors(errors)) return;

    try {
      await login(username, password);
      setPassword("");
      onSuccess?.();
    } catch {
      // `useLogin` already exposes the typed error; rethrowing would surface an
      // unhandled rejection for a failure the form is about to render.
    }
  }

  if (tenant.status === "resolving") {
    return (
      <Card className={cn("w-full max-w-md", className)}>
        <p role="status" className="text-content-muted flex items-center gap-2 text-sm">
          <Loader2 aria-hidden="true" className="size-4 motion-safe:animate-spin" />
          Loading…
        </p>
      </Card>
    );
  }

  if (tenant.status !== "recognized") {
    return (
      <Card
        title={TENANT_PROBLEM_TITLES[tenant.status]}
        className={cn("w-full max-w-md", className)}
      >
        <p
          role="alert"
          data-tenant-status={tenant.status}
          className="text-content-muted flex items-start gap-2.5 text-sm"
        >
          <ShieldAlert aria-hidden="true" className="text-warning mt-px size-4 shrink-0" />
          {TENANT_PROBLEM_MESSAGES[tenant.status]}
        </p>
      </Card>
    );
  }

  const retryAfter = error?.retryAfterSeconds;
  const heading = title ?? `Sign in to ${tenant.displayName}`;

  return (
    <Card title={heading} description={description} className={cn("w-full max-w-md", className)}>
      <form className="flex flex-col gap-5" onSubmit={handleSubmit} noValidate>
        <Input
          label="Username"
          name="username"
          autoComplete="username"
          value={username}
          onChange={(event) => setUsername(event.target.value)}
          error={fieldErrors.username ?? null}
          disabled={isPending}
        />
        <Input
          label="Password"
          name="password"
          type="password"
          autoComplete="current-password"
          value={password}
          onChange={(event) => setPassword(event.target.value)}
          error={fieldErrors.password ?? null}
          disabled={isPending}
        />

        {error !== null && (
          <p
            role="alert"
            data-error-code={error.code}
            className="bg-danger-surface text-danger border-danger/30 flex items-start gap-2 rounded-(--radius-control) border px-3.5 py-3 text-sm font-medium"
          >
            <AlertCircle aria-hidden="true" className="mt-px size-4 shrink-0" />
            <span>
              {error.message}
            {error.code === "rate_limit_exceeded" && retryAfter !== undefined
              ? ` Try again in ${retryAfter} second${retryAfter === 1 ? "" : "s"}.`
              : ""}
            </span>
          </p>
        )}

        <Button type="submit" isPending={isPending} className="w-full">
          {isPending ? "Signing in…" : "Sign in"}
        </Button>
      </form>
    </Card>
  );
}

/** Three distinct situations, three distinct headings — never one shared "problem" state. */
const TENANT_PROBLEM_TITLES: Record<"inactive" | "unknown" | "error", string> = {
  unknown: "Address not recognized",
  inactive: "This organization is unavailable",
  error: "We couldn't load this page",
};

const TENANT_PROBLEM_MESSAGES: Record<"inactive" | "unknown" | "error", string> = {
  unknown:
    "This web address isn't recognized. Check the address you used, or ask your administrator for the correct sign-in link.",
  inactive:
    "This organization's account is currently inactive, so sign-in is unavailable. Please contact your administrator.",
  error:
    "We couldn't reach the sign-in service just now. Check your connection and reload the page to try again.",
};
