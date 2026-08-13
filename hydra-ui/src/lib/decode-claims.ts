import { isRole, type Role } from "../types/session";

/**
 * Reads `sub`, `tenantId` and `roles` out of the access token's payload.
 *
 * This is necessary because the login response body is `{userId, token}` and carries no
 * roles at all — the roles only exist inside the JWT.
 *
 * IT IS A UI-AFFORDANCE HINT, NOT AUTHORIZATION. The signature is deliberately NOT
 * verified here (the package has no public key and no business verifying one); a user
 * who tampers with the token in memory can make the UI render an admin button, and the
 * backend will still reject the call with 403. Never gate anything that matters on this.
 */
export interface AccessTokenClaims {
  userId: string;
  tenantId: string;
  roles: Role[];
}

function base64UrlDecode(segment: string): string {
  const base64 = segment.replace(/-/g, "+").replace(/_/g, "/");
  const padded = base64.padEnd(base64.length + ((4 - (base64.length % 4)) % 4), "=");
  const binary = atob(padded);
  // Payloads are UTF-8; `atob` yields latin-1 bytes, so re-decode before JSON.parse.
  const bytes = Uint8Array.from(binary, (char) => char.charCodeAt(0));
  return new TextDecoder().decode(bytes);
}

export function decodeAccessTokenClaims(token: string): AccessTokenClaims | null {
  const segments = token.split(".");
  const payload = segments[1];
  if (segments.length !== 3 || payload === undefined || payload.length === 0) return null;

  let parsed: unknown;
  try {
    parsed = JSON.parse(base64UrlDecode(payload));
  } catch {
    return null;
  }

  if (parsed === null || typeof parsed !== "object") return null;
  const claims = parsed as Record<string, unknown>;

  const userId = claims["sub"];
  const tenantId = claims["tenantId"];
  if (typeof userId !== "string" || typeof tenantId !== "string") return null;

  const rawRoles = claims["roles"];
  const roles = Array.isArray(rawRoles) ? rawRoles.filter(isRole) : [];

  return { userId, tenantId, roles };
}
