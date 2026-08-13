import { useCallback, useState } from "react";
import { useHydraContext } from "../components/HydraProvider";
import { useSession } from "./useSession";
import { ApiError } from "../types/errors";
import type { Account, RegisterInput, RegisterResponseBody } from "../types/account";

export interface UseRegisterUserResult {
  registerUser: (input: RegisterInput) => Promise<Account>;
  isPending: boolean;
  error: ApiError | null;
  reset: () => void;
}

/**
 * Wraps `POST /api/v1/admin/register-user` (FR-016). Requires `ROLE_ADMIN` or above.
 *
 * The new account always lands in the CALLER'S tenant: `AuthService.registerUser` reads
 * the tenant off the authenticated principal and explicitly refuses to touch another
 * one. There is deliberately no tenant parameter here for that reason.
 */
export function useRegisterUser(): UseRegisterUserResult {
  const { httpClient } = useHydraContext();
  const { user } = useSession();
  const [isPending, setIsPending] = useState(false);
  const [error, setError] = useState<ApiError | null>(null);

  const registerUser = useCallback(
    async (input: RegisterInput): Promise<Account> => {
      setIsPending(true);
      setError(null);
      try {
        const body = await httpClient.request<RegisterResponseBody>(
          "/api/v1/admin/register-user",
          { method: "POST", body: input },
        );
        return {
          id: body.userId,
          username: input.username,
          // Echoed from the session, not the response — the server does not send it back.
          tenantId: user?.tenantId ?? "",
          role: "ROLE_USER",
        };
      } catch (caught) {
        if (caught instanceof ApiError) setError(caught);
        throw caught;
      } finally {
        setIsPending(false);
      }
    },
    [httpClient, user],
  );

  const reset = useCallback(() => setError(null), []);

  return { registerUser, isPending, error, reset };
}
