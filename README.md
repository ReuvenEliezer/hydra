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

`auth-service` needs a signing key at startup — see `application-local.yml` / `application-prod.yml` for the expected `JWT_PRIVATE_KEY_PATH` (or equivalent) configuration. CI generates an ephemeral RSA keypair per run (see `.github/workflows/ci.yml`) purely for tests; it is not a real credential.

## Design principles

See [`.specify/memory/constitution.md`](.specify/memory/constitution.md) for the full, governing version. Summary:

- **No framework code in `infra-shared`.** It stays a plain POJO jar. New cross-cutting infra concerns get their own dedicated module (see `rate-limit-starter`).
- **Classpath paths are load-path-authoritative**, not cosmetic (e.g. `lua/` for Redis scripts).
- **Multi-step Redis mutations must be atomic** (Lua scripts), never read-modify-write round trips.
- **Audit before adding.** This repo carries partially-completed refactors; confirm current state against source before building on top of it — README and other docs are advisory, not authoritative.

## CI

GitHub Actions (`.github/workflows/ci.yml`): builds the reactor, then runs the full test suite (unit + Testcontainers-backed integration tests, including the cross-service `integration-tests` module) with per-module JUnit reports via `dorny/test-reporter`.
