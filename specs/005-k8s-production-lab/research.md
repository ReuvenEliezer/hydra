# Phase 0 Research: Kubernetes Production Lab

**Feature**: `005-k8s-production-lab` | **Date**: 2026-08-18 | **Plan**: [plan.md](./plan.md)

This document does two jobs. Section A records what the repository **actually contains today**, confirmed against source before any planning decision was made (Constitution Principle V). Section B records the decisions that resolve every unknown in the plan's Technical Context.

Nothing here is speculation. Where a claim could not be verified without running the cluster, it is labelled a **validation obligation** and carries the check that settles it.

---

## Section A — Audit findings (confirmed against source)

The spec's "Known repository conditions" section listed conditions this feature must address. All were re-confirmed, and the audit found **two additional blockers** the spec did not know about. Both stop a clean-state container build at the first instruction.

### A1. The Maven wrapper does not exist in this repository — NEW, blocking

Both `Dockerfile`s begin:

```dockerfile
COPY mvnw .
COPY .mvn .mvn
```

Neither `mvnw` nor `.mvn/` exists in the working tree or in `git ls-files`. A container build from a clean checkout fails on the first `COPY`, before any Java is compiled. This is not a stale-cache problem; the files were never committed.

**Consequence**: FR-018 (clean-state build verification) cannot pass against the current `Dockerfile`s under any circumstances. This is a pre-existing condition, not one introduced here. Resolved by **D2**.

### A2. `browser-edge-starter` is absent from both image builds — confirmed, blocking

`auth-service/pom.xml` and `order-service/pom.xml` both declare a dependency on `browser-edge-starter` (order-service's is even annotated with a comment pointing at `BrowserEdgeAutoConfiguration`). Neither `Dockerfile` copies that module's POM or its sources; both stop at `infra-shared`, `infra-database`, `rate-limit-starter`.

**Consequence**: exactly as the spec predicted. The reactor build inside the image cannot resolve the dependency. Since `browser-edge-starter` is what emits Hydra's cross-origin headers, an image that somehow built without it would violate the transparent edge contract from the inside — the services would emit no CORS headers at all and Clause 2 would fail for a reason having nothing to do with the gateway. Resolved by **D2**.

### A3. Liquibase is wired correctly, on the classpath, and still does not execute — confirmed by classpath evidence

This finding was re-verified after a challenge, and the verification changed its reasoning entirely. Everything about `auth-service` *looks* wired:

- `liquibase-core:5.0.3` **is** on the runtime classpath — compile scope, transitively via `infra-database` (`mvn dependency:tree` confirms: `auth-service → infra-database → org.liquibase:liquibase-core:5.0.3:compile`).
- `auth-service`'s master changelog sits at `db/changelog/db.changelog-master.yaml` — Spring Boot's **default** changelog location — and includes both `001-init-auth-schema.yaml` and `002-tenant-url-identifier.yaml`.
- No `spring.liquibase.enabled=false` exists anywhere, and no exclusion removes the dependency.

Under Spring Boot 3 that combination runs Liquibase at startup. Under Spring Boot 4.1 it does not, and the reason is not in this repository at all:

| Artifact | `liquibase` entries |
|---|---|
| `spring-boot-autoconfigure:3.4.4` | **19** |
| `spring-boot-autoconfigure:4.1.0` | **0** |

Boot 4 split per-technology auto-configuration out of `spring-boot-autoconfigure` into dedicated modules. `LiquibaseAutoConfiguration` now lives in `org.springframework.boot:spring-boot-liquibase`, which appears **zero** times in either service's dependency tree and is not present in the local repository at all. `liquibase-core` itself ships no `AutoConfiguration.imports` and no `spring.factories`, so it cannot self-register. `infra-database` has no `src/` directory — it is a POM-only aggregator — so no hand-written `SpringLiquibase` bean exists either.

**No class on the runtime classpath creates a `SpringLiquibase` bean. The changelogs do not run.**

The `002-tenant-url-identifier.yaml` banner (`PARITY DOCUMENTATION ONLY - THIS FILE NEVER EXECUTES`) reaches the right conclusion by the wrong route — it tells the reader to "check `auth-service/pom.xml`", where a *transitive* dependency is invisible. That instruction is what makes this finding easy to get wrong in both directions.

`order-service` is a second, independent trap: its master changelog is at `changes/db.changelog-master.yaml`, a **non-default** path with no `spring.liquibase.change-log` pointing at it. Even if the Boot 4 module were added, `order-service`'s changelog would still not be found — and depending on the version's behaviour, adding the module could turn a silent no-op into a startup failure.

**Consequence, unchanged**: the real schema authority is Hibernate `ddl-auto: update` in every profile of both services, and that is the single largest risk to FR-052 and SC-009 — three replicas issuing concurrent DDL against one Postgres is exactly the hazard the spec's edge cases name. Resolved by **D6**.

**Consequence, new and sharper**: this is a *latent* condition, not a stable one. Adding `spring-boot-liquibase` — a one-line change someone will eventually make while "fixing the Liquibase setup" — silently activates two never-executed changelogs against a schema Hibernate has been authoring for the project's lifetime. That upgrade hazard belongs in the documentation regardless of what this lab does, and it strengthens rather than weakens D6's refusal to adopt Liquibase opportunistically.

### A4. `KeyProvider` beans are bound to specific profile names — NEW, constrains the whole deployment

- `LocalKeyProvider` is `@Profile({"local", "test"})` and loads an RSA key from `jwt.private-key-path`.
- `CloudKeyProvider` is `@Profile({"prod", "staging"})` and loads from AWS Secrets Manager.
- `SecurityConfig`'s real filter chain is `@Profile("!local")`.
- `BootstrapService` (first-boot seeding) is `@Profile({"local"})`.
- `H2ConsoleConfig` and `SecurityDebugFilter` are `@Profile("local")`.

**Consequence**: the lab cannot invent a fresh profile name such as `k8s`. Under an unknown profile **no `KeyProvider` bean exists at all** and `auth-service` fails at context startup. The choice is constrained to profiles that already exist, and each carries baggage. Resolved by **D5**.

### A5. The obsolete JVM flag is real, and may be worse than inert

Both images pass `-XX:+UseZGC -XX:+ZGenerational`. Non-generational ZGC was removed in JDK 24, at which point `ZGenerational` became obsolete. Obsolete flags are typically *removed* one release later, at which point the JVM rejects them as unrecognised and **refuses to start**.

**Consequence**: on Java 25 this flag is at best a startup warning and at worst fatal. FR-059 mandates its removal regardless, since removing an inert flag changes nothing. `-Djava.security.egd=file:/dev/./urandom` is a second candidate — it has been a no-op on modern JDKs for years. Resolved by **D3**, with a validation obligation attached.

### A6. Conditions from the spec, re-confirmed without change

| Condition | Confirmed at |
|---|---|
| Rate limiting trusts the left-most `X-Forwarded-For` | `rate-limit-starter/.../ClientIpResolver.java:8-23` — falls back to `getRemoteAddr()`, Javadoc explicitly assumes a reverse proxy sets the header |
| Renewal credential requires secure transport by default | `auth-service/src/main/resources/application.yaml` → `refresh-token.cookie.secure: ${REFRESH_COOKIE_SECURE:true}` |
| Tenant resolution fails closed when unconfigured | `hydra.tenant.base-domains: ${TENANT_BASE_DOMAINS:}` — empty by default, resolves nothing |
| Neither service exposes a metrics endpoint | Neither service declares a `management:` block; `order-service` exposes `health,info` only. No Micrometer registry, no tracing dependency anywhere |
| The conformance suite accepts an external base URL | `TransparentEdgeConformanceTest:38` reads `-Dedge.base-url` and skips its stand-in when set |

### A7. Two findings that make the lab *easier* than expected

**The conformance suite's HTTP client honours JVM trust settings.** `EdgeConformanceAssertions` builds every client with `HttpClients.createDefault()`, which resolves to the JVM's default `SSLContext`. That means the lab's CA can be handed to the suite with `-Djavax.net.ssl.trustStore=...` on the Maven invocation — **no code change at all**, which is exactly what FR-032b asks for and what keeps SC-020 ("zero assertions modified") intact.

**The suite's tenant constants already match the lab's hostnames.** `EdgeConformanceFixture` fixes `acme.localhost` and `beta.localhost`. Choosing `*.localhost` as the lab's tenant domain (**D8**) means the existing constants are correct against the lab with nothing overridden — and it satisfies FR-033's "two distinct tenant hostnames" for free.

---

## Section B — Decisions

### D1. Cluster provisioner and topology — `kind`

**Decision**: `kind` with a three-node config (1 control-plane, 2 workers), `disableDefaultCNI: true`, `kubeProxyMode: none`, and `extraPortMappings` binding host `443` and `80` to fixed node ports on the control-plane node. Worker count is a variable in `versions.env`.

**Rationale**: mandated by the requester and the only provisioner that satisfies the exclusions. Disabling the default CNI is required by FR-011 so Cilium is the sole provider; disabling kube-proxy is required for Cilium's kube-proxy replacement (FR-023) to be genuinely exercised rather than layered on top of an active kube-proxy.

**Alternatives rejected**: minikube, k3d and Docker Desktop's built-in cluster — all excluded by the requester, and k3d additionally ships its own service load balancer and Traefik ingress, which would compete with the mandated Gateway API path.

---

### D2. Container build — replace the wrapper stage with a pinned Maven toolchain image

**Decision**: rewrite the builder stage of both `Dockerfile`s to `FROM maven:<pinned>-eclipse-temurin-25 AS builder`, drop the `COPY mvnw .` / `COPY .mvn .mvn` instructions entirely, invoke `mvn` directly, and add `browser-edge-starter` to both the POM-copy layer and the source-copy layer. The build prints the resolved toolchain (`mvn -version`) as its first step.

**Rationale**: this fixes A1 and A2 in one change and satisfies FR-004 without committing wrapper binaries the repository has deliberately never carried. The toolchain is reproducible and pinned in the version matrix, and "which toolchain performed the build" is answered by build output rather than by assumption. It also means the host's Java version is irrelevant to the image build — the doctor still checks it, because the *local* Maven paths (running the conformance suite) need it.

**Alternatives rejected**:
- *Run `mvn wrapper:wrapper` and commit the wrapper*: adds committed binaries and a second toolchain definition to keep in sync with the version matrix, for no benefit over a pinned base image.
- *Build the JARs on the host and `COPY` them in*: breaks FR-018's clean-state guarantee — the image would silently inherit whatever the host's cache held.

**Validation obligation**: `docker build --no-cache` for both services, from a clean clone, is the FR-018 check. It must pass before any deployment task begins.

---

### D3. JVM flags — remove `ZGenerational`, keep `UseZGC`, measure it

**Decision**: remove `-XX:+ZGenerational` from both images. Keep `-XX:+UseZGC` untouched. Evaluate `-Djava.security.egd=file:/dev/./urandom` against the same inertness test and remove it only if the startup measurement shows no difference. Document every retained flag per FR-059a and publish the ZGC-versus-default comparison as a recommendation for a **separate** decision.

**Rationale**: FR-059 draws the line at provable inertness, and `ZGenerational` is on the wrong side of it (see A5). The collector selection is a genuine behavioural choice and this feature explicitly does not make it — a collector chosen on an arm64 laptop is not a collector chosen for production, and the spec says so.

**Validation obligation**: run `java -XX:+UseZGC -XX:+ZGenerational -version` inside the pinned runtime image *before* editing. If the JVM refuses to start, this is not a cleanup — it is a live bug fix, and that fact belongs in the documentation and the commit message.

---

### D4. Networking layer — Cilium as the single provider

**Decision**: one Helm install of Cilium configured with `kubeProxyReplacement: true`, `l7Proxy: true`, `gatewayAPI.enabled: true`, `envoy.enabled: true`, network policy enforcement, and Hubble (relay + UI) enabled. No second CNI, no MetalLB, no standalone gateway controller.

**Rationale**: Cilium is the only product that satisfies FR-022's list — CNI, policy engine, kernel-level observability, *and* Gateway API implementation — as one component. FR-029 forbids a standalone gateway controller and requires Envoy be consumed as the data plane of that gateway implementation, which is exactly Cilium's model: the Envoy DaemonSet is Cilium's, not an independently-managed application.

**Alternatives rejected**: Calico + Envoy Gateway (two components, and Envoy Gateway is the excluded standalone controller); Istio (a service mesh, explicitly excluded for the initial implementation); NGINX Gateway Fabric (gateway only — leaves CNI, policy and kernel observability unsolved).

**Risk, stated plainly**: Cilium's Gateway API implementation is less configurable than standalone Envoy Gateway. Two requirements depend on configuration surface that may not be exposed — FR-041 (`X-Forwarded-For` replace-not-append) and FR-080 (gateway spans). See **D12** and **D13**.

---

### D5. Spring profile and configuration delivery — `test` profile plus an external config mount

**Decision**: deploy both services with `SPRING_PROFILES_ACTIVE=test`, and supply all lab configuration through (a) environment variables and (b) a ConfigMap mounted at `/config/` and picked up by `SPRING_CONFIG_ADDITIONAL_LOCATION=file:/config/`. No `application-*.yml` is added to either service's resources. The following must be explicitly overridden, because `application-test.yml` sets literal values that placeholders would not have:

| Property | `application-test.yml` value | Lab value | Why it matters |
|---|---|---|---|
| `refresh-token.cookie.secure` | `false` | `true` | FR-032 — the credential's `Secure` attribute is the thing being exercised |
| `refresh-token.grace-ttl` | `PT2S` | `PT5S` (the default) | A 2-second grace window would make FR-067's concurrency result ambiguous |
| `spring.jpa.hibernate.ddl-auto` | `update` | `validate` | See **D6** |
| `spring.datasource.*` | localhost Postgres | in-cluster service DNS | — |
| `hydra.tenant.base-domains` | `localhost` | `localhost` | Already correct |

**Rationale**: A4 leaves four candidate profiles and only one survives. `local` swaps in a permissive security chain (`@Profile("!local")` disables the real one), enables the H2 console and a debug filter, and activates `BootstrapService` — all disqualifying. `prod`/`staging` bind `CloudKeyProvider` to AWS Secrets Manager, unavailable locally, and `prod` additionally forces a server-side TLS keystore that would double-terminate behind the gateway. `test` is the only profile that gives a **file-based** `KeyProvider` — which is precisely what a mounted Kubernetes Secret provides, and what makes FR-047 (identical signing material on every replica) true by construction — while keeping the real security chain and leaving `BootstrapService` inactive, which is FR-052a satisfied for free.

Environment variables outrank profile YAML packaged inside the JAR in Spring's property precedence, so every literal above is overridable without touching the file.

**Alternatives rejected**:
- *Add `"k8s"` to the `@Profile` lists*: a source change to application code, which FR-044 confines away from. Rejected on principle, not on difficulty.
- *Run a local Secrets Manager emulator to use the `prod` profile*: adds a component no requirement asks for, to obtain a key-loading path less faithful to how the lab supplies secrets.

**Consequence to document**: the lab runs its services under a profile named `test`. That is a naming accident of this repository, not a statement about the deployment's seriousness, and FR-055's documentation must say so — otherwise a reader reasonably concludes the lab is running something other than the real configuration.

---

### D6. Schema migration — a pre-deploy Job, with replicas running `validate`

**Decision**: application pods run with `spring.jpa.hibernate.ddl-auto=validate`. Schema creation happens in a Helm pre-install/pre-upgrade hook **Job** that runs exactly one instance of the same service image with `ddl-auto=update` and an exit-after-startup marker, per service, per database. The fixture Job (**D7**) runs after it. Neither Deployment's pods start until both Jobs complete.

**Rationale**: A3 makes this unavoidable. `ddl-auto: update` across three concurrently starting replicas is the failure the spec's edge cases predict, and FR-052 requires migration to *complete before ready* and to *remain correct under concurrent replica startup*. A single-instance Job makes concurrency structurally impossible rather than hopefully absent. Using the service's own image and its own JPA mappings keeps Hibernate as the schema authority — the lab does not get to invent a schema, and it does not adopt Liquibase on the sly, which is a separate decision this feature has no mandate to make.

`validate` on the replicas is a genuine assertion: if the Job's schema and the pods' mappings ever diverge, the pods fail loudly at startup instead of silently re-deriving DDL.

**Alternatives rejected**:
- *Adopt the existing Liquibase changelogs*: activating them means adding `org.springframework.boot:spring-boot-liquibase` (A3), which would run two never-executed changelogs against a schema Hibernate has been authoring since the project began — and would still not find `order-service`'s changelog, which sits at a non-default path. Running never-executed migrations against a schema Hibernate has been creating for the project's lifetime is a data-correctness gamble the lab has no reason to take. Adopting Liquibase is real work with real value — it is simply not this feature's work.
- *Leave `ddl-auto: update` on and rely on `podManagementPolicy`/leader election*: serialising startup to dodge a DDL race is a workaround that also destroys the rolling-update property SC-009 measures.

**Documentation obligation**: FR-052b's sibling. The docs must state that the lab runs Hibernate-authored DDL through a Job, that Liquibase remains unadopted, and that this is a known divergence from a production migration story.

---

### D7. Lab fixture — a Job running SQL against the migrated schema

**Decision**: after the migration Job and before any Deployment, a fixture Job applies a deterministic set of tenants (`acme`, `beta`, plus a third for the "new tenant needs no gateway change" check in FR-040/SC-007) and users with pre-computed BCrypt password hashes. It is idempotent (`ON CONFLICT DO NOTHING`), reapplied identically on every recreation.

**Rationale**: FR-052a. Seeding before traffic means `auth-service`'s users table is never empty, so first-boot bootstrap never runs — which is what makes the concurrent-bootstrap race out of scope rather than accidentally exercised. `BootstrapService` is `@Profile({"local"})` and the lab runs `test`, so it is doubly inactive; the fixture is what makes that safe rather than merely quiet.

**The fixture-drift trap the spec names is real and gets an explicit guard**: a fixture that applies cleanly but produces accounts that cannot sign in fails at the integration flow, not at seeding. So the fixture Job does **not** report success on `INSERT` alone — it ends by performing one real sign-in through the service and failing the Job if the credential is rejected. Seeding that cannot authenticate is a failed seed.

**Documentation obligation**: FR-052b — record that first-boot bootstrap is deliberately bypassed and is neither proven safe nor proven broken here.

---

### D8. Tenant hostnames and local exposure — `*.localhost` over a fixed kind port mapping

**Decision**: tenant addresses are `acme.localhost`, `beta.localhost` and `gamma.localhost`. The Gateway's Service is a NodePort at a fixed port, and kind's `extraPortMappings` binds host `443` to it on the control-plane node. `TENANT_BASE_DOMAINS=localhost`.

**Rationale**: FR-033 requires resolution without hosts-file edits and without elevated privileges. `*.localhost` is reserved by RFC 6761 and resolves to loopback on macOS and mainstream Linux resolvers **without network access**, which matters because the spec requires steady-state operation to work offline. It also matches the constants already baked into `EdgeConformanceFixture`, so the existing suite needs no override to find its tenants (A7).

FR-030 requires *exactly one* deterministic exposure mechanism. A fixed NodePort plus `extraPortMappings` is deterministic by construction — the port is declared in the cluster config, not allocated at runtime — and it works identically on macOS, where Docker bridge addresses are not routable from the host.

**Alternatives rejected**:
- *`sslip.io` / `localtest.me`*: requires working public DNS at request time, contradicting the offline steady-state assumption. Documented as the fallback for a resolver that refuses `*.localhost`.
- *MetalLB or `cloud-provider-kind`*: MetalLB hands out addresses on the Docker network, unreachable from a macOS host. `cloud-provider-kind` adds a second moving part and non-deterministic addressing for no gain over a fixed port.
- *`kubectl port-forward`*: not a documented path from workstation address to serving pod; it bypasses the Service and therefore bypasses part of what FR-030 asks to be documented.

---

### D9. TLS material — a lab CA, one wildcard certificate, one truststore

**Decision**: `certs.sh` generates (idempotently, with expiry checks) a lab CA and a single wildcard certificate for `*.localhost`, stores the pair as a Kubernetes Secret referenced by the Gateway's HTTPS listener, and writes a PKCS#12 truststore to `k8s-lab/.certs/lab-truststore.p12`. Every test invocation that speaks HTTPS is handed that truststore explicitly. Re-running setup renews material that has expired or is within 30 days of expiring.

**Rationale**: FR-032/032a/032b. One wildcard certificate covers every tenant because a tenant is one label in front of the base domain — which is also what makes FR-040 (no per-tenant gateway configuration) true for TLS as well as for routing. The expiry check exists because the spec names the exact failure it prevents: a lab rebuilt months later meets an expired certificate and reads it as a routing fault.

**On the harness**: because `HttpClients.createDefault()` honours the JVM default `SSLContext` (A7), the suite is handed trust via `-Djavax.net.ssl.trustStore=... -Djavax.net.ssl.trustStorePassword=...` on the Maven command line. Disabling verification is not available as a shortcut and must not be added: a harness that skips verification cannot test the `Secure` credential clause it exists to test.

**Alternatives rejected**: `mkcert` — installs into the host's system trust store, which is a host modification the diagnostic explicitly promises not to make (FR-003 in spirit), and still would not configure the JVM's truststore, so it solves nothing the lab actually needs.

---

### D10. Observability stack — Prometheus, Grafana, OTel Collector, Tempo, and an attached Java agent

**Decision**: the OpenTelemetry Java agent JAR is baked into the runtime stage of both images at `/opt/otel/opentelemetry-javaagent.jar` and activated **only** by chart-supplied `JAVA_TOOL_OPTIONS=-javaagent:/opt/otel/opentelemetry-javaagent.jar`. The agent exports OTLP to an OpenTelemetry Collector; the Collector exposes a Prometheus endpoint that Prometheus scrapes, and forwards traces to Tempo. Grafana is the only UI — it queries Prometheus for metrics and Tempo for traces. Logs are structured JSON via the agent's log correlation plus Spring's built-in JSON encoder, configured from the mounted ConfigMap.

**Rationale**: the clarification session settled the mechanism (container-level agent, no source or dependency changes), and A6 confirms neither service has any telemetry capability today — so *everything* observable comes from the agent. Baking the JAR into the image and leaving it inert unless `JAVA_TOOL_OPTIONS` is set means the image is not permanently coupled to the lab. Tempo is chosen over Jaeger specifically because FR-080a forbids a parallel tracing UI: Tempo is queried through Grafana, so the trace store adds a component but not a console.

**Alternatives rejected**: Micrometer + `spring-boot-starter-actuator`'s Prometheus registry — requires a build dependency in both services, which FR-044 and FR-048 forbid outright. Jaeger — a second console, forbidden by FR-080a. Loki — FR-082 explicitly rules out a heavyweight log stack and asks for documentation of production options instead.

**Sampling**: `OTEL_TRACES_SAMPLER=always_on` in the lab (FR-080b). A sampler that discards the request under investigation makes SC-012 untestable. The documentation must state that this is a lab setting and not a production recommendation.

---

### D11. Rate-limited rejections must be distinguishable — via status code, not a new metric

**Decision**: FR-079 is satisfied by the agent's `http.server.request.duration` metric carrying `http.response.status_code`, with dashboards separating `429` from `5xx`. The benchmark's throughput accounting reads the same distinction (FR-105).

**Rationale**: no service change is possible or needed. The limiter already returns a distinct status; the requirement is that the *dashboards and reports* not aggregate it into one error count. That is a dashboard and report design obligation, not an instrumentation one.

---

### D12. `X-Forwarded-For` replace-not-append — the highest-risk requirement

**Decision**: configure Cilium's Gateway API listener so the client address the backend sees is the one the gateway observed, not one the client supplied. Implementation route, in order of preference: (1) the Gateway API `HTTPRoute` `RequestHeaderModifier` filter with a `set` (not `add`) operation on `X-Forwarded-For`; (2) if the gateway's own XFF handling appends after filters run, a `CiliumClusterwideEnvoyConfig` overriding the listener's `use_remote_address` / `xff_num_trusted_hops` and `skip_xff_append` settings directly.

**Rationale**: FR-041 and SC-006 make this a security boundary, not a preference — A6 confirms `ClientIpResolver` trusts the left-most value with no validation, so an appending gateway makes every per-address limit forgeable. Route (1) is pure Gateway API and preferred because it keeps FR-026's "Gateway API is the primary configuration model" intact; route (2) is a documented escape hatch consumed through Cilium's own CRD, which keeps FR-029 intact (still no standalone controller).

**Validation obligation — this is the check, and it is not optional**: send a request with `X-Forwarded-For: 1.2.3.4` from a known client address, exceed the per-address limit, and assert the limiter counted against the observed address. If **neither** route produces replace semantics, that is a finding about Cilium's Gateway API implementation and it belongs in the Edge Finding (FR-113) as a genuine argument against Kubernetes-as-edge — not as a lab defect to be papered over. This decision is where the feature is most likely to discover something that matters.

---

### D13. Gateway spans — attempt Envoy tracing, and report honestly if it cannot be attached

**Decision**: attempt to attach an OpenTelemetry tracing provider to the Gateway's Envoy listener via `CiliumClusterwideEnvoyConfig`, so the trace begins at the gateway. Validate by issuing one request and retrieving a trace containing gateway, `order-service` and `auth-service` spans.

**Rationale**: SC-012 and FR-080 require the gateway to appear as a span, and the agent cannot instrument a proxy it does not run inside. Cilium's Envoy is configurable through its own CRD, which is the only lever available that does not add a component.

**If it cannot be attached**: the trace begins at `order-service`, SC-012 is **not** met, and that is reported as a failure with its cause named — per FR-116, not as a documented divergence quietly absorbed. The remedy would be a gateway change, which is itself evidence for the Edge Finding. Under no circumstance is a partial trace presented as satisfying SC-012.

---

### D14. Backing services — plain charts over official images, not Bitnami

**Decision**: PostgreSQL and Redis are deployed as StatefulSets in the lab's own umbrella chart, using the **same pinned images already in `docker-compose.yml`** (`postgres:16-alpine`, `redis:8.8-alpine`), each with a real readiness probe (`pg_isready`, `redis-cli ping`), credentials from Kubernetes Secrets, and NetworkPolicies restricting them to their permitted callers.

**Rationale**: version parity with the existing compose environment is worth more than chart convenience — a lab that runs a different Postgres than local development is measuring a different system. Bitnami's charts are additionally a licensing and availability hazard following the restriction of their free image catalogue, and a lab whose reproducibility depends on a vendor's registry policy is not reproducible.

**Alternatives rejected**: Bitnami charts (above); CloudNativePG (a production-grade operator whose value is in failover and backup — neither of which this lab exercises, and both explicitly out of scope).

---

### D15. Declarative delivery — Argo CD against a local git remote

**Decision**: Argo CD, watching a bare git repository created inside the lab (or the working repository itself) at `k8s-lab/gitops/`. One root Application reconciles the umbrella chart. Secrets are **never** committed: the tracked tree references Secret names that `setup` creates out of band, and the delivery loop is demonstrated by changing a non-secret tracked value (replica count) and observing convergence with no deploy command.

**Rationale**: FR-083, FR-085, FR-086, FR-088. Argo CD is chosen over Flux for one concrete reason — FR-088 requires a *delivery console* reachable by its own access operation, and Argo CD ships one. Flux would require adding a separate UI, which is a component no requirement asks for.

---

### D16. Cluster console — Headlamp

**Decision**: Headlamp, installed in-cluster, reached by its own `make` target.

**Rationale**: FR-087 says *install* a lightweight cluster console covering nodes, namespaces, pods, deployments, services, events, logs and resource usage. Headlamp is in-cluster, lightweight, and covers all eight. k9s was considered and rejected on the wording: it is a terminal client installed on the host, not a console installed in the cluster, and FR-088's "each behind its own access operation" implies a reachable endpoint. The Kubernetes Dashboard was rejected as heavier and awkward to expose.

---

### D17. Test implementation language — Bash against the real cluster, plus the existing Java suite

**Decision**: `smoke`, `integration`, `failure` and `perf` suites are Bash, driving `kubectl`, `curl` and `jq` against the running cluster, with a tiny shared assertion library and per-check PASS/FAIL lines feeding a single overall verdict and exit code. The only Java-side execution is Hydra's existing `edge-conformance` suite, invoked through Maven with `-Dedge.base-url` and the truststore properties.

**Rationale**: FR-092 requires execution against the actual cluster and FR-102/SC-020 require existing suites to pass unchanged. Adding a Maven module for lab tests would put lab concerns in the reactor, which the scope boundary rules out. The two genuinely concurrent tests (FR-067's ≥100 simultaneous rotations, FR-068's cross-replica limit) are expressible with `xargs -P` over `curl` and verified by counting successes — no JVM needed.

**One open item, flagged rather than hidden**: `TransparentEdgeConformanceTest` starts its in-process fixture (a Spring context plus a Redis Testcontainer) *before* checking `edge.base-url`, so pointing it at the lab still pays that startup cost. The assertions are untouched either way. Moving the override check above the fixture start would be a change to `@BeforeAll` — not to an assertion — and so does not violate SC-020 on a literal reading. **Recommendation: do not make it.** Accept the startup cost. The cost is seconds; the value of being able to say "the conformance suite file was not edited at all" is the entire point of SC-020, and it is worth more than the seconds.

---

### D18. Reduced-footprint mode — a values overlay, with an honest statement of what it disables

**Decision**: `values-reduced.yaml` lowers replica counts to the minimum that still exercises multi-instance behaviour (2, not 1 — a single replica cannot satisfy FR-069), disables Tempo and Hubble UI, and trims resource requests. Workloads, Deployments, Services, Gateway API, Cilium, network policy, Postgres, Redis and autoscaling all remain.

**Rationale**: FR-091. The requirement to state that the end-to-end trace scenario is *unavailable* rather than passing is the important half: `make test` in reduced mode must report SC-012 as SKIPPED-BY-CONFIGURATION, never as PASS. A test that silently stops checking is worse than a test that fails.

---

## Risk register

Ordered by likelihood of derailing the feature.

| # | Risk | Impact | Mitigation / where it surfaces |
|---|---|---|---|
| 1 | Cilium Gateway API cannot be made to replace `X-Forwarded-For` | FR-041, SC-006 fail | D12 — two routes attempted; failure is a genuine Edge Finding, not a defect to hide |
| 2 | Envoy tracing cannot be attached to the Cilium gateway | SC-012, FR-080 fail | D13 — reported as a failure with cause; never presented as a partial pass |
| 3 | `ddl-auto` Job approach diverges from replica mappings | Pods crash-loop on `validate` | D6 — this is the intended loud failure; caught at the first deploy, not in production |
| 4 | `-XX:+ZGenerational` is fatal, not merely obsolete, on Java 25 | Current images may not start at all | D3 — verified before editing; if fatal, it is a live bug and is reported as one |
| 5 | Workstation cannot fit the full profile (3 nodes + 6 app pods + 2 stateful + observability) | SC-016 unprovable | D18 reduced mode; FR-072 requires the scaling test to report the constraint, never a false PASS |
| 6 | `*.localhost` not resolved by some resolver | Tenant resolution untestable | D8 documented fallback to a public wildcard domain, with the offline caveat stated |
| 7 | Pinned component versions are not mutually compatible | Setup fails mid-checkpoint | FR-007 — compatibility basis recorded in the version matrix; checkpoints stop at the failure rather than continuing |

## Unknowns remaining

**None blocking.** Every NEEDS CLARIFICATION from the Technical Context is resolved above. The two items that cannot be settled without executing the cluster — D12 and D13 — are not unknowns in the planning sense: the approach is decided, the validation is defined, and the reporting obligation on failure is written down. Per FR-116, neither may be reported complete on the strength of generated files.
