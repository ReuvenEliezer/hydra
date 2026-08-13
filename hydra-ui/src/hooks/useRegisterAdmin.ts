import { useCallback, useState } from "react";
import { useHydraContext } from "../components/HydraProvider";
import { ApiError } from "../types/errors";
import type { Account, RegisterInput, RegisterResponseBody } from "../types/account";

export interface UseRegisterAdminResult {
  registerAdmin: (tenantId: string, input: RegisterInput) => Promise<Account>;
  isPending: boolean;
  error: ApiError | null;
  reset: () => void;
}

/**
 * Wraps `POST /api/v1/admin/{tenantId}/register-admin` (FR-017, FR-018).
 * Requires `ROLE_SUPER_ADMIN` — an ordinary admin gets a 403.
 *
 * Unlike `register-user`, the tenant is an explicit path parameter here: a super admin
 * provisions admins ACROSS tenants, so the target cannot be inferred from their own
 * session. A tenant that does not exist or is inactive comes back as a 404/422 rather
 * than a validation error.
 */
export function useRegisterAdmin(): UseRegisterAdminResult {
  const { httpClient } = useHydraContext();
  const [isPending, setIsPending] = useState(false);
  const [error, setError] = useState<ApiError | null>(null);

  const registerAdmin = useCallback(
    async (tenantId: string, input: RegisterInput): Promise<Account> => {
      setIsPending(true);
      setError(null);
      try {
        const body = await httpClient.request<RegisterResponseBody>(
          `/api/v1/admin/${tenantId}/register-admin`,
          { method: "POST", body: input },
        );
        return {
          id: body.userId,
          username: input.username,
          tenantId,
          role: "ROLE_ADMIN",
        };
      } catch (caught) {
        if (caught instanceof ApiError) setError(caught);
        throw caught;
      } finally {
        setIsPending(false);
      }
    },
    [httpClient],
  );

  const reset = useCallback(() => setError(null), []);

  return { registerAdmin, isPending, error, reset };
}
