<!--
Sync Impact Report
Version change: [TEMPLATE] → 1.0.0
Modified principles: n/a (initial ratification from template placeholders)
Added sections:
  - Core Principles I–V (Framework-Free Shared Core, Dedicated Modules for Cross-Cutting
    Concerns, Load-Path-Authoritative Paths, Atomic Distributed State Mutations,
    Audit Before Building)
  - Technology Constraints
  - Development Workflow
  - Governance
Removed sections: none (template placeholders only)
Deferred items:
  - TODO(RATIFICATION_DATE): original adoption date not recorded anywhere in the repo
    (no prior constitution, no dated governance doc). Set when the team confirms it.
Templates requiring follow-up: none — dependent templates read this file at runtime and
were not modified by this command per the scope guard.
-->

# Hydra Constitution

## Core Principles

### I. Framework-Free Shared Core
`infra-shared` MUST remain a plain POJO module with no framework dependencies (no Spring,
no Bucket4j, no Redis client, etc.). Any type placed there MUST be usable without pulling
in a framework runtime. This is a hard constraint, not a style preference: it exists so
shared domain/cross-cutting types stay reusable across services that may not share the
same framework stack.

### II. Dedicated Modules for Cross-Cutting Concerns
A new cross-cutting infrastructure concern (rate limiting, persistence, messaging, etc.)
MUST get its own dedicated module rather than being folded into `infra-shared` or bolted
onto a service. Each such module owns its auto-configuration (e.g. registered via
`META-INF/spring/org.springframework.boot.autoconfigure.AutoConfiguration.imports`) and
exposes an engine/interface abstraction (e.g. `RateLimiterEngine`) so the underlying
implementation can be swapped without touching call sites. Rationale: keeps
`infra-shared` framework-free (Principle I) and keeps concerns independently
versionable and testable.

### III. Load-Path-Authoritative Paths
Classpath resource paths (e.g. `lua/<name>.lua` loaded via
`ClassPathResource("lua/" + name + ".lua")`) are functional contracts, not cosmetic
directory choices. Renaming or restructuring such directories without updating every
load site MUST be treated as a breaking change. Rationale: prior incidents in this
class of bug are silent at compile time and only fail at runtime.

### IV. Atomic Distributed State Mutations (NON-NEGOTIABLE)
Any multi-step mutation of shared Redis state (e.g. refresh token rotation) MUST be
atomic — implemented via Lua scripts executed server-side, not via separate
read-modify-write round trips from the application. Rationale: this is a
multi-instance system; non-atomic mutations against shared state are a correctness
bug, not an edge case, under concurrent access.

### V. Audit Before Building
This repository carries partially-completed refactors and open architectural
questions (e.g. Kubernetes vs. plain Envoy + docker-compose for the edge layer,
first-admin bootstrap via raw SQL). Before extending a module or subsystem, its
current actual state MUST be confirmed against source — README and prior docs are
advisory, not authoritative. Work that depends on an unresolved open question (see
README "Roadmap / known gaps") MUST surface that dependency rather than silently
picking an assumption.

## Technology Constraints

- Language/runtime: Java 25.
- Framework: Spring Boot 4.1, Spring AOP, Spring Data Redis.
- Rate limiting: Bucket4j, applied via AOP (`RateLimiterAspect` + `@RateLimited`) with
  SpEL for dynamic key expressions.
- Redis client: Lettuce, using a Spring-managed connection bean
  (`@Bean(destroyMethod = "close")`).
- Build: Maven multi-module.
- Testing: Testcontainers with a typed `RedisContainer` for integration tests against
  real Redis rather than mocks.
- Edge layer: Kubernetes + Envoy Gateway is the current target; docker-compose is a
  candidate alternative under active evaluation (see Principle V) — do not treat either
  as permanently settled without checking the roadmap.

## Development Workflow

- New infra concerns follow Principle II: a dedicated module with its own
  auto-configuration and an interface abstraction over the concrete implementation.
- Changes touching classpath-loaded resources (Lua scripts, config files under a
  fixed directory) MUST update every load site in the same change (Principle III).
- Changes to distributed state mutation logic MUST preserve atomicity (Principle IV)
  and MUST be covered by integration tests against real Redis (Testcontainers), not
  mocks.
- Before starting work in an area with a documented open question or known gap
  (README "Roadmap / known gaps"), confirm current repo state first (Principle V).

## Governance

This constitution supersedes ad hoc practice for the areas it covers. Amendments
require: (1) the proposed change stated explicitly, (2) a version bump per the policy
below, (3) update of the Sync Impact Report at the top of this file.

Versioning policy (semantic versioning applied to governance):
- MAJOR: backward-incompatible principle removal or redefinition.
- MINOR: a new principle or materially expanded section added.
- PATCH: wording, typo, or non-semantic clarification.

Compliance: reviews of changes touching `infra-shared`, new infra modules, Redis-backed
state mutations, or classpath-loaded resources should verify alignment with the
relevant principle above. Complexity that conflicts with a principle (e.g. adding a
framework dependency to `infra-shared`) MUST be justified explicitly in the review or
avoided.

**Version**: 1.0.0 | **Ratified**: TODO(RATIFICATION_DATE): unknown — no prior dated
constitution or governance doc exists in this repo | **Last Amended**: 2026-08-13
