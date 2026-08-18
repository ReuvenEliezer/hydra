/**
 * Roles as they appear in the JWT `roles` claim — the values are the Spring Security
 * authority strings themselves (`Role.authority()` in infra-shared), not bare names.
 */
export type Role = "ROLE_USER" | "ROLE_ADMIN" | "ROLE_SUPER_ADMIN";

/**
 * `refreshing` is the state other requests key off to decide whether to coalesce onto
 * the in-flight refresh instead of starting their own. `expired` means a refresh was
 * attempted and definitively failed (FR-008) — distinct from `anonymous`, which is
 * simply "never signed in / signed out cleanly".
 */
export type SessionStatus =
  | "anonymous"
  | "authenticating"
  | "authenticated"
  | "refreshing"
  | "expired";

export interface SessionUser {
  id: string;
  tenantId: string;
  username: string;
  roles: Role[];
}

export interface SessionState {
  status: SessionStatus;
  user: SessionUser | null;
}

/**
 * Role hierarchy, mirroring `Roles.USER` / `Roles.ADMIN` / `Roles.SUPER_ADMIN_ONLY`:
 * an admin satisfies a user-level requirement, a super admin satisfies both.
 */
const ROLE_RANK: Record<Role, number> = {
  ROLE_USER: 1,
  ROLE_ADMIN: 2,
  ROLE_SUPER_ADMIN: 3,
};

export function isRole(value: unknown): value is Role {
  return typeof value === "string" && value in ROLE_RANK;
}

/**
 * UI affordance only, never authorization. Every real access decision is the backend's
 * `@PreAuthorize`; this exists so the UI does not offer controls that would 403.
 */
export function roleSatisfies(held: readonly Role[], required: Role): boolean {
  const needed = ROLE_RANK[required];
  return held.some((role) => ROLE_RANK[role] >= needed);
}
