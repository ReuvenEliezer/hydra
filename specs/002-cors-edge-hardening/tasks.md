---

description: "Task list for 002-cors-edge-hardening"
---

# Tasks: Browser Edge Hardening

**Input**: Design documents from `/specs/002-cors-edge-hardening/`

**Prerequisites**: [plan.md](plan.md), [spec.md](spec.md), [research.md](research.md), [data-model.md](data-model.md), [contracts/](contracts/)

**Tests**: Test tasks below are **not discretionary**. FR-016 makes the conformance suite a deliverable of the feature, and SC-009/SC-012 ("zero such instances reach a ready state") are only verifiable by an automated check. Validator tests are included for the same reason: FR-010, FR-017, and FR-018 are startup behaviours whose whole contract is *which* configurations are fatal and what the message names.

**Organization**: Grouped by user story so each is independently implementable and testable.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: US1–US4, mapping to spec.md user stories
- Exact file paths in every description

## Path Conventions

Maven multi-module, flat at repository root. New module `browser-edge-starter/`; existing `auth-service/`, `order-service/`, `integration-tests/`.

Maven is invoked through the wrapper distribution — this repo has **no** `mvnw` and `mvn` is not on `PATH`:

```bash
export MVN=~/.m2/wrapper/dists/apache-maven-3.9.16-bin/5grr65jo27hi51sujmtcldfovl/apache-maven-3.9.16/bin/mvn
```

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Create the module and put it in the reactor

- [X] T001 Create `browser-edge-starter/pom.xml` with parent `com.reuven:hydra:0.0.1-SNAPSHOT`, artifactId `browser-edge-starter`, packaging `jar`. Copy the dependency shape of `rate-limit-starter/pom.xml`: `spring-boot-starter-web`, `lombok` (optional, with the `annotationProcessorPaths` compiler-plugin block), `spring-boot-starter-test` + `assertj-core` at test scope. Add `com.google.guava:guava` **explicitly** with an explicit version property — research R3 requires it be declared, never relied on transitively. Write a `<description>` in the style of `rate-limit-starter`'s, stating why this is not in `infra-shared` (Principle I: `CorsConfiguration` is a Spring type)
- [X] T002 Add `<module>browser-edge-starter</module>` to the root `pom.xml` module list, positioned **before** `auth-service` and `order-service` so the reactor builds it first
- [X] T003 Create the package directory `browser-edge-starter/src/main/java/com/reuven/browseredge/` and the resource directory `browser-edge-starter/src/main/resources/META-INF/spring/`

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: The configuration records, the validator, and the auto-configuration that every user story builds on

**⚠️ CRITICAL**: No user story work can begin until this phase is complete

- [X] T004 [P] Create `browser-edge-starter/src/main/java/com/reuven/browseredge/BrowserOriginProperties.java` — a `@ConfigurationProperties(prefix = "hydra.cors")` record with `List<String> allowedOriginPatterns` and `Duration maxAge`, compact constructor turning null into `List.of()` / `PT30M` and defensively copying (data-model.md §1). Port the class Javadoc from `auth-service/src/main/java/com/reuven/auth/config/CorsProperties.java` — it explains why patterns are not `"*"` and why that distinction keeps `allowCredentials(true)` legal, which is the single most load-bearing comment in the current code
- [X] T005 [P] Create `browser-edge-starter/src/main/java/com/reuven/browseredge/ControlledDomainProperties.java` — a `@ConfigurationProperties(prefix = "hydra.tenant")` record with `List<String> baseDomains`, carrying over the normalization from `auth-service/src/main/java/com/reuven/auth/config/TenantResolutionProperties.java` **verbatim** (trim, blank-filter, `toLowerCase(Locale.ROOT)`, null → empty). 003's tenant-resolution tests depend on these exact semantics; changing them here breaks tenant resolution, not just CORS
- [X] T006 [P] Create `browser-edge-starter/src/main/java/com/reuven/browseredge/InvalidOriginPolicyException.java` — an unchecked exception whose message names the offending value and the reason. Every startup failure in this feature must name what was wrong (FR-010, FR-017, FR-018); a generic message makes the fail-closed behaviour undiagnosable
- [X] T007 Create `browser-edge-starter/src/main/java/com/reuven/browseredge/OriginPatternValidator.java` implementing the controlled-domain rule in data-model.md §3: strip scheme and port, accept an exact base-domain match or a single-label `*.<base-domain>` wildcard, reject everything else. Use Guava `InternetDomainName.isPublicSuffix()` for the FR-018 base-domain check — **not** a label-count rule, because `localhost` is a legitimate single-label base domain and a count rule would refuse to start every local environment (research R3). Keep it a plain object over `List<String>`, constructor-injected, so it is unit-testable with no Spring context — the same pattern `TenantHostParser` uses (depends on T005, T006)
- [X] T008 Create `browser-edge-starter/src/main/java/com/reuven/browseredge/BrowserEdgeAutoConfiguration.java` — `@AutoConfiguration`, `@EnableConfigurationProperties({BrowserOriginProperties.class, ControlledDomainProperties.class})`, contributing a `corsConfigurationSource()` bean of type `CorsConfigurationSource`. **Keep the bean name and type identical** to the beans it replaces so `http.cors(Customizer.withDefaults())` in `SecurityCommons` resolves it unchanged. Port the policy verbatim from `auth-service/.../config/CorsConfig.java`: methods `GET`/`POST`/`OPTIONS`; headers `Authorization`/`Content-Type`/`Accept` (**no** `X-Tenant-ID` — 003 removed it deliberately); exposed `Retry-After`; `allowCredentials(true)`; `setAllowedOriginPatterns(...)`; max-age from properties (depends on T004, T007)
- [X] T009 In `BrowserEdgeAutoConfiguration`, implement the four startup outcomes from data-model.md §4 in the bean factory method so failures abort context refresh before the port binds (research R4): empty pattern list → `WARN` and start; pattern outside the controlled set → throw; base domain that is a public suffix → throw. **Preserve the asymmetry between the first two** — an empty list is safe but useless, an over-broad pattern echoes credentials to an arbitrary origin. Collapsing them either way is a defect (depends on T008)
- [X] T010 Create `browser-edge-starter/src/main/resources/META-INF/spring/org.springframework.boot.autoconfigure.AutoConfiguration.imports` containing the single line `com.reuven.browseredge.BrowserEdgeAutoConfiguration`. This path is a functional contract (Principle III) — misspelled or missing, the module loads nothing and every service silently loses CORS with no error (depends on T008)
- [X] T011 [P] Create `browser-edge-starter/src/test/java/com/reuven/browseredge/OriginPatternValidatorTest.java` covering every row of the data-model.md §3 table, including the `localhost` case that must be **accepted** and the `base-domains: com` case that must be **rejected** even though its pattern is well-formed against it (depends on T007)

**Checkpoint**: The module builds and validates in isolation. No service consumes it yet.

---

## Phase 3: User Story 1 - One place to change the origin policy (Priority: P1) 🎯 MVP

**Goal**: The origin policy exists in exactly one place, both services consume it, and a dangerous pattern is fatal at startup.

**Independent Test**: Change `hydra.cors.allowed-origin-patterns` in one location, start both services, and confirm both accept a matching origin with credentials and readable `Retry-After`. `grep -rn "hydra.cors" --include=*.java` must return hits in `browser-edge-starter` only.

### Implementation for User Story 1

- [X] T012 [P] [US1] Add the `browser-edge-starter` dependency to `auth-service/pom.xml`
- [X] T013 [P] [US1] Add the `browser-edge-starter` dependency to `order-service/pom.xml`
- [X] T014 [US1] Delete `auth-service/src/main/java/com/reuven/auth/config/CorsProperties.java` and `auth-service/src/main/java/com/reuven/auth/config/CorsConfig.java`. Deletion is the requirement, not a side effect — a surviving local record would bind `hydra.cors` a second time with its own semantics, which is exactly the drift FR-001 removes (depends on T012)
- [X] T015 [US1] Delete `order-service/src/main/java/com/reuven/orderservice/config/CorsProperties.java` and `order-service/src/main/java/com/reuven/orderservice/config/CorsConfig.java` (depends on T013)
- [X] T016 [US1] Remove the `baseDomains` component from `auth-service/src/main/java/com/reuven/auth/config/TenantResolutionProperties.java`, leaving `reservedIdentifiers` and its normalization. Update the class Javadoc, which currently documents `baseDomains` at length (depends on T005)
- [X] T017 [US1] In `auth-service/src/main/java/com/reuven/auth/config/TenantResolutionConfig.java`, inject `ControlledDomainProperties` alongside `TenantResolutionProperties`, source the `TenantHostParser` constructor argument and the empty-list warning from it, and change `@EnableConfigurationProperties` accordingly. Its Javadoc references `CorsConfig`, now deleted — repoint it at `BrowserEdgeAutoConfiguration`. **This task and T016 must land in the same commit**: a half-applied move binds nothing and fails closed silently, with no error to point at (Principle III, research R7) (depends on T016)
- [X] T018 [US1] Add a `hydra.tenant.base-domains` block to `order-service/src/main/resources/application.yaml` using the same `${TENANT_BASE_DOMAINS:}` placeholder style as `auth-service/src/main/resources/application.yaml:49`. **order-service has no `hydra.tenant` block today** — without this its controlled-domain set is empty, every configured pattern is invalid under FR-010, and the service refuses to start. This is the one task whose omission breaks a working service (depends on T009)
- [X] T019 [P] [US1] Set `hydra.tenant.base-domains: localhost` in `order-service/src/main/resources/application-local.yml`, matching `auth-service/src/main/resources/application-local.yml:28` (depends on T018)
- [X] T020 [US1] Verify no YAML key changed anywhere: `grep -rn "allowed-origin-patterns\|base-domains" --include="*.yml" --include="*.yaml" auth-service/src order-service/src` must show the same keys as before this feature, in all six files. A renamed key binds to nothing and fails closed with no error — the one no-error failure mode of this change (research R7)
- [X] T021 [P] [US1] Add a startup test in `browser-edge-starter/src/test/java/com/reuven/browseredge/BrowserEdgeAutoConfigurationTest.java` asserting each outcome in data-model.md §4: valid config refreshes; empty list refreshes with a warning; over-broad pattern fails refresh naming the pattern; public-suffix base domain fails refresh naming the domain (depends on T009)
- [X] T022 [US1] Build the reactor and confirm auth-service and order-service still start on the `local` profile with their existing configuration unchanged: `$MVN -q clean install -DskipTests` then start each service (depends on T014, T015, T017, T019)

**Checkpoint**: The policy is defined once, both services consume it, dangerous configuration is fatal. This is a complete, shippable increment.

---

## Phase 4: User Story 2 - One emitter, identical in every deployment (Priority: P1)

**Goal**: Prove the services are the sole emitter and that an edge adding its own headers is caught.

**Independent Test**: Run the front-end against a direct-to-service deployment and behind the transparent stand-in; exactly one `Access-Control-Allow-Origin` in each, naming the single requesting origin, never `*`.

### Implementation for User Story 2

- [X] T023 [US2] Create `integration-tests/src/test/java/com/reuven/integration/edge/StandInProxies.java` — two Testcontainers nginx configurations: a **transparent** one (`proxy_set_header Host $http_host`, no CORS directives) and a **hostile** one (rewrites `Host` to the upstream name and injects its own `Access-Control-Allow-Origin`). nginx is scaffolding, not an edge recommendation; record that in the class Javadoc per research R5 and the spec's Assumptions
- [X] T024 [US2] Create `integration-tests/src/test/java/com/reuven/integration/edge/TransparentEdgeConformanceTest.java` tagged `@Tag("edge-conformance")`, resolving its target from the `edge.base-url` system property and defaulting to the transparent stand-in from T023 (depends on T023)
- [X] T025 [US2] Implement contract Clause 2 in `TransparentEdgeConformanceTest` — assert exactly one set of cross-origin response headers reaches the client, and that they came from the service, not the edge (FR-003, FR-015, contracts/transparent-edge-contract.md) (depends on T024)
- [X] T026 [P] [US2] Implement contract Clause 3 in `TransparentEdgeConformanceTest` — an unauthenticated `OPTIONS` preflight succeeds and never returns `401`, both direct and through the stand-in (FR-005) (depends on T024)
- [X] T027 [P] [US2] Implement the echoed-origin assertion in `TransparentEdgeConformanceTest` — the response names the single requesting origin, never a literal `*`, which browsers reject on credentialed requests (FR-009) (depends on T024)
- [X] T028 [US2] Add the negative run: assert the suite **fails**, naming each violated clause, when pointed at the hostile stand-in. This is what makes the suite meaningful — one that only ever meets a correct edge cannot distinguish "the edge is transparent" from "the assertions no longer work" (research R5, SC-009) (depends on T025, T026, T027)
- [X] T029 [P] [US2] Add an origin-policy rejection log assertion so a rejection is distinguishable from an authentication or authorization failure in service logs (FR-008)

**Checkpoint**: The single-emitter property is enforced and self-verifying.

---

## Phase 5: User Story 3 - The edge preserves the tenant's address (Priority: P1)

**Goal**: `Host` survives the request path intact, and an edge that breaks it is caught before users are.

**Independent Test**: Send a request through the deployed edge addressed to a tenant host; the host auth-service observes is byte-for-byte the host the client addressed.

### Implementation for User Story 3

- [X] T030 [US3] Implement contract Clause 1 in `integration-tests/src/test/java/com/reuven/integration/edge/TransparentEdgeConformanceTest.java` — assert the host auth-service observes equals the host the client addressed, byte for byte, through the transparent stand-in (FR-011, FR-012) (depends on T024)
- [X] T031 [US3] Assert the hostile stand-in's `Host` rewrite is detected and reported as a Clause 1 failure. Without this the highest-severity failure in the feature — every tenant resolving to `unknown`, a total outage — has no test (depends on T030, T023)
- [X] T032 [P] [US3] Assert `X-Forwarded-Host` is **not** honoured as a substitute for `Host`. 003 explicitly rejected forwarded-header semantics, so an edge that sets only `X-Forwarded-Host` must fail the contract rather than appear to satisfy it (contracts/transparent-edge-contract.md Clause 1) (depends on T030)
- [X] T033 [P] [US3] Implement contract Clause 5 — provisioning a new tenant requires no edge configuration change and no deployment (FR-013, SC-007) (depends on T024)
- [X] T034 [US3] Verify SC-010 end to end: run the suite against an arbitrary base URL via `-Dedge.base-url=...` and confirm a pass/fail verdict is produced with **zero** new test code. If validating a candidate edge requires editing tests, SC-010 is not met (depends on T030, T033)

**Checkpoint**: The full five-clause edge contract is executable and proven to detect its own violation.

---

## Phase 6: User Story 4 - Cross-site fails at configuration time (Priority: P2)

**Goal**: An unsupported topology is a loud startup error, not a silent sign-out at first expiry.

**Independent Test**: Configure a cross-site topology; the service reports it explicitly at startup rather than starting cleanly and failing at first renewal.

### Implementation for User Story 4

- [X] T035 [US4] Add the single-registrable-domain check to `browser-edge-starter/src/main/java/com/reuven/browseredge/OriginPatternValidator.java`: if the configured base domains span more than one registrable domain, throw, naming every conflicting domain. Research R6 explains why a per-pattern check cannot catch this — each pattern is individually valid, and only the pairing is cross-site (FR-017) (depends on T007)
- [X] T036 [P] [US4] Extend `browser-edge-starter/src/test/java/com/reuven/browseredge/OriginPatternValidatorTest.java` with the `base-domains: hydra.example.com,otherapp.io` case, asserting refusal and that the message names both domains (depends on T035)
- [X] T037 [US4] Document the supported and unsupported topologies (FR-006): same-registrable-domain including per-tenant subdomains and local development across ports is supported; cross-registrable-domain is **not**. State it where an engineer will find it without reading service source (SC-003), and record that FR-007 governs any future reversal
- [X] T038 [P] [US4] Add a regression test asserting `auth-service/src/main/java/com/reuven/auth/service/CookieUtil.java` still issues the credential `SameSite=Strict`, `httpOnly`, host-only (no `Domain` attribute), path `/api/v1/auth`. FR-014's failure mode is a future "fix" that broadens the cookie to span tenant subdomains and leaks one tenant's credential to another's host — this test is what stops it
- [X] T039 [P] [US4] Add an assertion that CSRF remains disabled in both services and that no credential-bearing endpoint accepts a cross-site request, documenting that FR-007 is a conditional guard this feature does not trigger (SC-005)

**Checkpoint**: All four stories independently functional.

---

## Phase 7: Polish & Cross-Cutting Concerns

- [X] T040 [P] Run the full quickstart: all seven scenarios in [quickstart.md](quickstart.md), including the counter-check in Scenario 1 and the two-stand-in run in Scenario 4
- [X] T041 [P] Confirm 003's tenant-resolution tests pass unchanged after `baseDomains` moved out of `TenantResolutionProperties` — especially base-domain normalization, which moved verbatim in T005
- [X] T042 [P] Update the repository `README.md` with the transparent-edge contract and a pointer to [contracts/transparent-edge-contract.md](contracts/transparent-edge-contract.md), so whoever stands up a real edge meets the constraints before writing configuration, not after
- [X] T043 Add the `edge-conformance` tagged suite to CI so SC-009 is enforced on every build rather than run by hand
- [X] T044 [P] Verify Principle III compliance across the whole change: every load site in the research R7 table updated together — both property keys unchanged, the `AutoConfiguration.imports` path present and correctly spelled, both records registered by the auto-configuration, `SecurityCommons` untouched
- [X] T045 Re-confirm the research R8 blast radius held: `SecurityCommons.authRules` `OPTIONS /**` backstop intact, `CookieUtil` untouched, CSRF still disabled, order-service still deriving tenant from the JWT claim, no Redis or database state touched

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies
- **Foundational (Phase 2)**: Depends on Setup — **blocks all user stories**
- **US1 (Phase 3)**: Depends on Foundational. Delivers the MVP
- **US2 (Phase 4)** and **US3 (Phase 5)**: Depend on Foundational. Share `TransparentEdgeConformanceTest` and the stand-ins, so they are best built **together by one person** rather than split — splitting them means two people editing the same test class
- **US4 (Phase 6)**: Depends on Foundational (T007). Independent of US2/US3 and can run alongside them
- **Polish (Phase 7)**: Depends on all desired stories

### Critical sequencing

- **T016 and T017 must land in the same commit.** Moving `baseDomains` out of `TenantResolutionProperties` without repointing `TenantResolutionConfig` binds nothing and fails closed silently — no compile error, no runtime error, just every host resolving to `unknown`
- **T018 before any order-service startup.** order-service has no `hydra.tenant` block today; once T009's validation is live, an empty controlled-domain set makes every pattern invalid and the service refuses to start
- **T028 and T031 are not optional polish.** They are what prove the conformance suite detects failure. Without them the suite can pass forever while asserting nothing

### Parallel Opportunities

- T004, T005, T006 are independent files — fully parallel
- T012 and T013 touch different POMs
- T026, T027 are independent assertions once T024 exists
- T032, T033 likewise once T030 exists
- US4 (Phase 6) can proceed in parallel with US2/US3 entirely
- Most of Phase 7 is parallel

---

## Parallel Example: Phase 2 Foundational

```bash
# Three independent record/exception files:
Task: "Create BrowserOriginProperties.java in browser-edge-starter/src/main/java/com/reuven/browseredge/"
Task: "Create ControlledDomainProperties.java in browser-edge-starter/src/main/java/com/reuven/browseredge/"
Task: "Create InvalidOriginPolicyException.java in browser-edge-starter/src/main/java/com/reuven/browseredge/"
```

---

## Implementation Strategy

### MVP First (User Story 1 only)

1. Phase 1: Setup — module in the reactor
2. Phase 2: Foundational — records, validator, auto-configuration
3. Phase 3: US1 — extraction, deletion, wiring
4. **STOP and VALIDATE**: quickstart Scenarios 1, 2, 3. The `grep` counter-check in Scenario 1 is the real test — if either service still mentions `hydra.cors` in Java, the duplication survived
5. Shippable: the policy is defined once and dangerous configuration is fatal, with no edge work done at all

### Incremental Delivery

1. Setup + Foundational → module ready
2. US1 → **MVP**: duplication gone, startup validation live
3. US2 + US3 together → the edge contract becomes executable and self-verifying
4. US4 → topology validation and cookie regression guards
5. Polish → CI enforcement and documentation

### Note on parallel team strategy

The usual "one developer per story" split does **not** apply cleanly here. US2 and US3 both build `TransparentEdgeConformanceTest`, so assign them to one person. A viable two-person split is: US1 then US4 for one, US2 + US3 for the other, after Foundational is done by either.

---

## Notes

- `[P]` = different files, no dependencies on incomplete tasks
- Commit after each task or logical group; T016+T017 must be one commit
- Every startup failure message must name the offending value — a generic message makes fail-closed behaviour undiagnosable
- `hydra-ui`'s front-end tests currently fail in this environment for unrelated reasons (an `msw`/Node incompatibility, ~54 of 91 failing before any change). Do not read those as a regression from this work
