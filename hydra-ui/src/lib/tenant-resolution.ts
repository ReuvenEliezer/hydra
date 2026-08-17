import { ApiError } from "../types/errors";
import { errorFromResponse, networkError } from "./normalize-error";

/**
 * The load-time tenant lookup.
 *
 * The address the page is served from is what identifies the organization, and the server
 * reads it from the `Host` of THIS request — not of the page. So `apiBaseUrl` must point at
 * the same tenant host the page is on (`https://acme.example.com`, or
 * `http://acme.localhost:8083` in development). Pointing it at a hostless origin such as
 * `http://localhost:8083` makes every lookup return `unknown` and every login fail closed,
 * with a UI that looks entirely correct. This is the one way a consumer can silently break
 * the feature.
 */

/** What the server can say about an address. Mirrors `TenantResolutionResponse`. */
export type ResolvedTenantStatus = "recognized" | "inactive" | "unknown";

export interface TenantResolutionResult {
  status: ResolvedTenantStatus;
  /** The organization's name. Present only when `status === "recognized"`. */
  displayName: string | null;
}

interface TenantResolutionBody {
  status?: unknown;
  displayName?: unknown;
}

const RESOLVED_STATUSES: readonly string[] = ["recognized", "inactive", "unknown"];

/**
 * Fetches `GET /api/v1/tenant` unauthenticated.
 *
 * Every failure of the lookup ITSELF — network, 5xx, 429, an unparseable or unrecognized
 * body — throws rather than resolving to `unknown`. Collapsing them would tell a user their
 * address is unrecognized because the API was briefly unreachable: a wrong diagnosis, and one
 * they cannot act on. The caller renders those as a distinct, retryable state.
 */
export async function fetchTenantResolution(
  apiBaseUrl: string,
  signal?: AbortSignal,
): Promise<TenantResolutionResult> {
  const base = apiBaseUrl.endsWith("/") ? apiBaseUrl.slice(0, -1) : apiBaseUrl;

  let response: Response;
  try {
    response = await globalThis.fetch(`${base}/api/v1/tenant`, {
      method: "GET",
      headers: { Accept: "application/json" },
      signal,
    });
  } catch (cause) {
    throw networkError(cause);
  }

  if (!response.ok) throw await errorFromResponse(response);

  let body: TenantResolutionBody;
  try {
    body = (await response.json()) as TenantResolutionBody;
  } catch (cause) {
    throw new ApiError({
      code: "server_error",
      message: "The sign-in service returned an unreadable response.",
      status: response.status,
      cause,
    });
  }

  const status = body.status;
  if (typeof status !== "string" || !RESOLVED_STATUSES.includes(status)) {
    throw new ApiError({
      code: "server_error",
      message: "The sign-in service returned an unrecognized response.",
      status: response.status,
    });
  }

  // displayName is authorized only on `recognized`; anywhere else it is dropped rather than
  // trusted, so a server that over-shares cannot leak an inactive organization's name.
  const displayName =
    status === "recognized" && typeof body.displayName === "string" && body.displayName.length > 0
      ? body.displayName
      : null;

  return { status: status as ResolvedTenantStatus, displayName };
}
