# Feature Specification: Kubernetes Production Lab

**Feature Branch**: `005-k8s-production-lab`

**Created**: 2026-08-18

**Status**: Draft

**Input**: User description: `specs/005-k8s-production-lab/requirements` — build, run, test, validate, document, break, fix and re-validate a complete local Kubernetes platform laboratory. Refined by the requester: the lab runs **Hydra's own `auth-service` and `order-service`**, not purpose-built demonstration services.

## Overview

Hydra needs production-grade Kubernetes knowledge and, separately, needs to settle an open architectural question its constitution records as unresolved: whether the edge in front of its services is Kubernetes-based or a plain proxy plus compose. This feature answers both with one artifact — a reproducible Kubernetes laboratory, running entirely on a developer workstation, that carries **Hydra's real services** rather than a demonstration stand-in.

That choice is what gives the lab its value and its difficulty. A tutorial service proves that a gateway can route. Hydra's services prove considerably more, because they impose real constraints that a stand-in cannot:

- Tenant identity is derived **solely** from the request's `Host` header, so any edge that rewrites `Host` causes a total outage rather than a degraded path.
- The renewal credential is a `Secure`, `SameSite=Strict`, host-only cookie, so the gateway must terminate TLS and must not touch cookies.
- Per-IP rate limiting trusts the left-most `X-Forwarded-For` value, so the gateway's forwarded-header discipline is a security boundary, not a convenience.
- Refresh-token rotation is atomic by design because Hydra is a multi-instance system — a property the project has never yet exercised under real multi-instance conditions.
- Cross-origin policy is emitted by the services alone, so a gateway with default CORS handling enabled breaks every browser call.

These constraints are already written down as [the transparent edge contract](../002-cors-edge-hardening/contracts/transparent-edge-contract.md), and there is already an executable conformance suite that can be pointed at any base URL. This lab is the first time that contract meets a real gateway.

The lab is built to be destroyed and rebuilt on demand. Every claim it makes about its own health must be produced by an executed check, never asserted.

## Clarifications

### Session 2026-08-18

- Q: Neither service currently exposes a metrics endpoint for the mandated metrics system, nor emits traces — how should that instrumentation be added? → A: Attach an instrumentation agent at container level; no source or dependency changes to either service, so FR-044 stands as written.
- Q: `auth-service` seeds the system tenant and super-admin on first boot only when the users table is empty — what should the lab do about several replicas running that check at the same time? → A: Out of scope. The lab pre-seeds a fixture so first-boot bootstrap never runs; the concurrent-bootstrap race is explicitly not exercised and is recorded as a coverage gap.
- Q: Should terminating TLS at the gateway be a hard pass/fail requirement, or may the lab fall back to plain HTTP with the divergence written down? → A: Hard requirement, no fallback. Local execution stays simple because tenant hostnames resolve without host-file changes or elevated privileges, certificate and authority generation is automated and idempotent in setup, and the test harness is handed the lab authority explicitly — preserving full fidelity for the `Secure` credential and for edge-contract compliance.
- Q: Where should traces actually be stored so a request can be looked up by its trace identifier? → A: A single lightweight trace store, surfaced through the dashboard system already mandated — one added component, no second console, and SC-012 stands as written.
- Q: Is changing the JVM flags currently baked into the service images in scope for this feature? → A: Remove only the flag that is provably inert on the mandated Java version. The collector choice stays as-is, is measured by the benchmark, and feeds a recommendation for a separate decision — this feature does not change it.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Reproducible platform from a clean machine (Priority: P1)

An engineer with a clean workstation runs one diagnostic command that tells them exactly what is missing, installs the named prerequisites, and then runs one setup command. Some minutes later they have a multi-node Kubernetes cluster with a real networking layer, a real gateway and a local image registry — plus a printed summary of what was created and whether it is healthy.

**Why this priority**: Nothing else exists without it. A platform that cannot be recreated on demand is a pet, and a pet teaches nothing about production. Cluster plus networking plus a gateway returning a response is a viable MVP on its own.

**Independent Test**: On a machine with only the documented prerequisites, run the diagnostic, then setup, then the cluster/networking/gateway status commands. The environment reports healthy and a request from the workstation reaches the cluster through the gateway.

**Acceptance Scenarios**:

1. **Given** a workstation missing one required tool, **When** the engineer runs the environment diagnostic, **Then** the output names that tool as failing, states what is required, and exits non-zero without installing anything.
2. **Given** all prerequisites satisfied, **When** the engineer runs the diagnostic, **Then** every check reports PASS and the environment is declared READY.
3. **Given** a READY environment and no existing cluster, **When** the engineer creates the cluster, **Then** one control-plane node and two worker nodes reach Ready, and no workload is scheduled into the default namespace.
4. **Given** a created cluster, **When** the engineer inspects networking status, **Then** the networking layer reports healthy on every node and a connectivity check exercising real pod-to-pod and pod-to-service traffic passes.
5. **Given** a healthy networking layer, **When** the engineer inspects gateway status, **Then** a gateway class exists, the gateway reports programmed, and a request from the workstation to the documented local address receives a response produced inside the cluster.
6. **Given** the environment is being created, **When** any checkpoint fails, **Then** the run stops there, prints the failure with diagnostic context, and reports no success for later stages.

---

### User Story 2 - Hydra's real services running in Kubernetes (Priority: P2)

An engineer builds `auth-service` and `order-service` from this repository's own build, publishes them to the lab registry under immutable tags, and deploys them alongside the backing datastore and cache they actually require. They then complete a real end-to-end flow: sign in through the gateway, receive a token, and use it to create and list orders — with `order-service` validating that token against `auth-service`'s published key set, resolved through cluster DNS.

**Why this priority**: This is what separates the lab from a tutorial. It is also where the unglamorous production problems live — schema migration on startup, secret material, credential wiring, and a container build that must actually produce a working image from a multi-module reactor.

**Independent Test**: Build and publish both images, deploy the full application namespace, then drive the sign-in → create-order → list-orders flow entirely through the gateway from the workstation. Confirm neither service is reachable from outside the cluster except through the gateway.

**Acceptance Scenarios**:

1. **Given** the repository source, **When** the engineer builds the service images, **Then** each image builds successfully from the multi-module reactor including every module the service actually depends on, and is tagged with an immutable revision-derived tag.
2. **Given** built images, **When** the engineer publishes and deploys them, **Then** the cluster pulls from the lab registry without contacting a public image host, and all pods reach Ready.
3. **Given** a deployed environment seeded with the lab fixture, **When** an engineer signs in through the gateway with fixture credentials for a tenant, **Then** they receive an access token and a renewal credential, and the credential's attributes are unchanged from what the service issued.
4. **Given** a valid access token, **When** the engineer creates and then lists orders through the gateway, **Then** both succeed, and the token was validated by `order-service` against the key set it fetched from `auth-service` over cluster DNS using a service name.
5. **Given** the services require a relational store and a cache, **When** the platform is installed, **Then** both are running in the cluster, reachable only by the workloads permitted to reach them, and each service's schema is migrated before that service reports ready.
6. **Given** database credentials, cache credentials and signing key material are required, **When** the engineer inspects the deployment, **Then** none of them appear in source, manifests, charts or images, and each is supplied through a secret the documentation maps to its production equivalent.
7. **Given** the build host's default Java toolchain is older than the mandated version, **When** the engineer builds, **Then** the build uses a containerised toolchain of the mandated version or fails loudly, and states which toolchain performed the build.

---

### User Story 3 - The gateway proves it is transparent (Priority: P3)

An engineer points Hydra's existing edge-conformance suite at the lab's gateway address and it passes — every clause of the transparent edge contract, executed against a real gateway rather than a stand-in. They then deliberately misconfigure the gateway to rewrite `Host` and to emit its own cross-origin headers, and watch the same suite fail.

**Why this priority**: This is the story that makes the lab worth building for Hydra specifically, rather than as a generic exercise. The contract was written to keep the Kubernetes-versus-compose decision open; this story is where that decision finally gets evidence. It ranks below US2 only because there must be something running to route to.

**Independent Test**: Run the existing `edge-conformance`-tagged suite against the lab gateway's base URL. It must pass unmodified. Then apply the documented hostile-edge configuration and confirm the same suite fails, naming the violated clause.

**Acceptance Scenarios**:

1. **Given** the lab gateway is serving Hydra's services, **When** the existing edge-conformance suite runs against the gateway's base URL, **Then** every clause passes with no modification to the suite's assertions.
2. **Given** a request addressed to a tenant hostname, **When** it traverses the gateway, **Then** the service receives the original `Host` unmodified, and tenant resolution yields that tenant rather than `unknown`.
3. **Given** a cross-origin browser request, **When** the response returns through the gateway, **Then** exactly one set of cross-origin headers is present and the gateway contributed none of it.
4. **Given** a cross-origin preflight request, **When** it reaches the gateway, **Then** the gateway forwards it to the service unauthenticated and does not answer it itself.
5. **Given** a sign-in response carrying the renewal credential, **When** it passes through the gateway, **Then** the credential's attributes — including its restricted same-site setting, its host-only scope and its path scope — arrive at the browser exactly as issued.
6. **Given** a new tenant is added, **When** it is used, **Then** no gateway configuration change was required for it to work.
7. **Given** the gateway is deliberately configured to rewrite `Host` and inject cross-origin headers, **When** the conformance suite runs, **Then** it fails and identifies which clause was violated.
8. **Given** a client sends a forged forwarded-client-address header, **When** the request traverses the gateway, **Then** the gateway replaces rather than appends to that header, so the address the rate limiter sees is the one the gateway observed and not the one the client claimed.

---

### User Story 4 - The platform explains itself (Priority: P4)

An engineer sends one request and can then answer, from the platform's own tooling: the request rate, error rate and latency distribution of each service; the CPU and memory used by the container and by the runtime inside it; and — for that single request — every hop it took across the gateway, `order-service` and `auth-service`.

**Why this priority**: Observability is what separates operating a system from guessing about it, and it is the precondition for the resource tuning, scaling and benchmarking work that follows.

**Independent Test**: Generate a known number of requests, confirm rate, errors and latency appear in the dashboards, and retrieve one specific request's trace showing the gateway, `order-service` and `auth-service` as connected spans.

**Acceptance Scenarios**:

1. **Given** a deployed platform, **When** the engineer opens the dashboards, **Then** request rate, error rate and latency distribution are present per service, alongside runtime memory, garbage collection, container CPU and memory, restart counts and replica counts.
2. **Given** a request has been served, **When** the engineer looks up its correlation identifier, **Then** one trace is returned with connected spans covering the gateway, `order-service` and its call to `auth-service`.
3. **Given** any service log line, **When** it is read, **Then** it is machine-parseable structured output carrying at minimum timestamp, level, service, trace identifier, span identifier and message.
4. **Given** a request rejected by the rate limiter, **When** the engineer inspects the dashboards, **Then** the rejection is distinguishable from an application error rather than being aggregated into a single error count.

---

### User Story 5 - Multi-instance correctness under failure (Priority: P5)

An engineer runs several replicas of each service and deliberately destroys parts of the system — kills a pod, deploys an unpullable image, forces a replica to report itself unready, cuts a permitted network path, rolls out a new version, stops a worker node. Beyond the usual recovery checks, they verify the two properties Hydra's design depends on but has never exercised under real multi-instance conditions: that concurrent credential rotation across replicas stays atomic, and that rate limits are enforced across the whole service rather than per pod.

**Why this priority**: This is the teaching payload and, for Hydra, the correctness payload. The project's constitution declares atomic distributed state mutation non-negotiable precisely because Hydra is multi-instance; until now that has been an argument, not an observation.

**Independent Test**: Run each drill against a healthy environment while an external client issues continuous requests. Each drill reports its own verdict, restores the environment to a verified healthy state, and the observed success rate is recorded.

**Acceptance Scenarios**:

1. **Given** a service running multiple replicas and a client issuing continuous requests, **When** one pod is deleted, **Then** a replacement reaches Ready and the client observes no sustained loss of service.
2. **Given** a healthy deployment, **When** an intentionally invalid image reference is deployed, **Then** the failure surfaces as an image-pull failure, previously healthy pods keep serving, and restoring the valid reference returns the deployment to healthy.
3. **Given** a healthy service, **When** one replica is forced to report itself not ready, **Then** it stops receiving traffic while still running, and resumes only after reporting ready again.
4. **Given** a policy permitting only the intended callers to reach the datastore, the cache and `auth-service`, **When** an unauthorised workload attempts those calls, **Then** each attempt fails while the authorised equivalents succeed — proven with real workloads, not simulated.
5. **Given** version N deployed and a client issuing continuous requests, **When** version N+1 rolls out, **Then** new pods become ready before old pods terminate, schema migration does not corrupt or deadlock under concurrent replica startup, the rollout completes, and the client observes no failed requests.
6. **Given** several replicas of `auth-service`, **When** the same renewal credential is presented concurrently to different replicas, **Then** exactly one rotation succeeds and the others are rejected — no credential is honoured twice.
7. **Given** several replicas of `auth-service` behind the gateway, **When** a client exceeds a configured per-address limit, **Then** the limit is enforced against the total across all replicas rather than allowing that many requests per pod.
8. **Given** a multi-node cluster, **When** a worker node is stopped or isolated, **Then** the platform reports the resulting scheduling and availability behaviour, and the documentation states how this differs from a real cloud node failure.
9. **Given** any drill has run, **When** it completes, **Then** the environment is returned to its pre-drill healthy state, verified by the standard health checks.

---

### User Story 6 - Load, scale and measure honestly (Priority: P6)

An engineer generates controlled load against the real gateway and watches replica count rise and later fall. They then run a repeatable benchmark comparing the two concurrency models on Hydra's actual endpoints — which block on a database and a cache, as production endpoints do — and receive a report that states its own configuration, hardware, load profile, results and limitations.

**Why this priority**: Concurrency and autoscaling are where cargo-cult conclusions are most common and most expensive. Running the comparison on endpoints with real blocking I/O is what makes the result mean anything.

**Independent Test**: Run the load test and observe replica count respond to real metrics. Run the benchmark in both concurrency modes and confirm the report contains every declared field and no unqualified conclusion.

**Acceptance Scenarios**:

1. **Given** a deployed service with autoscaling configured, **When** sustained load is applied through the gateway, **Then** replica count increases in response to observed metrics and returns toward baseline after load stops.
2. **Given** local resources insufficient for scaling to occur, **When** the scaling test runs, **Then** it reports the constraint explicitly rather than a false PASS.
3. **Given** a benchmark run, **When** it completes, **Then** the report contains configuration, hardware, load profile, throughput, latency percentiles, error rate, CPU, memory, runtime heap, garbage-collection behaviour, container memory and replica count.
4. **Given** the benchmark drives endpoints that block on the datastore and the cache, **When** the two concurrency modes are compared, **Then** the report presents the measured difference and states the workstation-specific factors behind it, without generalising to production and without claiming the lightweight model reduces memory consumption.
5. **Given** the deployed services, **When** the engineer switches concurrency mode, **Then** the change is configuration-only, requires no source change, and the active mode is observable at runtime.
6. **Given** load is applied, **When** the rate limiter engages, **Then** the benchmark distinguishes throttled responses from errors so that limiter behaviour does not silently corrupt the throughput result.

---

### User Story 7 - Declarative delivery and a way to look inside (Priority: P7)

An engineer changes a manifest in version control and watches the cluster converge without anyone running a deploy command. They also have a lightweight console for inspecting cluster objects, logs and events, plus one-command access to the metrics and delivery consoles.

**Why this priority**: These make the earlier stories a sustainable practice rather than a sequence of shell commands. Valuable, but the lab teaches its core lessons without them.

**Independent Test**: Commit a change to a tracked manifest, observe the delivery controller detect it and the cluster converge; open each console by its documented command and inspect a live pod's logs.

**Acceptance Scenarios**:

1. **Given** the delivery controller watches a tracked configuration source, **When** a tracked value changes, **Then** it reports the deviation and the cluster converges without a manual deploy.
2. **Given** a running environment, **When** the engineer runs the console access commands, **Then** the cluster console, metrics console and delivery console each become reachable by a deterministic documented mechanism.
3. **Given** the cluster console is open, **When** the engineer inspects a workload, **Then** nodes, namespaces, pods, deployments, services, events, logs and resource usage are all visible.
4. **Given** secret material is required by the services, **When** the engineer inspects the tracked configuration, **Then** no secret value is committed to version control.

---

### User Story 8 - Documentation, production mapping and a settled edge decision (Priority: P8)

An engineer who has never seen the lab reads its documentation and can explain what each component is, how a request reaches a pod, how to break each component, how to recover it, and what the equivalent looks like in a real cloud environment. A separate written finding records what the lab demonstrated about running Hydra's edge on Kubernetes, as evidence for the decision the constitution leaves open.

**Why this priority**: The lab's output is understanding and a decision. Undocumented, it is a pile of manifests its own author will not understand in three months. It ranks last only because it describes work the earlier stories produce.

**Independent Test**: Give the documentation to an engineer unfamiliar with the project and ask them to set up the environment, break one component, diagnose it and recover it, using documentation alone.

**Acceptance Scenarios**:

1. **Given** the documentation, **When** a reader looks up any major component, **Then** they find what it is, why it exists, what problem it solves, how it works, how to inspect it, how to break it, how to recover it, and its production equivalent.
2. **Given** the documentation, **When** a reader looks for the rationale behind each architectural exclusion, **Then** each deliberately unused technology has a stated reason.
3. **Given** the production-mapping document, **When** a reader compares local and production, **Then** each local component maps to its production counterpart, including the datastore, the cache, secret material and the registry, and the differences that do not transfer are stated explicitly.
4. **Given** the version documentation, **When** a reader checks any component version, **Then** it is pinned, mutually compatible with the rest of the matrix, and justified, with no component tracking a moving reference.
5. **Given** the lab has been executed and validated, **When** a reader consults the edge finding, **Then** it states what was demonstrated about Kubernetes as Hydra's edge, what remained unproven locally, and what would still need verifying in a real cloud environment before the open question is closed.

---

### Edge Cases

**Inherited from Hydra's services**

- **Container build omits a required module**: the service images are built from a multi-module reactor. A module the service depends on but the image build does not copy produces a build failure — or worse, a stale artifact. The build must cover every module each service actually depends on, and must be verified by building from a clean state.
- **Hard-coded runtime flags conflict with the runtime-defaults requirement**: the existing images pin explicit garbage-collector flags, at least one of which no longer has meaning on the mandated Java version. Each flag must be justified against measurement or removed.
- **Tenant hostname does not resolve on the workstation**: tenant identity comes solely from `Host`, so the lab must serve several distinct tenant hostnames from the workstation. A single flat address cannot exercise tenant resolution at all.
- **Renewal credential is `Secure`**: the browser will not store it over plain HTTP, which is why TLS at the gateway is binding rather than aspirational. There is no mode in which authentication traffic crosses the lab unencrypted.
- **Locally generated certificates expire**: a lab rebuilt months later meets an expired certificate and a TLS error that reads as a routing fault. Setup must regenerate or renew material idempotently rather than assuming the first generation is permanent.
- **Test-client trust is not the system trust store**: the conformance harness runs on a runtime with its own trust configuration, so trusting the lab authority on the workstation does not make the harness trust it. Trust material must be handed to the harness explicitly, and never worked around by disabling verification — a harness that skips verification cannot test the credential clause it exists to test.
- **Forwarded-address header is trusted left-most**: a client can forge it. If the gateway appends rather than replaces, per-address rate limits become bypassable. This is a security boundary the lab must test, not assume.
- **Gateway ships cross-origin handling enabled by default**: many do. If both the gateway and the service emit, browsers reject the response — a failure that appears only in the deployed environment.
- **Concurrent schema migration**: several replicas starting at once each attempt migration. Startup must serialise or no-op safely rather than deadlock or partially apply.
- **Fixture drift**: the seeded fixture encodes assumptions about the services' schema and password handling. A schema change elsewhere in the project can leave the fixture applying cleanly but producing accounts that cannot sign in — the failure surfaces at the integration flow, not at seeding, so seeding alone must not be read as success.
- **Cache unavailable**: rate limiting is configured to fail closed by default, so losing the cache rejects requests rather than passing them through. The lab must demonstrate this deliberately so the behaviour is a known property rather than a surprise.
- **Signing key material differs per replica**: if each replica generated its own key, tokens issued by one would fail validation against another's published key set. All replicas must serve the same key material.
- **Non-URL token issuer**: the issuer identifier is not a resolvable address, so validation configuration must not assume it can be fetched.
- **Sampling hides the request you are looking for**: a policy that samples a fraction of traffic will, sooner or later, drop the exact request an engineer is trying to follow. The result looks like broken propagation rather than a sampling decision, so the lab must make its sampling policy explicit and visible.
- **Agent-only instrumentation has a ceiling**: automatic instrumentation sees framework boundaries, not domain intent. Signals that would require hand-written spans or custom meters are simply unavailable, and the lab must record what it therefore cannot show rather than implying full coverage. The agent's own overhead is also present in every benchmark figure.

**Environmental**

- **Host toolchain mismatch**: the workstation's default Java toolchain is older than mandated. The build must not silently downgrade.
- **Insufficient hardware**: the full platform plus a datastore, a cache and multiple replicas is heavier than a tutorial. The diagnostic must fail the specific resource check, and a reduced mode must remain available.
- **Port conflicts**: another process already holds a port the gateway or registry needs — detected during diagnostics, not discovered mid-install.
- **Architecture differences**: every pinned component must have an image for the host architecture, or the gap is documented.
- **Container daemon installed but stopped**: diagnostics must distinguish "not installed" from "not running".
- **Registry reachable from the host but not from inside the cluster**: the image path must reconcile the workstation's address space with a node container's, with a documented fallback.
- **Gateway address never provisioned**: no cloud load balancer exists locally; the chosen exposure mechanism must be deterministic and documented end to end.
- **Autoscaling with no metrics available**: the scaling test must distinguish "did not scale" from "could not observe".
- **Stale state from a previous run**: creation must be idempotent or fail with a clear instruction, never half-adopt old state.
- **Uncommitted changes during image build**: a revision-derived tag could collide with a previously published image built from different source; the image lifecycle must make this visible.
- **Delivery controller with no reachable remote**: the demonstration must work from a local repository or state the dependency.
- **Tests run against a missing or unhealthy cluster**: every test entry point must fail fast with a clear message.
- **Convergence never happens**: every wait must be bounded with an explicit timeout and must surface diagnostic context on expiry — never an unbounded wait, never a fixed sleep standing in for a readiness condition.

## Requirements *(mandatory)*

### Environment diagnostics and prerequisites

- **FR-001**: The system MUST provide a single diagnostic entry point validating the container CLI, the container daemon, the cluster provisioning tool, the cluster CLI, the component package manager, the Java toolchain and its version, the build tool and the Java version it will actually use, available CPU, available memory, host architecture, required free ports, and available container storage where practical.
- **FR-002**: The diagnostic MUST print one line per check with an explicit PASS/FAIL verdict and a concluding readiness statement, and MUST exit non-zero if any required check fails.
- **FR-003**: The diagnostic MUST NOT install, modify or upgrade anything on the host; it reports and instructs only.
- **FR-004**: The system MUST refuse to compile or run application code on a Java version older than the mandated one. Where the host toolchain does not satisfy this, the build MUST use a reproducible containerised toolchain of the mandated version and MUST state which toolchain performed the build.

### Version governance

- **FR-005**: The system MUST document a single version matrix covering at minimum Java, the application framework, the build tool, Kubernetes, the cluster provisioning tool, the networking layer, the gateway API definitions, the component package manager, the delivery controller, the metrics system, the dashboard system, the telemetry components, the trace store, the relational datastore and the cache.
- **FR-006**: Every version MUST be pinned to an explicit release. Moving references MUST NOT be used absent a specific documented reason.
- **FR-007**: Versions MUST be selected for mutual compatibility with the compatibility basis recorded, rather than each component independently taking its newest release.
- **FR-008**: The datastore and cache versions MUST match the versions Hydra already runs in local development, so the lab does not silently validate against a different engine than the project uses.
- **FR-009**: The pinned versions MUST be the versions the installation path actually uses, so the matrix cannot drift from reality.

### Cluster lifecycle

- **FR-010**: The system MUST provision a local multi-node Kubernetes cluster with a default topology of one control-plane node and two workers, with the worker count configurable.
- **FR-011**: The cluster definition MUST disable the default networking plugin so the chosen networking layer is the sole provider.
- **FR-012**: The system MUST provide distinct create, delete, recreate, status and health operations for the cluster.
- **FR-013**: Cluster creation MUST verify every expected node reaches Ready before reporting success.
- **FR-014**: Installation MUST proceed in discrete named checkpoints; after each, the system MUST validate state, print a concise summary, and stop rather than continue past a broken critical dependency.
- **FR-015**: All waiting MUST use condition-based waits with explicit bounded timeouts. Fixed-duration sleeps MUST NOT substitute for readiness conditions.

### Image lifecycle

- **FR-016**: The system MUST run a local image registry integrated with the cluster; the primary path MUST publish to and pull from it without requiring a public image host or account.
- **FR-017**: Every application image MUST carry an immutable revision-derived tag. Floating tags MUST NOT be used for application images.
- **FR-018**: Each service image build MUST include every module that service depends on in the multi-module reactor, and MUST be verified by a build from a clean state with no local build cache.
- **FR-019**: The image path MUST explicitly reconcile addressing differences between the workstation, the registry, the node containers and the container runtime inside them, and MUST NOT assume a loopback address means the same thing inside a pod as on the host.
- **FR-020**: A direct image-load fallback MUST be available for local runtime edge cases, documented as a fallback rather than the primary path.
- **FR-021**: The system MUST provide registry create and status operations plus image build and publish operations, and MUST document the complete lifecycle from source to running pod.

### Networking layer

- **FR-022**: The system MUST install a single networking layer serving as cluster network provider, network policy engine, kernel-level observability layer and gateway implementation.
- **FR-023**: The networking layer MUST be configured with service-proxy replacement where supported, layer-7 proxying, gateway support, network policy and observability enabled.
- **FR-024**: The system MUST provide a networking status operation and a connectivity test exercising real pod-to-pod and pod-to-service traffic.
- **FR-025**: The networking architecture — network provider, service proxy and its replacement, kernel-level datapath, service and pod networking, network policy, layer-7 proxy and its relationship to the gateway — MUST be documented rather than treated as an implementation detail.

### North-south traffic

- **FR-026**: The Kubernetes Gateway API MUST be the primary north-south interface. Legacy ingress objects and ingress annotations MUST NOT be the primary configuration model.
- **FR-027**: The gateway API definitions MUST be installed explicitly at a pinned version, using stable API versions wherever available.
- **FR-028**: The system MUST define a gateway class, a gateway and route objects supporting host-based routing, path-based routing, request header manipulation and route-level timeout configuration.
- **FR-029**: A separate standalone gateway controller MUST NOT be installed; the layer-7 proxy MUST be consumed as the data plane of the chosen networking layer's gateway implementation and MUST NOT be managed as an independent application component.
- **FR-030**: The system MUST select exactly one deterministic local exposure mechanism making the gateway reachable from the workstation without a cloud load balancer, and MUST document the complete path from the workstation address to the serving pod.
- **FR-031**: The gateway MUST route to both services by path, such that `auth-service` and `order-service` are reachable through a single tenant hostname as a browser would address them.
- **FR-032**: The gateway MUST terminate TLS using locally generated material, so the renewal credential's `Secure` attribute is exercised exactly as issued. This is a blocking requirement with no fallback: a run that cannot terminate TLS at the gateway is a failed run, not a documented divergence. The credential's `Secure` attribute MUST NOT be relaxed to accommodate a plain-HTTP path, and no plain-HTTP mode that carries authentication traffic MUST exist.
- **FR-032a**: Certificate and certificate-authority generation MUST be automated and idempotent as part of setup, covering every tenant hostname the gateway serves with a single wildcard certificate. Re-running setup MUST regenerate or renew expired material without manual intervention.
- **FR-032b**: The conformance and integration harness MUST be supplied the lab's certificate authority explicitly at initialisation, so client trust is configured by the lab rather than left to each developer's machine or to disabling verification.
- **FR-033**: The system MUST serve at least two distinct tenant hostnames from the workstation, so host-derived tenant resolution is genuinely exercised rather than assumed. Those hostnames MUST resolve without modifying host resolution files and without elevated privileges.
- **FR-034**: The system MUST provide gateway status and gateway test operations, and the gateway MUST carry real application traffic rather than a placeholder response.

### Transparent edge conformance

- **FR-035**: The gateway MUST satisfy every clause of the existing transparent edge contract, and this MUST be proven by running the existing edge-conformance suite against the lab gateway's base URL with no modification to the suite's assertions.
- **FR-036**: The gateway MUST forward the original `Host` header unmodified end to end, including when terminating TLS and including for requests it routes by host.
- **FR-037**: The gateway MUST NOT add, rewrite or strip any cross-origin response header. Any cross-origin handling the gateway product enables by default MUST be explicitly disabled.
- **FR-038**: The gateway MUST forward cross-origin preflight requests to the service unauthenticated and MUST NOT answer them itself.
- **FR-039**: The gateway MUST NOT modify credential headers on requests or responses, preserving the renewal credential's same-site, host-only and path scoping exactly as issued.
- **FR-040**: The gateway MUST require no per-tenant configuration; adding a tenant MUST NOT require a gateway change.
- **FR-041**: The gateway MUST replace, not append to, the forwarded-client-address header, so a client cannot forge the address the rate limiter enforces against. The system MUST include a test proving a forged value is not honoured.
- **FR-042**: The system MUST provide a documented hostile-edge configuration that deliberately violates the contract, and the conformance suite MUST fail against it and identify the violated clause. A suite that passes against both configurations is not proving anything.

### Applications

- **FR-043**: The lab MUST deploy Hydra's existing `auth-service` and `order-service`. Purpose-built demonstration services MUST NOT be substituted for them.
- **FR-044**: The lab MUST NOT change the runtime behaviour of either service. Changes are confined to the deployment surface — container build, externalised configuration, charts and manifests — and any lab-only affordance MUST be gated behind a non-production profile that is off by default. All metrics and tracing instrumentation MUST be supplied by an agent attached at container level; no metrics or tracing dependency MUST be added to either service's build, and neither service's source MUST be modified to emit telemetry.
- **FR-045**: `order-service` MUST resolve `auth-service`'s published key set through cluster DNS using a service name. Pod addresses MUST NOT be used for service-to-service communication.
- **FR-046**: The token issuer identifier MUST be treated as an opaque identifier rather than a resolvable address.
- **FR-047**: All replicas of `auth-service` MUST serve identical signing key material, so a token issued by one replica validates against the key set published by any other.
- **FR-048**: Each service MUST expose a health endpoint distinguishing started, ready to receive traffic, and alive. Service and runtime metrics MUST reach the metrics system by way of the attached agent, without adding a metrics dependency to either service's build.
- **FR-049**: Each service MUST support switching its concurrency model between the lightweight-thread model and the platform-thread model by configuration alone, with the active mode observable at runtime.
- **FR-050**: Documentation MUST explain platform threads, lightweight threads, blocking I/O, scheduler behaviour, thread pinning, daemon-thread behaviour, limitations, and specifically when the lightweight model does and does not help. It MUST NOT claim that model inherently reduces runtime memory consumption.

### Backing services and state

- **FR-051**: The relational datastore and the cache MUST run inside the cluster as the services' real dependencies, not be stubbed or mocked.
- **FR-052**: Each service's schema migration MUST complete before that service reports ready, and MUST remain correct when several replicas start concurrently.
- **FR-052a**: The lab MUST apply a fixture of tenants and users after schema migration and before any service replica accepts traffic, so that `auth-service`'s first-boot bootstrap never runs in the lab. The fixture MUST cover every tenant hostname required by FR-033 and MUST be applied identically on every environment recreation, with no manual step.
- **FR-052b**: The fixture MUST NOT be treated as a substitute for validating first-boot bootstrap. The documentation MUST record that the lab deliberately bypasses that path, so no reader concludes bootstrap was exercised under multiple replicas when it was not.
- **FR-053**: Datastore credentials, cache credentials and signing key material MUST be supplied through Kubernetes secrets. They MUST NOT appear in source, manifests, charts, images or version control.
- **FR-054**: The datastore and the cache MUST be reachable only by the workloads that require them, enforced by network policy.
- **FR-055**: The documentation MUST map each item of secret material to its production equivalent, and MUST state plainly that the lab's secret handling is not itself a production pattern.
- **FR-056**: The system MUST demonstrate the configured behaviour when the cache is unavailable, so that the fail-closed rate-limiting posture is an observed property rather than an assumed one.

### Containers and runtime configuration

- **FR-057**: Application images MUST be built in multiple stages with a minimal runtime layer, running as a non-root user with a dedicated user and group identity.
- **FR-058**: Application containers MUST drop unnecessary kernel capabilities, use a read-only root filesystem where practical, apply a restricted syscall profile where practical, handle termination signals correctly and shut down gracefully. Application containers MUST NOT run privileged.
- **FR-059**: Runtime configuration MUST be container-aware. Any runtime flag present in the service images that is provably inert on the mandated Java version MUST be removed, since removing it changes no behaviour. Flags that do change behaviour — the garbage-collector selection in particular — MUST be left as they are by this feature.
- **FR-059a**: Every runtime flag retained in the service images — the collector selection and any other behavioural flag alike — MUST be documented with what it does and whether it still applies on the mandated Java version, and the collector selection MUST additionally be measured against the runtime's defaults and published as a comparison. The lab MUST NOT change any retained flag on the strength of a workstation measurement; the recommendation is input to a separate decision, and the documentation MUST say so plainly.
- **FR-060**: Memory documentation MUST account for heap, class metadata, code cache, direct buffers, native memory, thread-related memory and runtime overhead, and MUST NOT equate the container memory limit with maximum heap size without a stated reason.

### Resources, health and availability

- **FR-061**: Every application workload MUST declare both resource requests and limits.
- **FR-062**: Initial resource values MUST be treated as starting points, with a measurement-based path for revising them using the metrics system, dashboards and the load and benchmark tooling. Lowering a limit MUST be supported by measurement and MUST NOT be justified by the choice of concurrency model.
- **FR-063**: Every application workload MUST define startup, readiness and liveness checks, where readiness represents genuine ability to receive traffic and is distinct from liveness.
- **FR-064**: The system MUST provide a controlled way to make a replica report itself not ready, gated behind a non-production profile, so readiness behaviour can be demonstrated rather than assumed.
- **FR-065**: Both services MUST run multiple replicas and MUST configure disruption budgets, topology spreading or anti-affinity, rolling-update bounds and a graceful termination period appropriate to a local multi-node cluster.
- **FR-066**: Deleting any single application pod MUST NOT make the service unavailable to an external client, proven by an executed test rather than asserted.

### Multi-instance state correctness

- **FR-067**: The system MUST include a test proving that when the same renewal credential is presented concurrently to different `auth-service` replicas, exactly one rotation succeeds and every other attempt is rejected.
- **FR-068**: The system MUST include a test proving that per-address rate limits are enforced across the whole service rather than per replica.
- **FR-069**: Both tests MUST run against multiple real replicas in the cluster. A single-replica deployment does not satisfy them.

### Autoscaling

- **FR-070**: The system MUST configure horizontal autoscaling driven by real observed metrics, with no simulated or hard-coded replica changes.
- **FR-071**: The system MUST provide a load-generation operation driving traffic through the actual gateway, and a scaling test observing the resulting replica changes.
- **FR-072**: When local resources prevent scaling, the scaling test MUST report that constraint explicitly and MUST NOT report success.

### Security and isolation

- **FR-073**: Network policy MUST permit only the intended paths — gateway to services, `order-service` to `auth-service`, services to their datastore and cache — and block everything else. A test MUST prove permitted paths succeed and forbidden paths fail, using real workloads and services.
- **FR-074**: Workloads MUST be organised into dedicated namespaces for platform components, applications, stateful backing services, observability and delivery. Application workloads MUST NOT run in the default namespace.
- **FR-075**: Each workload MUST use a dedicated service identity with least-privilege rights. Application workloads MUST NOT be granted cluster-administrator rights.
- **FR-076**: Credentials MUST NOT be hard-coded in source, manifests, charts or images.

### Observability

- **FR-077**: The system MUST install a metrics system, dashboards and telemetry collection, collecting request rate, errors and latency per service plus runtime memory and CPU, garbage collection, container CPU and memory, pod restarts, replica count and autoscaler state. Service-level and runtime-level signals MUST originate from the attached agent rather than from instrumentation added to the services.
- **FR-078**: Dashboards MUST be organised around the rate/errors/duration method and MUST be usable for the resource-tuning and benchmarking work required elsewhere in this specification.
- **FR-079**: Rate-limited rejections MUST be distinguishable from application errors in both metrics and dashboards.
- **FR-080**: The system MUST propagate trace context from the gateway through `order-service` to `auth-service`, so a single external request can be followed end to end as one trace. Propagation MUST be achieved by the attached agent's automatic instrumentation; the services MUST NOT be modified to create or forward spans.
- **FR-080a**: The system MUST run a trace store that retains emitted traces and makes them retrievable by trace identifier, surfaced through the dashboard system rather than through a separate console. It is the only tracing component added; a parallel tracing UI MUST NOT be installed.
- **FR-080b**: Trace sampling MUST be configured so that a request an engineer has just issued is retrievable. A sampling policy that silently discards the request under investigation makes the end-to-end scenario untestable and MUST NOT be the default in the lab.
- **FR-081**: Documentation MUST explain traces, spans, context propagation, sampling, trace identifiers and log/trace correlation.
- **FR-082**: All application logs MUST be machine-parseable structured records carrying at minimum timestamp, level, service, trace identifier, span identifier and message. A heavyweight log storage stack MUST NOT be introduced; production log-storage options MUST be documented instead.

### Declarative delivery

- **FR-083**: The system MUST install a delivery controller reconciling cluster state from declarative configuration in version control, and MUST demonstrate the full loop: a change is detected, reconciled, and becomes the active state without a manual deploy.
- **FR-084**: Deployment MUST be packaged as charts with a base value set and a local override set, exposing at minimum image, replica count, resources, environment, probes, service, gateway, route, network policy and secret references — without excessive abstraction layers.
- **FR-085**: No secret value MUST be committed to the tracked configuration source.
- **FR-086**: The system MUST provide status and access operations for the delivery controller.

### Inspection consoles

- **FR-087**: The system MUST install a lightweight cluster console permitting inspection of nodes, namespaces, pods, deployments, services, events, logs and resource usage.
- **FR-088**: The cluster console, the dashboard system and the delivery console MUST each be reachable from the workstation by a deterministic documented mechanism, each behind its own access operation. Traces MUST be reachable through the dashboard system; no fourth console MUST be introduced for them.

### Developer interface

- **FR-089**: The system MUST expose one consistent developer entry point covering at minimum: diagnostics; setup; cluster create/delete/recreate/status/health; registry create/status; networking status and connectivity test; gateway status and test; platform install and status; image build and publish; application build, deploy and status; the full test suite plus smoke, integration, failure, pod-failure, network-policy, scaling and rolling-update tests; edge conformance; load test; benchmark; debug; logs; the three console access operations; full-recreation validation; and cleanup.
- **FR-090**: The system MUST provide a diagnostic dump operation printing node, pod, service, endpoint, gateway, route, network policy, event, deployment and autoscaler state cluster-wide, plus networking-layer diagnostics, sufficient to identify scheduling, image, readiness, routing, DNS, network policy and autoscaling failures.
- **FR-091**: The system MUST provide a reduced-footprint setup mode for constrained workstations. The reduced mode MAY disable optional components — the trace store among them — but MUST retain workloads, deployments, services, the gateway API, the networking layer, network policy, the datastore, the cache and — where feasible — autoscaling. Where the trace store is disabled, the documentation MUST state that the end-to-end trace scenario is unavailable in that mode rather than letting it appear to have passed.

### Testing

- **FR-092**: Infrastructure tests MUST execute against the actual running local cluster. Kubernetes MUST NOT be mocked for infrastructure integration tests.
- **FR-093**: Tests MUST be organised into smoke, integration, failure and performance suites, each independently runnable.
- **FR-094**: The smoke suite MUST validate the cluster API, node readiness, networking health, gateway API installation, gateway class existence, gateway programming, route acceptance, gateway reachability, datastore and cache readiness, application readiness, service existence, HTTP routing, service-to-service communication, and availability of the metrics system, dashboards, trace store and delivery controller.
- **FR-095**: The integration suite MUST exercise the real end-to-end flow — sign in through the gateway, obtain a token, create and list orders — and MUST cover routing, DNS, service discovery, readiness behaviour, key-set retrieval between services, network policy, graceful shutdown and error handling.
- **FR-096**: The existing edge-conformance suite MUST be run against the lab gateway as part of validation, reusing it by configuration rather than reimplementing its assertions.
- **FR-097**: The failure suite MUST implement controlled drills for pod deletion, invalid image deployment, readiness failure, network policy enforcement, rolling update with schema migration, cache unavailability, concurrent credential rotation, cross-replica rate limiting and node failure, each restoring the environment to a verified healthy state on completion.
- **FR-098**: Every test entry point MUST return a non-zero exit code when any required check fails, and MUST NOT report a component as passing unless an executed check validated it.
- **FR-099**: The fast validation entry point MUST run smoke, integration, edge conformance and the relevant failure tests, and MUST NOT destroy or recreate the cluster.
- **FR-100**: The full reproducibility entry point MUST destroy the cluster, remove relevant local state, recreate the cluster, install the platform, deploy the applications, wait for readiness, and run smoke, integration and edge-conformance validation. It MUST NOT run as part of the fast validation path.
- **FR-101**: The validation output MUST present a per-component PASS/FAIL summary and a single overall verdict.
- **FR-102**: Hydra's existing test suites MUST continue to pass unchanged; this feature MUST NOT require modifying an existing assertion to accommodate the lab.

### Performance measurement

- **FR-103**: The system MUST provide a repeatable benchmark driving load through the actual gateway and running the same workload in both concurrency modes.
- **FR-104**: The benchmark MUST exercise endpoints that block on the datastore and the cache, so the comparison reflects real blocking I/O rather than a synthetic delay.
- **FR-104a**: When comparing concurrency models, the benchmark MUST hold the garbage-collector selection constant. Collector comparisons MUST be run as their own experiment, so no published figure varies two settings at once.
- **FR-105**: The benchmark MUST collect requests per second, throughput, median, 95th and 99th percentile latency, error rate, CPU, memory, runtime heap, garbage-collection behaviour, container memory and replica count, and MUST report throttled responses separately from errors.
- **FR-106**: The benchmark MUST produce a report stating its configuration, hardware, load profile, results, observations and limitations, and MUST state that results depend on workstation hardware, workload shape, concurrency, latency, downstream behaviour, runtime configuration, resource limits and the overhead of the attached instrumentation agent.
- **FR-107**: The benchmark MUST NOT state a conclusion its measurements do not support, and MUST NOT generalise a workstation result to a production claim.

### Reproducibility

- **FR-108**: The complete cycle — create, install, deploy, test, destroy, recreate, re-test — MUST succeed on a second pass with no manual intervention between passes.
- **FR-109**: A cleanup operation MUST remove the cluster, the registry and the local state the lab created, leaving the workstation in a state where the first-run path works again.

### Documentation

- **FR-110**: The documentation MUST explain what the project is; the rationale for each chosen technology; the rationale for each deliberate exclusion, including why no standalone gateway controller, no legacy ingress as the primary API and no service mesh in the initial implementation; how to install prerequisites; how to run the environment; how to run tests and benchmarks; how to access the consoles; and how to debug failures.
- **FR-111**: Every major component MUST be documented with what it is, why it exists, what problem it solves, how it works, how to inspect it, how to break it, how to recover it, and its production equivalent.
- **FR-112**: A production-mapping document MUST map each local component to its production counterpart — local cluster to managed Kubernetes, local registry to a managed registry, in-cluster datastore and cache to managed equivalents, local storage to network-attached storage, local secrets to a managed secret store — and MUST distinguish transferable Kubernetes concepts from local implementation detail. It MUST NOT claim the local cluster behaves identically to a managed cloud cluster.
- **FR-113**: The system MUST produce a written finding on running Hydra's edge on Kubernetes, stating what the lab demonstrated, what it could not demonstrate locally, and what would still require verification in a real cloud environment. It MUST be framed as evidence toward the open architectural question, not as a unilateral resolution of it.
- **FR-114**: All documentation, specifications and commit messages MUST be written in English.

### Failure handling during construction

- **FR-115**: When any step fails during construction or validation, the operator MUST diagnose it — command output, cluster events, workload status, logs, service status, gateway status, route status and networking status — identify the root cause, fix the implementation and re-run the failed validation, rather than reporting the error and moving on.
- **FR-116**: The feature MUST NOT be reported complete on the basis of generated files. Completion requires the environment to have been executed and validated, with recorded results reflecting actual runs.

### Key Entities

- **Version Matrix**: The authoritative record of every pinned component version, its compatibility basis and any documented exception. Consumed by the installation path so documentation and reality cannot diverge.
- **Checkpoint**: A named installation stage with a validation step, a summary output and a stop condition. Ordered; a failed checkpoint blocks all later ones.
- **Environment Diagnostic Report**: The per-check PASS/FAIL record of host readiness, produced before any installation, with an overall verdict.
- **Service Image**: A built artifact for one Hydra service, identified by an immutable revision-derived tag, built from the multi-module reactor including every module that service depends on, published to the local registry.
- **Tenant Address**: A hostname that resolves to the gateway and, by its host label alone, identifies a tenant. Several must exist for tenant resolution to be genuinely exercised; none may require gateway configuration of its own.
- **Lab Fixture**: The deterministic set of tenants and users the lab seeds after migration and before traffic, covering every tenant hostname the gateway serves. Reapplied identically on every recreation; the reason first-boot bootstrap never runs in the lab.
- **Backing Service**: An in-cluster stateful dependency — the relational datastore or the cache — with its own credentials, network policy and production counterpart.
- **Secret Material**: A credential or signing key consumed by a service, supplied through a Kubernetes secret, absent from version control, and mapped in documentation to its production equivalent.
- **Edge Conformance Result**: The outcome of running the existing transparent edge contract suite against the lab gateway, plus the outcome against the deliberately hostile configuration. Both are required; a pass alone proves nothing.
- **Failure Drill**: A named controlled fault with a trigger, an expected observable outcome, an assertion and a restoration step returning the environment to a verified healthy state.
- **Validation Result**: The per-component PASS/FAIL record plus a single overall verdict, surfaced as human-readable output and as a process exit status.
- **Benchmark Report**: One measurement session — configuration, hardware, load profile, collected metrics, observations and limitations — scoped to the workstation it ran on.
- **Edge Finding**: The written record of what the lab demonstrated about Kubernetes as Hydra's edge, what it could not demonstrate locally, and what remains to be verified in a real cloud environment.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: An engineer starting from a workstation that satisfies the documented prerequisites reaches a fully validated environment using the documented commands, with no manual intervention beyond those commands, in under 45 minutes of wall-clock time.
- **SC-002**: The environment diagnostic correctly identifies a missing or unsatisfied prerequisite in 100% of seeded cases and exits non-zero every time.
- **SC-003**: Destroy-and-recreate followed by re-validation succeeds without manual intervention on three consecutive runs.
- **SC-004**: A user can sign in and create an order entirely through the gateway, with the token validated against the key set retrieved between services, in 100% of runs against a healthy environment.
- **SC-005**: The existing edge-conformance suite passes against the lab gateway over TLS with zero modifications to its assertions and with certificate verification enabled, and fails against the deliberately hostile gateway configuration, naming the violated clause.
- **SC-006**: A request carrying a forged forwarded-client-address header is rate-limited against the address the gateway observed, not the forged one, in 100% of attempts.
- **SC-007**: A tenant added after the gateway was configured works immediately, with zero gateway configuration changes.
- **SC-008**: With an external client issuing continuous requests, deleting any single application pod keeps the observed success rate at or above 99% over a 60-second window.
- **SC-009**: A rolling update from one version to the next completes with zero failed requests observed by an external client issuing continuous requests throughout, including when schema migration runs.
- **SC-010**: When one renewal credential is presented concurrently to multiple replicas, exactly one rotation succeeds — zero double-honoured credentials across at least 100 concurrent attempts.
- **SC-011**: A per-address rate limit configured at N requests per window admits at most N requests per window across all replicas combined, not N per replica.
- **SC-012**: A single external request can be followed end to end across the gateway, `order-service` and `auth-service` as one connected trace, retrievable by its identifier within 30 seconds.
- **SC-013**: In the network policy test, permitted communication succeeds in 100% of attempts and forbidden communication — including any attempt to reach the datastore or cache from an unauthorised workload — fails in 100% of attempts, repeatably.
- **SC-014**: Every failure drill returns the environment to a state passing the standard health checks, verified automatically at the end of each drill, in 100% of runs.
- **SC-015**: The validation entry point reports a per-component verdict and a single overall verdict, and returns a non-zero exit code for 100% of seeded component failures, with no component ever reported passing without an executed check behind it.
- **SC-016**: Under sustained load the replica count increases above baseline and later returns toward it; where workstation resources prevent this, the scaling test reports the constraint explicitly instead of a passing verdict.
- **SC-017**: The benchmark report contains every declared field, separates throttled responses from errors, and reports repeated runs with their observed variance rather than as a single unqualified figure.
- **SC-018**: Given any one of the seeded fault classes — scheduling, image, readiness, routing, DNS, network policy, autoscaling, datastore, cache — the diagnostic dump contains enough information for a reader to name the failing component without issuing further commands.
- **SC-019**: Every operation listed in the developer interface exists, is documented, and exits successfully against a healthy environment.
- **SC-020**: Hydra's existing test suites pass unchanged, with zero assertions modified to accommodate the lab.
- **SC-021**: An engineer unfamiliar with the project can, using documentation alone, set up the environment, break one component, diagnose it and recover it — without reading any manifest.
- **SC-022**: Every component version referenced anywhere in the environment resolves to the version recorded in the version matrix, with zero moving references outside documented exceptions.
- **SC-023**: A reader of the edge finding can state what the lab proved about Kubernetes as Hydra's edge and what it did not, without reading any other document.

## Assumptions

### Mandated constraints

- The technology stack is a **hard input constraint from the requester**, not a downstream implementation choice: the container runtime, the local cluster provisioner, the networking layer serving as CNI, policy engine and gateway implementation, the Gateway API as the primary north-south interface, the layer-7 proxy consumed only as that gateway's data plane, the delivery controller, the metrics and dashboard systems, the telemetry framework, and the mandated Java and application-framework versions. They appear above as capability requirements because that is what makes them testable; the planning phase selects the specific pinned releases, topology and layout.
- Technologies explicitly excluded by the requester: any alternative local Kubernetes distribution as the primary provisioner, a container-desktop built-in cluster, legacy ingress as the primary networking API, a standalone gateway controller, a service mesh in the initial implementation, and any component not required by a stated requirement.
- The original requirements described two purpose-built services (`api-service` and `auth-service`) with demonstration endpoints. The requester has since directed that the lab run Hydra's real `auth-service` and `order-service` instead. This specification reflects that direction; the demonstration endpoints named in the original input are superseded by Hydra's actual API surface.

### Scope boundaries

- The lab carries Hydra's real services but MUST NOT change their runtime behaviour. Work is confined to the deployment surface — container build, externalised configuration, charts and manifests — plus lab-only affordances gated behind a non-production profile that is off by default. No new module joins the build reactor for the services themselves.
- The existing edge-conformance suite is **reused by configuration**, pointed at the lab gateway's base URL. Its assertions are not rewritten, extended or relaxed for this feature. If a clause cannot be satisfied by the lab gateway, that is a finding about the gateway, not a reason to amend the contract.
- This feature produces **evidence** toward the open architectural question the constitution records (Kubernetes versus plain proxy plus compose for the edge). It does not close that question by itself, since a local cluster cannot demonstrate everything a managed cloud cluster would.
- First-boot bootstrap is **deliberately not exercised**. The lab seeds a fixture so the users table is never empty when replicas start, which means the race between concurrently starting replicas on that emptiness check is neither proven safe nor proven broken here. It is a known coverage gap, not a resolved question, and belongs to whatever work examines that path directly.
- Hydra's front end is out of scope. Browser-facing behaviour is validated at the HTTP level by the conformance suite, which is sufficient to exercise the contract without a browser.
- Single workstation, single engineer, no cloud resources, no shared infrastructure. Nothing here is intended to run in a shared or production environment, and the lab's secret handling in particular is not a production pattern.
- The garbage-collector selection for Hydra's services is **not decided here**. The lab measures it and publishes a recommendation; changing it is separate work, because a collector chosen on a workstation is not a collector chosen for production.
- Backup and restore, data migration between environments, multi-cluster topologies, cost management and compliance controls are out of scope.
- Public certificate authorities are not involved; TLS at the gateway uses locally generated material issued by a lab-local authority.
- Tenant hostnames are expected to come from a wildcard domain that already resolves to the loopback address, so no host-file entry and no privilege escalation is needed to reach the gateway by tenant name. A single wildcard certificate covers them, because a tenant is one label in front of the base domain.

### Known repository conditions this feature must address

These were confirmed against the source and are stated because the planning phase depends on them, not as speculation:

- The existing service container builds do not copy every module their services depend on. The most recently added shared module is absent from both, so a container build from a clean state is expected to fail until FR-018 is satisfied. This is a pre-existing condition, not one introduced here.
- The existing service images pin explicit garbage-collector flags. Generational behaviour has been the runtime default since well before the mandated version, so one of the two flags is inert and FR-059 removes it as a no-op. The collector selection itself is a real behavioural choice; FR-059a measures it and recommends, and this feature deliberately does not change it.
- Rate limiting resolves the client address from the left-most forwarded-address value and its documentation explicitly assumes the edge sets or overwrites that header. FR-041 makes that assumption an enforced property of the lab gateway rather than an inherited hope.
- The renewal credential defaults to requiring a secure transport, which is why FR-032 requires TLS at the gateway rather than treating encryption as optional polish.
- Tenant resolution requires the controlled base-domain configuration to be populated; with it empty, no address resolves and the system fails closed universally. The lab's configuration must set it deliberately.
- Neither service currently exposes a metrics endpoint for the mandated metrics system, and neither carries any tracing dependency; `order-service` exposes only health and info. Every observability requirement in this specification therefore describes capability the lab adds by attaching an agent, not capability it merely wires up.

### Environmental assumptions

- The workstation runs a Unix-like operating system with a working container runtime. Native Windows support is not targeted; if unsupported, the documentation says so rather than leaving it implied.
- Network access is available at setup time to pull pinned charts and images; steady-state operation after installation does not require it.
- Every pinned component publishes an image for the workstation's architecture, or the gap is recorded as a documented limitation.
- The workstation has enough CPU and memory for the full profile — which is heavier than the original tutorial framing, since it now includes a datastore, a cache and multiple replicas of two real services. The reduced-footprint mode exists for the case where it does not.
- A local version-control repository suffices for the declarative-delivery demonstration; no external hosting account is required.
- Documentation, specifications and commit messages are written in English regardless of the language used in conversation.
