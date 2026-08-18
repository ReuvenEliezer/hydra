# Implementation Plan: Browser Edge Hardening

**Branch**: `002-cors-edge-hardening` | **Date**: 2026-08-17 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `/specs/002-cors-edge-hardening/spec.md`

## Summary

Consolidate the browser origin policy — today duplicated across auth-service and order-service — into a new `browser-edge-starter` module following the `rate-limit-starter` precedent, and turn three currently-unstated architectural facts into enforced ones: the services are the sole emitter of cross-origin headers, any edge must be transparent (`Host` preserved, no headers of its own), and only same-registrable-domain topologies are supported.

The load-bearing decision, taken in `/speckit-clarify`, is **services-own-the-policy with a transparent edge**. It dissolves rather than answers the Kubernetes-versus-docker-compose question: a transparent edge is specified by constraints that hold for any implementation, so this feature no longer blocks on a decision the constitution lists as under active evaluation.

Two things make the work more than a code move. First, an over-broad origin pattern is a credential-echo hazard, so pattern validation becomes fatal at startup rather than advisory — with a deliberate asymmetry against the empty-list case, which stays a warning. Second, the edge contract ships as an executable conformance suite that is itself validated against a deliberately hostile stand-in, because a suite that only ever meets a correct edge cannot detect its own breakage.

## Technical Context

**Language/Version**: Java 25 (`<java.version>25</java.version>` in the root POM)

**Primary Dependencies**: Spring Boot 4.1.0, Spring Security, Spring Web (`CorsConfiguration`, `CorsConfigurationSource`), Guava 33.4.0-jre (`InternetDomainName`, for the public-suffix check — see research R3), Lombok

**Storage**: N/A. This feature reads configuration only; no PostgreSQL or Redis state is read or written.

**Testing**: JUnit 5, AssertJ, Spring Boot Test, Testcontainers (`spring-boot-testcontainers`, `junit-jupiter`), `spring-boot-resttestclient` + httpclient5 in `integration-tests`

**Target Platform**: Linux/JVM services, optionally behind a transparent edge; evergreen browsers for the front-end package

**Project Type**: Maven multi-module web services (7 modules today)

**Performance Goals**: None new. Preflight caching stays at the existing `PT30M` default, which is the only performance lever this feature touches.

**Constraints**: Fail-closed at startup for unsafe configuration, fail-closed at request time for absent configuration; `infra-shared` must remain framework-free; the property keys `hydra.cors.allowed-origin-patterns` and `hydra.tenant.base-domains` must not change, because a silently-unbound key is this change's one no-error failure mode

**Scale/Scope**: 2 browser-facing services, N tenants per controlled base domain, 1 registrable domain per deployment (research R6)

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-checked after Phase 1 design.*

| Principle | Assessment | Verdict |
|---|---|---|
| **I. Framework-Free Shared Core** | The policy needs `spring-web` types, so `infra-shared` is not a candidate and nothing is added to it. The new module owns its own framework dependencies, exactly as `rate-limit-starter`'s POM description says it must. | **PASS** |
| **II. Dedicated Modules for Cross-Cutting Concerns** | A browser-edge policy spanning every browser-facing service is precisely this principle's subject. `browser-edge-starter` gets its own `AutoConfiguration.imports`, its own configuration properties, and contributes a `CorsConfigurationSource` — the same shape as the rate-limiting module. | **PASS** |
| **III. Load-Path-Authoritative Paths** | This is the principle most at risk here, and the risk is concrete rather than theoretical: 003's own task list records that renaming a CORS key without updating its binding "binds to nothing and silently fails closed." Both property keys are therefore left unchanged, and research R7 enumerates all five string-matched or classpath-scanned contracts that must move together. | **PASS**, with R7 as the checklist |
| **IV. Atomic Distributed State Mutations** | No Redis or database state is read or written. | **N/A** |
| **V. Audit Before Building** | Every claim in research.md was checked against source on 2026-08-17, and three stale claims in the prior spec were corrected as a result. The constitution's open edge-layer question is *surfaced and dissolved* by the transparent-edge decision rather than silently assumed — the spec records the technology choice as explicitly out of scope. | **PASS** |

**Post-Phase-1 re-check**: unchanged. No design artifact introduced a framework dependency into `infra-shared`, no new module beyond the one Principle II requires, no state mutation, and no property-key rename. The one judgement call — putting the conformance suite in the existing `integration-tests` module rather than a new one — is test placement, which Principle II does not govern; rationale in research R5.

**No Complexity Tracking entries.** No principle is violated, so nothing requires justification.

## Project Structure

### Documentation (this feature)

```text
specs/002-cors-edge-hardening/
├── plan.md                              # This file
├── spec.md                              # Feature specification (5 clarifications integrated)
├── research.md                          # Phase 0 output — R1..R8
├── data-model.md                        # Phase 1 output — configuration model
├── quickstart.md                        # Phase 1 output — 7 validation scenarios
├── contracts/
│   ├── browser-edge-starter.md          # Module public surface
│   └── transparent-edge-contract.md     # The 5-clause edge contract
├── checklists/
│   └── requirements.md                  # Spec quality checklist, 16/16
└── tasks.md                             # Phase 2 — NOT created by /speckit-plan
```

### Source Code (repository root)

```text
browser-edge-starter/                                    # NEW MODULE
├── pom.xml                                              # + guava; mirrors rate-limit-starter
└── src/
    ├── main/
    │   ├── java/com/reuven/browseredge/
    │   │   ├── BrowserEdgeAutoConfiguration.java        # Single activation point
    │   │   ├── BrowserOriginProperties.java             # binds hydra.cors
    │   │   ├── ControlledDomainProperties.java          # binds hydra.tenant.base-domains
    │   │   ├── OriginPatternValidator.java              # FR-010 / FR-017 / FR-018
    │   │   └── InvalidOriginPolicyException.java        # names the offending value
    │   └── resources/META-INF/spring/
    │       └── org.springframework.boot.autoconfigure.AutoConfiguration.imports
    └── test/java/com/reuven/browseredge/                # validator + startup-failure tests

auth-service/src/main/java/com/reuven/auth/config/
├── CorsConfig.java                                      # DELETED
├── CorsProperties.java                                  # DELETED
├── TenantResolutionProperties.java                      # MODIFIED: baseDomains moves out
└── SecurityCommons.java                                 # UNCHANGED (bean resolved by type)

order-service/src/main/java/com/reuven/orderservice/config/
├── CorsConfig.java                                      # DELETED
└── CorsProperties.java                                  # DELETED

integration-tests/src/test/java/com/reuven/integration/
└── edge/                                                # NEW: @Tag("edge-conformance")
    ├── TransparentEdgeConformanceTest.java              # 5 clauses, -Dedge.base-url
    └── StandInProxies.java                              # transparent + hostile nginx containers

pom.xml                                                  # MODIFIED: + <module>browser-edge-starter</module>
auth-service/pom.xml, order-service/pom.xml              # MODIFIED: + starter dependency
```

**Structure Decision**: A new sibling module at the repository root, matching the existing flat multi-module layout (`infra-shared`, `infra-database`, `rate-limit-starter`, the two services, `integration-tests`). `browser-edge-starter` is placed before the services in the reactor, since both depend on it. The conformance suite lives in `integration-tests` rather than a new module — it is test-only code, `integration-tests` already has Testcontainers and an HTTP client wired, and the `edge.base-url` property makes it pointable at a real edge without extraction. Research R5 records the tradeoff and the conditions under which extracting it later would be right.

## Sequencing note for `/speckit-tasks`

User Story 1 (module extraction) is deliverable on its own and unblocks nothing else — it is the natural first slice. User Stories 2 and 3 share the conformance suite as their delivery vehicle, so they are best built together rather than sequenced. User Story 4 (startup validation for topology) is independent of the suite and can proceed in parallel with it, but depends on `ControlledDomainProperties` existing, so it follows the extraction.

The one cross-feature edit is `TenantResolutionProperties`, which belongs to 003. It should land in the same commit as the shared record that replaces its `baseDomains` component, because a half-applied move binds nothing and fails closed silently (Principle III, research R7).
