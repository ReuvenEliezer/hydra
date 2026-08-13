import { useCallback, useState } from "react";
import { useHydraContext } from "../components/HydraProvider";
import { ApiError, type AuthError } from "../types/errors";

interface LoginResponseBody {
  userId: string;
  token: string;
}

export interface UseLoginResult {
  /**
   * Resolves on success; throws a typed `AuthError` on failure.
   * `tenantId` overrides the `HydraProvider`-level default for this call only — omit it
   * to fall back to that default. `LoginForm` always supplies its own field's value.
   */
  login: (username: string, password: string, tenantId?: string) => Promise<void>;
  isPending: boolean;
  error: AuthError | null;
  reset: () => void;
}

/**
 * Wraps `POST /api/v1/auth/login`.
 *
 * The credentials go out in the request body and are never stored, echoed, or logged.
 * The refresh cookie the server sets in response is httpOnly, so it is never visible
 * here either — this hook only ever sees the access token, which goes straight into the
 * session manager's in-memory slot (FR-001, FR-002, FR-006).
 */
export function useLogin(): UseLoginResult {
  const { httpClient, sessionManager } = useHydraContext();
  const [isPending, setIsPending] = useState(false);
  const [error, setError] = useState<AuthError | null>(null);

  const login = useCallback(
    async (username: string, password: string, tenantId?: string) => {
      setIsPending(true);
      setError(null);
      try {
        const body = await httpClient.request<LoginResponseBody>("/api/v1/auth/login", {
          method: "POST",
          body: { username, password },
          // The one call that carries the tenant header, and the one call where a 401
          // means "wrong password" rather than "token expired" — so no refresh-retry.
          sendTenantHeader: true,
          tenantId,
          authenticated: false,
        });
        sessionManager.adoptAccessToken(body.token);
      } catch (caught) {
        const authError = (
          caught instanceof ApiError
            ? caught
            : new ApiError({ code: "server_error", message: "Sign-in failed.", status: 0 })
        ) as AuthError;
        setError(authError);
        throw authError;
      } finally {
        setIsPending(false);
      }
    },
    [httpClient, sessionManager],
  );

  const reset = useCallback(() => setError(null), []);

  return { login, isPending, error, reset };
}
