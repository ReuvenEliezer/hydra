import type { Role } from "../../src/types/session";

/**
 * Builds a structurally valid, UNSIGNED JWT for tests.
 *
 * The package only ever base64url-decodes the payload (`decodeAccessTokenClaims`) and
 * never verifies a signature, so a real RS256 token would add nothing but key
 * management to the test suite. The signature segment is a placeholder on purpose —
 * if any production code ever starts depending on it, these tests should break loudly.
 */
export interface FakeTokenClaims {
  userId?: string;
  tenantId?: string;
  username?: string;
  roles?: Role[];
  expiresInSeconds?: number;
}

export const TEST_TENANT_ID = "8b0f2e4c-1d3a-4f6b-9c8d-0e1f2a3b4c5d";
export const TEST_USER_ID = "3f2504e0-4f89-11d3-9a0c-0305e82c3301";
export const TEST_USERNAME = "test-user";

function base64Url(value: string): string {
  return btoa(value).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

export function makeAccessToken(claims: FakeTokenClaims = {}): string {
  const {
    userId = TEST_USER_ID,
    tenantId = TEST_TENANT_ID,
    username = TEST_USERNAME,
    roles = ["ROLE_USER"],
    expiresInSeconds = 3600,
  } = claims;

  const header = base64Url(JSON.stringify({ alg: "RS256", typ: "JWT", kid: "test-key" }));
  const nowSeconds = Math.floor(Date.now() / 1000);
  const payload = base64Url(
    JSON.stringify({
      sub: userId,
      tenantId,
      username,
      roles,
      iss: "hydra-auth-service",
      iat: nowSeconds,
      exp: nowSeconds + expiresInSeconds,
      jti: `${nowSeconds}-${Math.random().toString(36).slice(2)}`,
    }),
  );

  return `${header}.${payload}.test-signature-not-verified`;
}
