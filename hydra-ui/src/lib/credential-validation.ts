/**
 * Client-side credential rules, mirroring the backend's Bean Validation bounds EXACTLY
 * (`LoginRequest` and `RegisterRequest`: `@Size(min = 3, max = 50)` on username,
 * `@Size(min = 8, max = 100)` on password).
 *
 * The 100-character password maximum matters and is easy to drop: the backend enforces
 * it, so omitting it here just moves the rejection from an inline field message to a
 * confusing 400 after submit.
 *
 * This is convenience, not security — every rule here is enforced again server-side.
 */
export const USERNAME_MIN_LENGTH = 3;
export const USERNAME_MAX_LENGTH = 50;
export const PASSWORD_MIN_LENGTH = 8;
export const PASSWORD_MAX_LENGTH = 100;

export interface CredentialErrors {
  username?: string;
  password?: string;
}

export function validateUsername(username: string): string | undefined {
  if (username.trim().length === 0) return "Username cannot be blank";
  if (username.length < USERNAME_MIN_LENGTH || username.length > USERNAME_MAX_LENGTH) {
    return `Username must be between ${USERNAME_MIN_LENGTH} and ${USERNAME_MAX_LENGTH} characters`;
  }
  return undefined;
}

export function validatePassword(password: string): string | undefined {
  if (password.length === 0) return "Password cannot be blank";
  if (password.length < PASSWORD_MIN_LENGTH) {
    return `Password must be at least ${PASSWORD_MIN_LENGTH} characters long`;
  }
  if (password.length > PASSWORD_MAX_LENGTH) {
    return `Password must be at most ${PASSWORD_MAX_LENGTH} characters long`;
  }
  return undefined;
}

export function validateCredentials(username: string, password: string): CredentialErrors {
  const errors: CredentialErrors = {};
  const usernameError = validateUsername(username);
  const passwordError = validatePassword(password);
  if (usernameError !== undefined) errors.username = usernameError;
  if (passwordError !== undefined) errors.password = passwordError;
  return errors;
}

export function hasCredentialErrors(errors: CredentialErrors): boolean {
  return errors.username !== undefined || errors.password !== undefined;
}
