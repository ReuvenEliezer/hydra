import { useState, type FormEvent } from "react";
import { useHydraContext } from "../HydraProvider";
import { useLogin } from "../../hooks/useLogin";
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
  title?: string;
  description?: string;
  onSuccess?: () => void;
  /**
   * Pre-fills the Tenant ID field; the user can still edit it before submitting.
   * Defaults to the `HydraProvider`-level `tenantId` when omitted. Temporary: once
   * tenant is resolved from the URL (subdomain) instead of typed in, this field and
   * prop go away.
   */
  defaultTenantId?: string;
}

/**
 * Note on the error copy: every failure mode renders its own message EXCEPT the one
 * that must not. A wrong username and a wrong password both come back as
 * `invalid_credentials` and both render "Incorrect username or password" — the backend
 * deliberately collapses them (`AuthService.login` throws the same
 * `BadCredentialsException` for an unknown user, an inactive user, and a bad password)
 * to prevent username enumeration, and the UI must not undo that by hinting at which
 * one was wrong.
 */
export function LoginForm({
  className,
  title = "Sign in",
  description,
  onSuccess,
  defaultTenantId,
}: LoginFormProps) {
  const { login, isPending, error } = useLogin();
  const { tenantId: providerTenantId } = useHydraContext();
  const [tenantId, setTenantId] = useState(defaultTenantId ?? providerTenantId);
  const [username, setUsername] = useState("");
  const [password, setPassword] = useState("");
  const [fieldErrors, setFieldErrors] = useState<CredentialErrors>({});
  const [tenantIdError, setTenantIdError] = useState<string | null>(null);

  async function handleSubmit(event: FormEvent<HTMLFormElement>): Promise<void> {
    event.preventDefault();
    const errors = validateCredentials(username, password);
    setFieldErrors(errors);
    const tenantError = tenantId.trim().length === 0 ? "Tenant ID cannot be blank" : null;
    setTenantIdError(tenantError);
    // No request at all until the input is well-formed (FR-019).
    if (hasCredentialErrors(errors) || tenantError !== null) return;

    try {
      await login(username, password, tenantId);
      setPassword("");
      onSuccess?.();
    } catch {
      // `useLogin` already exposes the typed error; rethrowing would surface an
      // unhandled rejection for a failure the form is about to render.
    }
  }

  const retryAfter = error?.retryAfterSeconds;

  return (
    <Card title={title} description={description} className={cn("w-full max-w-sm", className)}>
      <form className="flex flex-col gap-4" onSubmit={handleSubmit} noValidate>
        <Input
          label="Tenant ID"
          name="tenantId"
          value={tenantId}
          onChange={(event) => setTenantId(event.target.value)}
          error={tenantIdError}
          disabled={isPending}
        />
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
            className="bg-danger-surface text-danger rounded-(--radius-control) px-3 py-2 text-sm"
          >
            {error.message}
            {error.code === "rate_limit_exceeded" && retryAfter !== undefined
              ? ` Try again in ${retryAfter} second${retryAfter === 1 ? "" : "s"}.`
              : ""}
          </p>
        )}

        <Button type="submit" isPending={isPending} className="w-full">
          {isPending ? "Signing in…" : "Sign in"}
        </Button>
      </form>
    </Card>
  );
}
