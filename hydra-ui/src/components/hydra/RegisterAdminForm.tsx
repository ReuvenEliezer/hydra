import { useState, type FormEvent } from "react";
import { useRegisterAdmin } from "../../hooks/useRegisterAdmin";
import { cn } from "../../lib/cn";
import {
  hasCredentialErrors,
  validateCredentials,
  PASSWORD_MAX_LENGTH,
  PASSWORD_MIN_LENGTH,
  USERNAME_MAX_LENGTH,
  USERNAME_MIN_LENGTH,
  type CredentialErrors,
} from "../../lib/credential-validation";
import type { Account } from "../../types/account";
import { Button } from "../ui/Button";
import { Card } from "../ui/Card";
import { Input } from "../ui/Input";
import { RequireRole } from "./RequireRole";

export interface RegisterAdminFormProps {
  className?: string;
  /** Pre-fills the target tenant when the app already knows which one is in scope. */
  defaultTenantId?: string;
  onRegistered?: (account: Account) => void;
}

/**
 * Wrapped in `RequireRole("ROLE_SUPER_ADMIN")` per FR-018 — an ordinary admin does not
 * see this form at all, and since the whole form is unmounted for them there is no
 * submit path to reach either.
 *
 * The tenant is an explicit field because a super admin provisions admins across
 * tenants, so it cannot be inferred from their own session the way `RegisterUserForm`
 * does.
 */
export function RegisterAdminForm({
  className,
  defaultTenantId = "",
  onRegistered,
}: RegisterAdminFormProps) {
  const { registerAdmin, isPending, error } = useRegisterAdmin();
  const [tenantId, setTenantId] = useState(defaultTenantId);
  const [username, setUsername] = useState("");
  const [password, setPassword] = useState("");
  const [fieldErrors, setFieldErrors] = useState<CredentialErrors>({});
  const [tenantError, setTenantError] = useState<string | null>(null);
  const [createdUsername, setCreatedUsername] = useState<string | null>(null);

  async function handleSubmit(event: FormEvent<HTMLFormElement>): Promise<void> {
    event.preventDefault();
    setCreatedUsername(null);

    const errors = validateCredentials(username, password);
    setFieldErrors(errors);
    const missingTenant = tenantId.trim().length === 0 ? "Tenant is required" : null;
    setTenantError(missingTenant);
    if (hasCredentialErrors(errors) || missingTenant !== null) return;

    try {
      const account = await registerAdmin(tenantId.trim(), { username, password });
      setCreatedUsername(account.username);
      setUsername("");
      setPassword("");
      onRegistered?.(account);
    } catch {
      // Rendered from the hook's `error`.
    }
  }

  return (
    <RequireRole role="ROLE_SUPER_ADMIN">
      <Card
        title="Add a tenant admin"
        description="Creates an administrator for the chosen tenant."
        className={cn("w-full max-w-sm", className)}
      >
        <form className="flex flex-col gap-4" onSubmit={handleSubmit} noValidate>
          <Input
            label="Tenant ID"
            name="tenantId"
            autoComplete="off"
            value={tenantId}
            onChange={(event) => setTenantId(event.target.value)}
            error={tenantError}
            disabled={isPending}
          />
          <Input
            label="Username"
            name="username"
            autoComplete="off"
            hint={`${USERNAME_MIN_LENGTH}–${USERNAME_MAX_LENGTH} characters`}
            value={username}
            onChange={(event) => setUsername(event.target.value)}
            error={fieldErrors.username ?? null}
            disabled={isPending}
          />
          <Input
            label="Password"
            name="password"
            type="password"
            autoComplete="new-password"
            hint={`${PASSWORD_MIN_LENGTH}–${PASSWORD_MAX_LENGTH} characters`}
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
            </p>
          )}

          {createdUsername !== null && (
            <p role="status" className="text-success text-sm">
              Created admin “{createdUsername}”.
            </p>
          )}

          <Button type="submit" isPending={isPending}>
            {isPending ? "Creating…" : "Create admin"}
          </Button>
        </form>
      </Card>
    </RequireRole>
  );
}
