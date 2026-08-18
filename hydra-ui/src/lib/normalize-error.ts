import { ApiError, type ApiErrorCode } from "../types/errors";

/**
 * Turns any backend failure into one `ApiError`.
 *
 * There are FOUR producers on the backend, verified in source, and they do not agree
 * on where the machine-readable code lives:
 *
 *  A. `GlobalExceptionHandler` (both services) — `{status, error, message, path, timestamp}`
 *     where `error` is the HTTP reason phrase and the CODE IS IN `message`
 *     (e.g. `"invalid_refresh_token"`, `"refresh_token_reuse_detected"`).
 *  B. `RateLimitExceptionHandler` — same record, opposite convention: the CODE IS IN
 *     `error` (`"rate_limit_exceeded"`) and `message` holds human text. Plus a
 *     `Retry-After` header.
 *  C. Spring Security's entry points (`res.sendError`) — Boot's default `/error`
 *     attributes `{timestamp, status, error, path}` with NO `message` field at all
 *     (`server.error.include-message` is not enabled). This is what an expired access
 *     token looks like, i.e. the single most common error path in the whole package.
 *  D. `AuthController.refresh` with no cookie — a `@JsonInclude(NON_NULL)` `AuthResponse`
 *     that serializes to just `{"message": "invalid_refresh_token"}`; no status, no path.
 *
 * Resolution order is therefore: `body.error` (B) → `body.message` (A, D) → status (C).
 * `status` always comes from the response object, never the body.
 */

/** Codes the backend actually emits as literal strings. Kept explicit so a typo'd
 *  comparison can't silently fall through to the status-derived branch. */
const WIRE_CODES = new Set<string>([
  "invalid_refresh_token",
  "refresh_token_reuse_detected",
  "rate_limit_exceeded",
  // Shape A again, from the login path. Both arrive in `message`, and both MUST beat the
  // status-derived fallback: 400 would otherwise read as a validation error and 403 as a
  // permission denial, neither of which describes what actually happened.
  "unknown_tenant_address",
  "tenant_inactive",
]);

/**
 * Shape A's `BadCredentialsException` handler returns the literal human string
 * "Invalid credentials" in `message` rather than a machine code, so it needs its own
 * match to avoid being lumped in with the status-derived fallback.
 */
const INVALID_CREDENTIALS_MESSAGE = "invalid credentials";

const DEFAULT_MESSAGES: Record<ApiErrorCode, string> = {
  invalid_credentials: "Incorrect username or password.",
  unknown_tenant_address:
    "This web address isn't recognized. Check the address you used, or ask your administrator for the correct sign-in link.",
  tenant_inactive:
    "This organization's account is currently inactive, so sign-in is unavailable. Please contact your administrator.",
  invalid_refresh_token: "Your session has expired. Please sign in again.",
  refresh_token_reuse_detected: "Your session was ended for security reasons. Please sign in again.",
  rate_limit_exceeded: "Too many attempts. Please wait a moment and try again.",
  validation_error: "Some of the details you entered are not valid.",
  business_rule_violation: "That action is not allowed for this record.",
  permission_denied: "You do not have permission to do that.",
  not_found: "We couldn't find what you were looking for.",
  network_error: "We couldn't reach the server. Check your connection and try again.",
  server_error: "Something went wrong on our end. Please try again.",
};

/** Minimal view of a `Response` — keeps this function testable with a plain object. */
export interface ErrorResponseLike {
  status: number;
  headers: { get(name: string): string | null };
}

interface WireErrorBody {
  status?: unknown;
  error?: unknown;
  message?: unknown;
  path?: unknown;
}

function statusDerivedCode(status: number): ApiErrorCode {
  if (status === 400) return "validation_error";
  // Shape C's 401 carries no code. `invalid_credentials` is the status-derived default
  // per data-model.md; on the authenticated paths this error is consumed by the
  // refresh-and-retry logic and never reaches the user, so the label only surfaces on
  // the login call, where it is exactly right.
  if (status === 401) return "invalid_credentials";
  if (status === 403) return "permission_denied";
  if (status === 404) return "not_found";
  if (status === 422) return "business_rule_violation";
  if (status === 429) return "rate_limit_exceeded";
  return "server_error";
}

function asString(value: unknown): string | undefined {
  return typeof value === "string" && value.length > 0 ? value : undefined;
}

function resolveCode(status: number, body: WireErrorBody): ApiErrorCode {
  const error = asString(body.error);
  if (error && WIRE_CODES.has(error)) return error as ApiErrorCode;

  const message = asString(body.message);
  if (message) {
    if (WIRE_CODES.has(message)) return message as ApiErrorCode;
    if (message.toLowerCase() === INVALID_CREDENTIALS_MESSAGE) return "invalid_credentials";
  }

  return statusDerivedCode(status);
}

function resolveMessage(code: ApiErrorCode, body: WireErrorBody): string {
  const message = asString(body.message);
  // When `message` IS the machine code (shapes A and D) it is not display text.
  //
  // "Invalid credentials" is the same kind of sentinel even though it reads like prose:
  // `resolveCode` already treats it as shape A's stand-in for a machine code, and letting it
  // through here would mean the two functions disagree about what it is - the code says
  // `invalid_credentials` while the text shown is the backend's raw wording rather than the
  // deliberately non-revealing copy in DEFAULT_MESSAGES.
  const isSentinel =
    message && (WIRE_CODES.has(message) || message.toLowerCase() === INVALID_CREDENTIALS_MESSAGE);
  if (message && !isSentinel) return message;

  // Shape B puts the human text in `message` and the code in `error`, so the branch
  // above already covered it. Anything left is shape C or a code-only body.
  return DEFAULT_MESSAGES[code];
}

function parseRetryAfter(headers: ErrorResponseLike["headers"]): number | undefined {
  const raw = headers.get("Retry-After");
  if (raw === null) return undefined;
  const seconds = Number.parseInt(raw, 10);
  return Number.isFinite(seconds) && seconds >= 0 ? seconds : undefined;
}

/**
 * Pure mapping step: response metadata + already-parsed body in, `ApiError` out.
 * Separated from the I/O so tests can assert on each wire shape without a fetch.
 */
export function normalizeError(response: ErrorResponseLike, body: unknown): ApiError {
  const wireBody: WireErrorBody =
    body !== null && typeof body === "object" ? (body as WireErrorBody) : {};

  const code = resolveCode(response.status, wireBody);
  const retryAfterSeconds =
    code === "rate_limit_exceeded" ? parseRetryAfter(response.headers) : undefined;

  return new ApiError({
    code,
    message: resolveMessage(code, wireBody),
    status: response.status,
    path: asString(wireBody.path),
    retryAfterSeconds,
  });
}

/**
 * Reads the body off a real `Response` and normalizes it. Tolerates a body that is
 * empty (204-style), non-JSON, or HTML — the security filter chain can return an HTML
 * error page if content negotiation goes wrong, and a parse failure must not mask the
 * real HTTP status.
 */
export async function errorFromResponse(response: Response): Promise<ApiError> {
  let body: unknown = null;
  try {
    const text = await response.text();
    if (text.length > 0) body = JSON.parse(text);
  } catch {
    body = null;
  }
  return normalizeError(response, body);
}

/** A transport-level failure: `fetch` rejected, so there is no status to read. */
export function networkError(cause: unknown): ApiError {
  return new ApiError({
    code: "network_error",
    message: DEFAULT_MESSAGES.network_error,
    status: 0,
    cause,
  });
}

export { DEFAULT_MESSAGES };
