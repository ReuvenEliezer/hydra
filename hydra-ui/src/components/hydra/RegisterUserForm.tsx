import { useState, type FormEvent } from "react";
import { AlertCircle, CheckCircle2 } from "lucide-react";
import { useRegisterUser } from "../../hooks/useRegisterUser";
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

export interface RegisterUserFormProps {
  className?: string;
  onRegistered?: (account: Account) => void;
}

/**
 * Wrapped in `RequireRole("ROLE_ADMIN")` per FR-016. The new user is created in the
 * admin's own tenant — there is no tenant field because the server ignores any attempt
 * to specify one.
 */
export function RegisterUserForm({ className, onRegistered }: RegisterUserFormProps) {
  const { registerUser, isPending, error } = useRegisterUser();
  const [username, setUsername] = useState("");
  const [password, setPassword] = useState("");
  const [fieldErrors, setFieldErrors] = useState<CredentialErrors>({});
  const [createdUsername, setCreatedUsername] = useState<string | null>(null);

  async function handleSubmit(event: FormEvent<HTMLFormElement>): Promise<void> {
    event.preventDefault();
    setCreatedUsername(null);
    // Same bounds as LoginForm, mirroring RegisterRequest's own @Size constraints (FR-019).
    const errors = validateCredentials(username, password);
    setFieldErrors(errors);
    if (hasCredentialErrors(errors)) return;

    try {
      const account = await registerUser({ username, password });
      setCreatedUsername(account.username);
      setUsername("");
      setPassword("");
      onRegistered?.(account);
    } catch {
      // Rendered from the hook's `error`.
    }
  }

  return (
    <RequireRole role="ROLE_ADMIN">
      <Card
        title="Add a user"
        description="Creates a standard user in your tenant."
        className={cn("w-full max-w-md", className)}
      >
        <form className="flex flex-col gap-5" onSubmit={handleSubmit} noValidate>
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
              className="bg-danger-surface text-danger border-danger/30 flex items-start gap-2 rounded-(--radius-control) border px-3.5 py-3 text-sm font-medium"
            >
              <AlertCircle aria-hidden="true" className="mt-px size-4 shrink-0" />
              {error.message}
            </p>
          )}

          {createdUsername !== null && (
            <p
              role="status"
              className="bg-success-surface text-success border-success/30 flex items-center gap-2 rounded-(--radius-control) border px-3.5 py-3 text-sm font-medium"
            >
              <CheckCircle2 aria-hidden="true" className="size-4 shrink-0" />
              Created “{createdUsername}”.
            </p>
          )}

          <Button type="submit" isPending={isPending}>
            {isPending ? "Creating…" : "Create user"}
          </Button>
        </form>
      </Card>
    </RequireRole>
  );
}
