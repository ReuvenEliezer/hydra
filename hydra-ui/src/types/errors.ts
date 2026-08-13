/**
 * The single normalized error type every hook and component sees.
 *
 * The backend has four distinct error producers across three body layouts, and the
 * machine-readable code moves between the `error` and `message` fields depending on
 * which one responded (see data-model.md). Normalization happens once, in
 * `lib/normalize-error.ts`; nothing downstream of it ever touches a raw body.
 */
export type ApiErrorCode =
  | "invalid_credentials"
  | "invalid_refresh_token"
  | "refresh_token_reuse_detected"
  | "rate_limit_exceeded"
  | "validation_error"
  | "business_rule_violation"
  | "permission_denied"
  | "not_found"
  | "network_error"
  | "server_error";

export interface ApiErrorInit {
  code: ApiErrorCode;
  message: string;
  /** HTTP status, always read off the response object — bodies C and D omit or disagree. */
  status: number;
  path?: string;
  /** Present only for `rate_limit_exceeded`, parsed from the `Retry-After` header. */
  retryAfterSeconds?: number;
  cause?: unknown;
}

/**
 * A real `Error` subclass rather than a plain object, so hooks can both `throw` it and
 * expose it as their `error` value without the caller having to handle two shapes.
 * Narrow it with the `code` discriminant or the type guards below.
 */
export class ApiError extends Error {
  readonly code: ApiErrorCode;
  readonly status: number;
  readonly path: string | undefined;
  readonly retryAfterSeconds: number | undefined;

  constructor(init: ApiErrorInit) {
    super(init.message, init.cause === undefined ? undefined : { cause: init.cause });
    this.name = "ApiError";
    this.code = init.code;
    this.status = init.status;
    this.path = init.path;
    this.retryAfterSeconds = init.retryAfterSeconds;
  }
}

/** Client- or server-side input rejection (HTTP 400). */
export type ValidationError = ApiError & { code: "validation_error" };
/** The caller's role does not permit the action (HTTP 403). */
export type PermissionError = ApiError & { code: "permission_denied" };
/** A domain rule rejected an otherwise well-formed request (HTTP 422). */
export type BusinessRuleError = ApiError & { code: "business_rule_violation" };
/** Throttled (HTTP 429); carries `retryAfterSeconds` when the header was readable. */
export type RateLimitError = ApiError & { code: "rate_limit_exceeded" };

/** The subset of codes `useLogin` can surface. */
export type AuthError = ApiError & {
  code:
    | "invalid_credentials"
    | "validation_error"
    | "rate_limit_exceeded"
    | "network_error"
    | "server_error";
};

export function isApiError(value: unknown): value is ApiError {
  return value instanceof ApiError;
}

export function isValidationError(value: unknown): value is ValidationError {
  return isApiError(value) && value.code === "validation_error";
}

export function isPermissionError(value: unknown): value is PermissionError {
  return isApiError(value) && value.code === "permission_denied";
}

export function isBusinessRuleError(value: unknown): value is BusinessRuleError {
  return isApiError(value) && value.code === "business_rule_violation";
}

export function isRateLimitError(value: unknown): value is RateLimitError {
  return isApiError(value) && value.code === "rate_limit_exceeded";
}

/**
 * True when the failure means the session is genuinely dead and the user must sign in
 * again — as opposed to a throttled or transient failure, which must NOT sign them out
 * (FR-008 vs FR-021).
 */
export function isSessionDeadError(value: unknown): value is ApiError {
  return (
    isApiError(value) &&
    (value.code === "invalid_refresh_token" || value.code === "refresh_token_reuse_detected")
  );
}
