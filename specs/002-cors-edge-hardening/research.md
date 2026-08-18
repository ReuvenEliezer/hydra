# Phase 0 Research: Browser Edge Hardening

**Feature**: `002-cors-edge-hardening` | **Date**: 2026-08-17

All findings below were confirmed against source in this repository on 2026-08-17, per constitution Principle V. Where a claim comes from a prior document rather than from code, it is labelled as such.

---

## R1 — Where the shared origin policy lives

**Decision**: A new Maven module, `browser-edge-starter`, package `com.reuven.browseredge`, modelled directly on `rate-limit-starter`. It owns its own `META-INF/spring/org.springframework.boot.autoconfigure.AutoConfiguration.imports`, exposes `@ConfigurationProperties` records, and contributes a `CorsConfigurationSource` bean. auth-service and order-service delete their local `CorsConfig`/`CorsProperties` and depend on the module.

**Rationale (audited)**: Constitution Principle II requires a cross-cutting infrastructure concern to get its own module with its own auto-configuration and an abstraction over the implementation, explicitly *not* folded into `infra-shared` (Principle I keeps that framework-free). `rate-limit-starter` is the established precedent and its own POM description states the reasoning verbatim: "Deliberately NOT part of infra-shared: infra-shared stays a dependency-free POJO jar, this module owns every framework dependency the domain needs." The CORS policy needs `spring-web` types (`CorsConfiguration`, `CorsConfigurationSource`), so `infra-shared` is not an option.

The auto-configuration mechanism is proven in this repo: `RateLimitAutoConfiguration` is discovered through the imports file with no `@ComponentScan` in any service's `@SpringBootApplication`, and its Javadoc records that a service with none of the prerequisites "pulls in this jar with zero runtime effect — onboarding is additive, never a breaking change."

**Alternatives considered**:
- *Leave the config duplicated and add a lint rule* — rejected: does not satisfy FR-001, and the drift risk is what the feature exists to remove.
- *Put the shared record in `infra-shared`* — rejected: violates Principle I, since `CorsConfiguration` is a Spring type.
- *A parent `@Configuration` class inherited by each service* — rejected: inheritance across module boundaries still requires each service to opt in by extending, which is a copy of the wiring, not a removal of it.

---

## R2 — Making the controlled-domain set reachable from both services

**Problem (audited)**: FR-010 derives the controlled-domain set from the deployment's declared tenant base domains. That configuration exists only in auth-service: `TenantResolutionProperties` binds `hydra.tenant` with `baseDomains` and `reservedIdentifiers`. `grep` over `order-service/src/main` for `base-domains`, `baseDomains`, or `hydra.tenant` returns nothing — order-service has no equivalent.

**Decision**: Move the base-domain list into `browser-edge-starter` as its own record bound to the **unchanged** key `hydra.tenant.base-domains`. auth-service's `TenantResolutionProperties` keeps `reservedIdentifiers` and consumes the shared record for base domains rather than binding them itself.

**Rationale**: The property key does not change, so no environment file, no `application-*.yml`, and no deployment variable is touched — which matters because 003's own task list records that renaming a CORS/tenant key without updating every binding site "binds to nothing and silently fails closed," the one failure mode of this class of change that produces no error. Both concerns then read one key from one record, so drift is structurally impossible rather than merely discouraged.

**Alternatives considered**:
- *Rename to a neutral key such as `hydra.domains.base`* — rejected: a cosmetic improvement bought with exactly the silent fail-closed risk described above, across every environment at once.
- *Duplicate the property into order-service* — rejected: reintroduces the duplication this feature removes, for the requirement whose purpose is removing it.
- *Two records binding the same key independently* — workable in Spring and drift-free (one key, two readers), but rejected as less clear than one owner; it invites a future editor to change one record's normalization and not the other.

**Consequence for 003**: `TenantResolutionProperties` is edited by this feature. Its `baseDomains` normalization (trim, lowercase with `Locale.ROOT`, null → empty) must move with it unchanged — that normalization is load-bearing for tenant resolution and is covered by 003's tests.

---

## R3 — Detecting a public suffix

**Decision**: Use Guava's `com.google.common.net.InternetDomainName` (`isPublicSuffix()` / `isUnderPublicSuffix()`), declared as an explicit dependency of `browser-edge-starter`.

**Rationale**: FR-018 requires rejecting a declared base domain that is itself a public suffix. This cannot be done with a label-count heuristic, and the reason is concrete rather than theoretical: **`localhost` is the configured base domain for local development** (`hydra.tenant.base-domains: localhost` in `application-local.yml`) and is a single label. A rule of "at least two labels" would refuse to start every local environment. Guava carries a bundled Public Suffix List and answers correctly for both cases — `com` and `co.uk` are public suffixes, `localhost` is not.

Guava 33.4.0-jre is already resolved in the local Maven repository, so this is not a new download for developers, but it MUST be declared explicitly in the module POM rather than relied upon transitively — an undeclared transitive that disappears on a dependency bump is precisely the class of silent breakage Principle III exists to prevent.

**Alternatives considered**:
- *Hand-maintained list of common public suffixes* — rejected: the PSL has thousands of entries and changes; a partial list gives false confidence exactly where the check is a security control.
- *Label-count structural rule alone* — rejected: breaks local development, as above.
- *A dedicated PSL library* — viable, but Guava is already in the dependency graph and is far more widely audited.

---

## R4 — Refusing to start

**Decision**: Validate in the `@Bean` factory method of the auto-configuration and throw a dedicated unchecked exception carrying the offending value and the reason. Spring Boot turns a bean-creation failure into a failed `ApplicationContext` refresh and a non-zero exit — the process does not reach a ready state.

**Rationale**: FR-010, FR-017, and FR-018 all require refusing to start rather than warning. The existing `CorsConfig` already does its checking at exactly this point — it inspects the list in `corsConfigurationSource()` and logs — so the validation has a natural home that is already on the startup path. Throwing there is the smallest change that converts the existing warn into a hard stop, and it keeps the "empty list fails closed" behaviour from FR-002 in the same method, so all four failure modes are stated in one place and cannot drift apart.

**Deliberate difference from today**: the current code *warns* on an empty list and starts. FR-002 preserves fail-closed at request time (an empty pattern list rejects every cross-origin request), so an empty list remains a startup warning, not a startup failure — an empty list is safe, merely useless. An over-broad pattern is not safe, so that one is fatal. This asymmetry is intentional and must be preserved by whoever implements it; collapsing both to "fatal" would break any deployment that legitimately serves no browser traffic.

**Alternatives considered**:
- *Bean Validation (`@Validated` + custom constraint)* — rejected: the failure message is assembled by the framework and is markedly less specific than a purpose-built exception, and FR-010/FR-017/FR-018 all require *naming the offending value*.
- *`ApplicationRunner` / `@PostConstruct` check* — rejected: runs after the context is up, so a service can bind its port before failing.

---

## R5 — Where the conformance suite lives, and how it proves itself

**Decision**: The suite lives in the existing `integration-tests` module, tagged `@Tag("edge-conformance")`, targeting a base URL from the `edge.base-url` property. Its default target in CI is an nginx stand-in container started with Testcontainers. It is run against **two** stand-in configurations: a correctly transparent one, which it must pass, and a deliberately `Host`-rewriting, header-injecting one, which it must fail.

**Rationale**: `integration-tests` already has Testcontainers, `spring-boot-resttestclient`, and httpclient5 wired, and already carries a cross-service test (`AuthOrderCrossServiceIntegrationTest`). Adding a module for test-only code would be ceremony without benefit; Principle II governs runtime cross-cutting concerns, not test placement.

The negative configuration is the load-bearing part of this decision. A conformance suite that only ever runs against a correct edge cannot distinguish "the edge is transparent" from "the assertions do not work," and would pass forever after a refactor silently broke it. Running it against a known-bad edge and requiring failure is what makes SC-009 and SC-010 meaningful rather than decorative.

**On the stand-in image**: nginx is scaffolding, not a recommendation. It was chosen because expressing both "preserve `Host`" and "rewrite `Host`" is a one-line configuration difference in it. Per the spec's Assumptions, this is explicitly not an answer to the Kubernetes-versus-docker-compose question — the suite takes a base URL and does not know what is serving it.

**Alternatives considered**:
- *A dedicated `edge-conformance` Maven module* — reasonable, and better if the suite is ever published for external consumers to run against their own edge. Rejected for now as premature; the `edge.base-url` property already makes it pointable, and a module can be extracted later without changing the assertions.
- *Only positive tests against a transparent proxy* — rejected: cannot detect its own breakage, as above.

---

## R6 — What FR-017 can actually check

**Problem**: FR-017 requires refusing to start on a configuration "whose front-end origin is not same-site with the services." Under 003's topology this is mostly unreachable: the page and the API are served from the same tenant host in production, and from the same host on different ports in development, and ports do not affect same-site. FR-010 additionally constrains every origin pattern to a declared base domain. So the obvious cross-site cases are already excluded.

**Decision**: Implement FR-017 as a **single-registrable-domain check on the controlled-domain set**. If the configured base domains span more than one registrable domain, the service refuses to start.

**Rationale**: The residual cross-site risk is a *pairing* risk, not a per-pattern one. With base domains `hydra.example.com` and `otherapp.io` both declared, every individual origin pattern is valid under FR-010, yet a page at `acme.otherapp.io` calling auth-service at `acme.hydra.example.com` is genuinely cross-site and its strict same-site cookie is silently withheld at every renewal — the exact failure User Story 4 exists to prevent. A per-pattern check cannot see this; only a check over the whole set can.

Refusing multi-registrable-domain deployments is consistent with the clarification that declined cross-site support: both say the supported topology is one registrable domain, and both fail loudly rather than at first expiry.

**Known limitation, stated rather than hidden**: this forbids a deployment that legitimately serves two independent product domains from one service instance, even when each is internally same-site. No such deployment exists today. If one is wanted later, the correct change is to designate one registrable domain authoritative for the session credential per instance, and FR-007 governs any relaxation of the cookie itself. Recorded here so a future reader meets a documented constraint rather than an unexplained one.

**Alternatives considered**:
- *Require an explicit `session-domain` designation whenever multiple base domains are configured* — more flexible and strictly better once a second product domain exists; rejected now as configuration surface for a case that does not exist, which Principle V's "audit before building" argues against.
- *Warn instead of refusing* — rejected: it reproduces the silent-sign-out trap the story is about, one step removed.

---

## R7 — Preserving the load-path contracts (Principle III)

**Audited load sites that must change together**, because each is a functional contract whose breakage is silent at compile time:

| Contract | Current state | Change |
|---|---|---|
| `hydra.cors.allowed-origin-patterns` | Bound by `CorsProperties` in **both** services; set in 4 YAML files | Key unchanged; binding moves to the shared module. Both services' local records deleted in the same change. |
| `hydra.tenant.base-domains` | Bound by `TenantResolutionProperties` (auth-service only) | Key unchanged; ownership moves to the shared module (R2). |
| `META-INF/spring/…AutoConfiguration.imports` | Exists in `rate-limit-starter` | New file in `browser-edge-starter`. Absent or misspelled, the module loads nothing and every service silently loses CORS. |
| `@EnableConfigurationProperties(CorsProperties.class)` on `CorsConfig` | Present in both services; there is no `@ConfigurationPropertiesScan` | The shared auto-configuration must register the records itself. 003's tasks record that an unregistered record "binds to nothing and silently fails closed." |
| `http.cors(Customizer.withDefaults())` in `SecurityCommons` | auth-service; picks up the `CorsConfigurationSource` bean by type | Unchanged — the bean keeps its type and name, so the security wiring is untouched. Verified in `SecurityCommons.applyCommonSecurity`. |

**Rationale for calling this out separately**: every row is a string-matched or classpath-scanned contract with no compile-time check. Principle III names this class of change as breaking and requires all sites to be updated together.

---

## R8 — What does not change

Confirmed by reading the current source, to bound the blast radius:

- **`SecurityCommons` authorization rules** stay as they are. The explicit `OPTIONS /**` permit-all backstop already exists with a comment explaining that it protects against filter-order changes, which is FR-005 already satisfied. This feature keeps it and adds a test.
- **`CookieUtil`** is untouched. `SameSite=Strict`, `httpOnly`, path `/api/v1/auth`, and host-only scope (no `Domain` attribute) are exactly the posture FR-014 requires. Cross-site is declined, so there is no cookie change in this feature.
- **CSRF stays disabled** in both services. FR-007 is a conditional guard on a future relaxation that this feature does not perform.
- **`order-service`'s tenant handling** is unchanged; it derives tenant from the JWT claim and never reads a tenant header.
- **No Redis or database state** is touched, so constitution Principle IV does not apply to this feature.
