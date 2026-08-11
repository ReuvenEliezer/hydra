# Hydra

Java 25 / Spring Boot 4.1 microservices monorepo. Multi-module Maven build with shared infrastructure modules, Redis-backed distributed state, and a Kubernetes/Envoy Gateway edge layer.

> **Note:** This README was drafted from architectural context, not a live scan of the repo. Verify module names, versions, and paths against the actual source before relying on it — see the review checklist at the bottom.

## Modules

| Module | Purpose |
|---|---|
| `auth-service` | Authentication/authorization service. JWT issuance, refresh token rotation (Redis + Lua, atomic), per-client rate limiting via `infra-ratelimit`. |
| `order-service` | Order domain service. |
| `infra-shared` | Pure POJO module — **no framework dependencies**. Cross-cutting types shared across services. Hard constraint: keep this framework-free. |
| `infra-database` | Shared persistence infrastructure. |
| `infra-ratelimit` | Spring Boot auto-configuration module for rate limiting. Contains `RateLimiterAspect`, `@RateLimited`, SpEL expression caching, `RateLimiterEngine` (interface) with `Bucket4jRateLimiterEngine`, `ClientIpResolver`, `RateLimitProperties`, `RateLimitRedisConfig`, `RateLimitExceptionHandler`. Registered via `META-INF/spring/org.springframework.boot.autoconfigure.AutoConfiguration.imports`. |

## Architecture

### Rate limiting

- Dedicated auto-configuration module (`infra-ratelimit`), not embedded in `infra-shared`.
- Engine abstraction (`RateLimiterEngine`) with a Bucket4j-backed implementation, so the algorithm can be swapped without touching call sites.
- AOP-based (`RateLimiterAspect` + `@RateLimited`), with SpEL for dynamic key expressions.
- Redis-backed bucket state for cross-instance consistency.
- `type: Local` at the Envoy layer does **not** provide per-IP bucketing — that requires `type: Global` with a Redis-backed ratelimit service. (Documented in-line in the K8s rate-limit policy.)

### Redis

- Redis 7.4, client: Lettuce.
- Refresh token rotation is atomic via Lua scripts, loaded from the classpath at `lua/<name>.lua` (`ClassPathResource("lua/" + name + ".lua")` — directory naming is load-path-authoritative).
- `LettuceBasedProxyManager` backed by a Spring-managed connection bean (`@Bean(destroyMethod = "close")`).

### Edge layer (Kubernetes / Envoy Gateway)

Manifests under `k8s/`. Current state:

- Routing: `/api/v1/orders` → `/api/orders` via `URLRewrite` filter.
- `SecurityPolicy` forwards JWT claims `sub` / `tenantId` as headers `x-user-id` / `x-tenant-id` via `claimToHeaders`.
- Rate-limit policy currently `type: Local` (see caveat above); `type: Global` + Redis-backed limiter needed for real per-IP bucketing across replicas.
- `k8s/README.md` documents a bootstrap workaround (raw SQL) for first-admin creation.
- No GitOps layer — `kubectl apply` is imperative. ArgoCD/dashboard not yet added.

**Open question:** whether Kubernetes is the right production target, or whether plain Envoy in docker-compose gets the same edge JWT validation + rate limiting with materially less operational overhead. Worth resolving before investing further in the K8s layer (e.g. GitOps).

## Tech stack

- Java 25, Spring Boot 4.1, Spring AOP, Spring Data Redis
- Bucket4j (rate limiting), Lettuce (Redis client)
- Testcontainers with typed `RedisContainer` for integration tests
- Maven multi-module build
- Kubernetes + Envoy Gateway (edge), docker-compose (local dev — candidate alternative to K8s)

## Getting started

```bash
mvn clean install
```

> Fill in actual run/dev instructions (docker-compose services, required env vars, local Redis setup) once confirmed against the repo.

## Design principles

- **No framework code in `infra-shared`.** It stays a plain POJO jar. New cross-cutting infra concerns get their own dedicated module (see `infra-ratelimit`).
- **Classpath paths are load-path-authoritative**, not cosmetic (e.g. `lua/` for Redis scripts).
- **Audit before adding.** This repo tends to carry partially-completed refactors; confirm current state before building on top of it.

## Roadmap / known gaps

- [ ] Decide: Kubernetes vs. plain Envoy + docker-compose for production edge.
- [ ] If staying on K8s: add GitOps (ArgoCD) instead of imperative `kubectl apply`.
- [ ] Management/dashboard layer — not yet started, separate phase.
- [ ] Replace raw-SQL first-admin bootstrap with a proper mechanism.

---

### Review checklist (fill in / correct before committing)

- [ ] Confirm actual module list and names against `pom.xml` files
- [ ] Confirm Java/Spring Boot versions in the parent POM
- [ ] Add real build/run instructions (docker-compose file, ports, env vars)
- [ ] Add license/ownership info if relevant
- [ ] Link to `k8s/README.md` and any other module-level READMEs
