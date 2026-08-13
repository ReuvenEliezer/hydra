# Hydra

Java 25 / Spring Boot 4.1 microservices monorepo. Multi-module Maven build with a framework-free shared core, a dedicated Redis-backed rate-limiting starter, and JWT-based auth issued by `auth-service` and consumed by `order-service`.

## Modules

| Module | Purpose |
|---|---|
| `auth-service` | Authentication service. Login/refresh/logout, JWT issuance (RSA-signed, JWKS endpoint), refresh token rotation via atomic Redis Lua scripts, tenant/user bootstrap, admin user registration. |
| `order-service` | Order domain service. CRUD-style order API, secured as an OAuth2 resource server validating JWTs issued by `auth-service`. |
| `infra-shared` | Pure POJO module — **no framework dependencies**. Shared types: `AuthenticatedUser`, `Role`/`Roles`, `Headers`, `JwtClaimNames`, `ErrorResponse`. |
| `infra-database` | Shared persistence infrastructure (Postgres, H2 for tests, Liquibase, Spring Data JPA). |
| `rate-limit-starter` | Spring Boot auto-configuration module for declarative rate limiting: `@RateLimited` + AOP (`RateLimiterAspect`), SpEL key expressions, `RateLimiterEngine` abstraction with a Bucket4j/Redis-Lettuce implementation (`Bucket4jRateLimiterEngine`) and a `NoOpRateLimiterEngine`, `ClientIpResolver`, `RateLimitExceptionHandler`. Registered via `META-INF/spring/org.springframework.boot.autoconfigure.AutoConfiguration.imports`. |
| `integration-tests` | Cross-service integration tests only (no `src/main`). Boots `auth-service` and `order-service` as real Spring contexts in the same JVM and exercises the actual HTTP/JWT contract between them. Builds last in the reactor. |

## Architecture

### Auth flow

- `auth-service` issues RSA-signed JWTs; public keys are exposed at `/.well-known/jwks.json` (`JwksController`) for resource servers to validate against.
- `POST /api/v1/auth/login`, `/refresh`, `/logout` (`AuthController`); `POST /api/v1/admin/register-user` and `/api/v1/admin/{tenantId}/register-admin` (`AdminController`).
- Refresh token rotation is atomic via Lua scripts loaded from the classpath at `lua/<name>.lua` (`refresh_issue`, `refresh_rotate`, `refresh_revoke_family`, `refresh_revoke_all`) — the resource path under `src/main/resources/lua/` is load-path-authoritative, not cosmetic.
- `order-service` validates those JWTs as an OAuth2 resource server; `OrderController` exposes `/api/orders` (list, create, get by id, delete).
- Key material comes from `KeyProvider` implementations: `LocalKeyProvider` (dev) and `CloudKeyProvider` (AWS Secrets Manager, via `software.amazon.awssdk:secretsmanager`).

### Rate limiting

- Dedicated auto-configuration module (`rate-limit-starter`), deliberately kept out of `infra-shared` so the shared core stays framework-free.
- Engine abstraction (`RateLimiterEngine`) with a Bucket4j/Redis-backed implementation and a no-op fallback, so the algorithm/backend can be swapped without touching call sites.
- AOP-based (`RateLimiterAspect` + `@RateLimited`), with SpEL for dynamic key expressions; `auth-service` is the current consumer.

### Persistence

- Postgres 16 in production/dev (`infra-database`), H2 for tests.
- Liquibase-managed schema per service (`auth-service`: `db/changelog/`, `order-service`: `changes/`).

### Redis

- Client: Lettuce. Used for refresh-token state (`auth-service`) and distributed rate-limit buckets (`rate-limit-starter`).
- `LettuceBasedProxyManager` backed by a Spring-managed connection bean.

## Tech stack

- Java 25, Spring Boot 4.1, Spring Security (incl. OAuth2 resource server), Spring Data JPA, Spring Data Redis, Spring AOP
- Nimbus JOSE+JWT (RSA signing/JWKS), Bucket4j + Lettuce (rate limiting), Liquibase, Lombok
- AWS SDK v2 (`secretsmanager`) for cloud key material
- Testcontainers (Postgres, Redis) + JUnit 5 + AssertJ across all modules
- Maven multi-module build (reactor order: `infra-shared` → `infra-database` → `rate-limit-starter` → `auth-service` → `order-service` → `integration-tests`)

## Getting started

Start local infra (Postgres + Redis):

```bash
docker compose up -d
```

Build and test the whole reactor:

```bash
mvn clean install
```

### Running `auth-service` with the `local` profile

`local` is the default active profile (`spring.profiles.active` in `application.yaml`), and it needs two things `application-local.yml` doesn't provide a default for:

- `jwt.private-key-path` (`${JWT_PRIVATE_KEY_PATH}`) — an RSA private key, PKCS#8 PEM, that `LocalKeyProvider` loads from disk to sign tokens (the public key/JWKS entry is always derived from it, never loaded separately).
- `app.bootstrap.super-admin-password` (`${APP_BOOTSTRAP_SUPER_ADMIN_PASSWORD}`) — password for the `super-admin` user that `BootstrapService` creates on first boot (only when the `users` table is empty), under a generated `System Tenant`.

Neither is set anywhere in the repo, so starting `auth-service` without them fails fast with a `PlaceholderResolutionException`.

**1. Generate a local signing key** (PKCS#8 PEM, not committed — `keys/` is gitignored):

```bash
mkdir -p keys
openssl genpkey -algorithm RSA -out keys/jwt-private-key-local.pem -pkeyopt rsa_keygen_bits:2048
chmod 600 keys/jwt-private-key-local.pem
```

**2. Set the env vars and run:**

```bash
export JWT_PRIVATE_KEY_PATH="$(pwd)/keys/jwt-private-key-local.pem"
export APP_BOOTSTRAP_SUPER_ADMIN_PASSWORD=admin12345
mvn -pl auth-service -am spring-boot:run
```

In IntelliJ, use a Spring Boot run configuration for `com.reuven.auth.AuthServiceApplication` with those two vars under Environment Variables instead (a shareable one lives at `.run/AuthServiceApplication.run.xml` — update the key path and password there rather than duplicating the config elsewhere).

**3. Look up the bootstrap tenant.** `BootstrapService` doesn't log the generated tenant UUID, so fetch it via the H2 console (enabled in `local`, at `http://localhost:8083/h2-console`, JDBC URL/credentials from `application-local.yml`):

```sql
SELECT id, name FROM tenants;
```

**4. Log in to get a token** (`auth-service` listens on `:8083`):

```bash
curl -i -X POST http://localhost:8083/api/v1/auth/login \
  -H "Content-Type: application/json" \
  -H "X-Tenant-ID: <tenant-uuid-from-step-3>" \
  -d '{"username":"super-admin","password":"admin12345"}'
```

The access token comes back in the JSON body (`AuthResponse`); the refresh token is set as an httpOnly cookie, not returned in the body.

CI generates its own ephemeral RSA keypair per run (see `.github/workflows/ci.yml`) purely for tests — that key is not a real credential and is unrelated to the one you generate locally.

## Design principles

See [`.specify/memory/constitution.md`](.specify/memory/constitution.md) for the full, governing version. Summary:

- **No framework code in `infra-shared`.** It stays a plain POJO jar. New cross-cutting infra concerns get their own dedicated module (see `rate-limit-starter`).
- **Classpath paths are load-path-authoritative**, not cosmetic (e.g. `lua/` for Redis scripts).
- **Multi-step Redis mutations must be atomic** (Lua scripts), never read-modify-write round trips.
- **Audit before adding.** This repo carries partially-completed refactors; confirm current state against source before building on top of it — README and other docs are advisory, not authoritative.

## CI

GitHub Actions (`.github/workflows/ci.yml`): builds the reactor, then runs the full test suite (unit + Testcontainers-backed integration tests, including the cross-service `integration-tests` module) with per-module JUnit reports via `dorny/test-reporter`.
