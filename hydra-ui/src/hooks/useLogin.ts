import { useCallback, useState } from "react";
import { useHydraContext } from "../components/HydraProvider";
import { ApiError, type AuthError } from "../types/errors";

interface LoginResponseBody {
  userId: string;
  token: string;
}

export interface UseLoginResult {
  /** Resolves on success; throws a typed `AuthError` on failure. */
  login: (username: string, password: string) => Promise<void>;
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
 *
 * Nothing tenant-related leaves the browser. The organization is decided entirely by the
 * address the request is sent to, so a caller cannot aim a credential at a tenant — which
 * is why `login` takes a username and a password and nothing else.
 */
export function useLogin(): UseLoginResult {
  const { httpClient, sessionManager } = useHydraContext();
  const [isPending, setIsPending] = useState(false);
  const [error, setError] = useState<AuthError | null>(null);

  const login = useCallback(
    async (username: string, password: string) => {
      setIsPending(true);
      setError(null);
      try {
        const body = await httpClient.request<LoginResponseBody>("/api/v1/auth/login", {
          method: "POST",
          body: { username, password },
          // The one call where a 401 means "wrong password" rather than "token expired",
          // so there is no refresh-and-retry to attempt.
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
