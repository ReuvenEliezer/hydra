import type { Role } from "./session";

/**
 * An account as this package can know it.
 *
 * There is no user-list endpoint anywhere in auth-service, so an `Account` only ever
 * comes from a registration call — and the registration response is deliberately thin:
 * `AdminController` returns an `AuthResponse` with a null token, which
 * `@JsonInclude(NON_NULL)` reduces on the wire to `{userId, message}` where `message` is
 * "USER_CREATED" or "TENANT_ADMIN_CREATED".
 *
 * So `id` is the only field the server actually sends back. `username`, `tenantId` and
 * `role` are filled in from what the caller submitted plus which endpoint answered —
 * they are echoes of the request, not server-confirmed values.
 */
export interface Account {
  id: string;
  username: string;
  tenantId: string;
  role: Role;
}

export interface RegisterInput {
  username: string;
  password: string;
}

/** The literal `message` values the two registration endpoints return on success. */
export type RegistrationOutcome = "USER_CREATED" | "TENANT_ADMIN_CREATED";

export interface RegisterResponseBody {
  userId: string;
  message?: RegistrationOutcome;
}
