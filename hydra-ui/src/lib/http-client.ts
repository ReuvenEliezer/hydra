import { errorFromResponse, networkError } from "./normalize-error";
import type { SessionManager } from "./session-manager";

/**
 * The one place a network request is made (apart from the session manager's own refresh
 * call, which cannot go through here without a cycle).
 *
 * Two header rules are load-bearing and easy to get wrong in opposite directions:
 *
 *  - `X-Tenant-ID` goes on the LOGIN request ONLY. `AuthController.login` declares
 *    `@RequestHeader(Headers.TENANT_ID)` with no default, so omitting it is a 400
 *    before credentials are even checked. Every other endpoint derives the tenant from
 *    the JWT `tenantId` claim server-side — order-service does not even allow the
 *    header through CORS, so sending it anyway would fail the preflight.
 *  - `Accept: application/json` goes on everything. The security filter chain forwards
 *    to Boot's `/error`, which will happily negotiate an HTML page if we do not say
 *    otherwise, and an HTML body is unparseable noise on the most common error path.
 */

export interface HttpClientOptions {
  apiBaseUrl: string;
  tenantId: string;
  sessionManager: SessionManager;
  fetchImpl?: typeof fetch;
}

export interface RequestOptions {
  method?: "GET" | "POST" | "PATCH" | "DELETE";
  /** JSON request body; omitted entirely when undefined. */
  body?: unknown;
  query?: Record<string, string | number | undefined>;
  /** Attach the bearer token and refresh-and-retry once on 401. Default true. */
  authenticated?: boolean;
  /** Send `X-Tenant-ID`. Login only. Default false. */
  sendTenantHeader?: boolean;
  /**
   * Overrides the provider-level tenant for this request only. Login collects tenant
   * per-submission (see `LoginForm`) rather than trusting a single value baked in at
   * `HydraProvider` mount, so this is normally set on every login call; falls back to
   * the provider's `tenantId` when omitted.
   */
  tenantId?: string;
  signal?: AbortSignal;
}

export interface HttpClient {
  request<T>(path: string, options?: RequestOptions): Promise<T>;
}

function buildUrl(
  apiBaseUrl: string,
  path: string,
  query: RequestOptions["query"],
): string {
  const base = apiBaseUrl.endsWith("/") ? apiBaseUrl.slice(0, -1) : apiBaseUrl;
  const search = new URLSearchParams();
  for (const [key, value] of Object.entries(query ?? {})) {
    if (value !== undefined) search.append(key, String(value));
  }
  const queryString = search.toString();
  return `${base}${path}${queryString.length > 0 ? `?${queryString}` : ""}`;
}

async function parseBody<T>(response: Response): Promise<T> {
  // 204 (logout, cancel-order) and any other empty body: there is nothing to parse and
  // callers type those as void.
  if (response.status === 204) return undefined as T;
  const text = await response.text();
  if (text.length === 0) return undefined as T;
  return JSON.parse(text) as T;
}

export function createHttpClient(options: HttpClientOptions): HttpClient {
  const { apiBaseUrl, tenantId, sessionManager } = options;
  const doFetch: typeof fetch = options.fetchImpl ?? ((...args) => globalThis.fetch(...args));

  async function send(
    path: string,
    requestOptions: RequestOptions,
    accessToken: string | null,
  ): Promise<Response> {
    const headers: Record<string, string> = { Accept: "application/json" };

    if (requestOptions.body !== undefined) headers["Content-Type"] = "application/json";
    if (requestOptions.sendTenantHeader === true) {
      headers["X-Tenant-ID"] = requestOptions.tenantId ?? tenantId;
    }
    if (accessToken !== null) headers["Authorization"] = `Bearer ${accessToken}`;

    const init: RequestInit = {
      method: requestOptions.method ?? "GET",
      headers,
      // Harmless on bearer-authenticated calls (the refresh cookie is path-scoped to
      // /api/v1/auth so it is not sent to order-service), and required on the auth
      // endpoints that do need it.
      credentials: "include",
    };
    if (requestOptions.body !== undefined) init.body = JSON.stringify(requestOptions.body);
    if (requestOptions.signal !== undefined) init.signal = requestOptions.signal;

    try {
      return await doFetch(buildUrl(apiBaseUrl, path, requestOptions.query), init);
    } catch (cause) {
      throw networkError(cause);
    }
  }

  async function request<T>(path: string, requestOptions: RequestOptions = {}): Promise<T> {
    const authenticated = requestOptions.authenticated !== false;
    const response = await send(
      path,
      requestOptions,
      authenticated ? sessionManager.getAccessToken() : null,
    );

    if (response.ok) return parseBody<T>(response);

    // A 401 on an authenticated call is the expected shape of "the access token just
    // expired". Renew once through the session manager — which coalesces, so twenty
    // simultaneous 401s still produce one refresh — and replay the request.
    if (response.status === 401 && authenticated) {
      const renewedToken = await sessionManager.refresh();
      if (renewedToken !== null) {
        const retried = await send(path, requestOptions, renewedToken);
        if (retried.ok) return parseBody<T>(retried);
        throw await errorFromResponse(retried);
      }
      // Refresh failed definitively: the session manager has already forced a clean
      // sign-out, so surface the original failure rather than retrying into a loop.
    }

    throw await errorFromResponse(response);
  }

  return { request };
}
