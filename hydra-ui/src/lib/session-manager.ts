import { decodeAccessTokenClaims } from "./decode-claims";
import { errorFromResponse, networkError } from "./normalize-error";
import { ApiError } from "../types/errors";
import type { SessionState, SessionStatus, SessionUser } from "../types/session";

/**
 * Owns the access token and the session state machine.
 *
 * Created PER `HydraProvider`, never as a module singleton: a singleton leaks session
 * state between tests and breaks any app that mounts more than one provider (two
 * tenants side by side, a preview pane, Storybook stories on one page).
 *
 * The access token lives only in the closure below — never localStorage, never
 * sessionStorage, never a JS-readable cookie (FR-006). The refresh token is never
 * touched by this code at all: it is an httpOnly cookie scoped to `/api/v1/auth`, and
 * the browser attaches it automatically because every auth request sets
 * `credentials: "include"`.
 */

const AUTH_BASE_PATH = "/api/v1/auth";

export interface SessionManagerOptions {
  apiBaseUrl: string;
  /** Injectable for tests; defaults to the global `fetch`. */
  fetchImpl?: typeof fetch;
  /** Injectable so the 429 back-off is deterministic under fake timers. */
  sleep?: (ms: number) => Promise<void>;
}

export interface SessionManager {
  getState(): SessionState;
  subscribe(listener: () => void): () => void;
  /** In-memory access token, or null when there is no live session. */
  getAccessToken(): string | null;
  /** Adopts a freshly issued access token (login, or a successful refresh). */
  adoptAccessToken(token: string): void;
  /**
   * One silent refresh at provider mount, used to rehydrate the in-memory token from
   * the httpOnly cookie after a page reload (FR-003). Never throws.
   */
  restoreSession(): Promise<void>;
  /**
   * Renews the access token. Concurrent callers share ONE in-flight request (FR-005):
   * the first caller issues `POST /api/v1/auth/refresh`, everyone else awaits the same
   * promise and then retries with whatever token it produced.
   *
   * Resolves to the new token, or `null` when the session is dead and the caller
   * should surface a signed-out state. Rejects only for retryable transport failures.
   */
  refresh(): Promise<string | null>;
  /** Clears state immediately and cancels/ignores any in-flight or scheduled refresh. */
  clear(status?: Extract<SessionStatus, "anonymous" | "expired">): void;
}

const ANONYMOUS: SessionState = { status: "anonymous", user: null };

export function createSessionManager(options: SessionManagerOptions): SessionManager {
  const { apiBaseUrl } = options;
  const doFetch: typeof fetch = options.fetchImpl ?? ((...args) => globalThis.fetch(...args));
  const sleep =
    options.sleep ?? ((ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms)));

  let accessToken: string | null = null;
  let state: SessionState = ANONYMOUS;
  const listeners = new Set<() => void>();

  /**
   * Bumped by `clear()`. Any refresh that started before the bump discards its result
   * instead of resurrecting a session the user has already signed out of (FR-007) —
   * this is what makes "no further requests happen on their behalf" actually hold when
   * sign-out lands while a refresh is already in flight.
   */
  let generation = 0;
  let inFlight: Promise<string | null> | null = null;
  let abortController: AbortController | null = null;

  function emit(): void {
    for (const listener of listeners) listener();
  }

  function setState(next: SessionState): void {
    // Object identity is the change signal for useSyncExternalStore, so only replace it
    // when something actually differs.
    if (next.status === state.status && next.user === state.user) return;
    state = next;
    emit();
  }

  function setStatus(status: SessionStatus): void {
    setState({ status, user: state.user });
  }

  function userFromToken(token: string): SessionUser | null {
    const claims = decodeAccessTokenClaims(token);
    if (claims === null) return null;
    return { id: claims.userId, tenantId: claims.tenantId, roles: claims.roles };
  }

  function adoptAccessToken(token: string): void {
    accessToken = token;
    setState({ status: "authenticated", user: userFromToken(token) });
  }

  function clear(status: Extract<SessionStatus, "anonymous" | "expired"> = "anonymous"): void {
    generation += 1;
    accessToken = null;
    inFlight = null;
    abortController?.abort();
    abortController = null;
    setState({ status, user: null });
  }

  async function requestRefresh(signal: AbortSignal): Promise<Response> {
    try {
      return await doFetch(`${apiBaseUrl}${AUTH_BASE_PATH}/refresh`, {
        method: "POST",
        // The httpOnly refresh cookie rides along only because of this; without it the
        // browser sends nothing and every session dies at access-token expiry.
        credentials: "include",
        // The security filter chain can answer with an HTML error page otherwise.
        headers: { Accept: "application/json" },
        signal,
      });
    } catch (cause) {
      throw networkError(cause);
    }
  }

  /**
   * One refresh attempt plus, for a 429 only, one delayed retry.
   *
   * The 401-vs-429 split is the important part: a 401 means the renewal credential is
   * genuinely dead, so sign out cleanly and never retry (FR-008, and retrying would
   * loop). A 429 means the endpoint is throttled but the session is FINE — signing the
   * user out there would drop sessions under load and lose their work (FR-021).
   */
  async function performRefresh(myGeneration: number): Promise<string | null> {
    const controller = new AbortController();
    abortController = controller;

    let response = await requestRefresh(controller.signal);

    if (response.status === 429) {
      const rateLimited = await errorFromResponse(response);
      if (myGeneration !== generation) return null;
      await sleep(Math.max(1, rateLimited.retryAfterSeconds ?? 1) * 1000);
      if (myGeneration !== generation) return null;
      response = await requestRefresh(controller.signal);
    }

    if (myGeneration !== generation) return null;

    if (!response.ok) {
      const error = await errorFromResponse(response);
      if (myGeneration !== generation) return null;

      if (error.status === 401) {
        // Forced sign-out: state cleared, nothing scheduled, nothing retried.
        clear("expired");
        return null;
      }
      // 429 twice over, 5xx, or anything else: the session is not proven dead, so keep
      // it and let the caller decide how to surface a retryable failure.
      setStatus("authenticated");
      throw error;
    }

    const body = (await response.json()) as { token?: unknown };
    if (myGeneration !== generation) return null;

    if (typeof body.token !== "string" || body.token.length === 0) {
      setStatus("authenticated");
      throw new ApiError({
        code: "server_error",
        message: "The server did not return a new access token.",
        status: response.status,
      });
    }

    adoptAccessToken(body.token);
    return body.token;
  }

  function refresh(): Promise<string | null> {
    // The coalescing point: while a refresh is pending every other caller gets the same
    // promise, so N simultaneously-expired requests produce exactly ONE network call
    // (FR-005, SC-005).
    if (inFlight !== null) return inFlight;

    const myGeneration = generation;
    setStatus(state.status === "authenticated" ? "refreshing" : "authenticating");

    const pending = performRefresh(myGeneration).finally(() => {
      if (inFlight === pending) {
        inFlight = null;
        abortController = null;
      }
    });
    inFlight = pending;
    return pending;
  }

  async function restoreSession(): Promise<void> {
    setStatus("authenticating");
    try {
      const token = await refresh();
      if (token === null && state.status !== "authenticated") {
        // No cookie, or an invalid one: a first-time visitor, not an error to show.
        setState(ANONYMOUS);
      }
    } catch {
      // A backend that is down at page load must not look like "signed out" — but there
      // is also no session to keep, so settle on anonymous without surfacing an error
      // the user did not ask for.
      setState(ANONYMOUS);
    }
  }

  return {
    getState: () => state,
    subscribe(listener) {
      listeners.add(listener);
      return () => listeners.delete(listener);
    },
    getAccessToken: () => accessToken,
    adoptAccessToken,
    restoreSession,
    refresh,
    clear,
  };
}
