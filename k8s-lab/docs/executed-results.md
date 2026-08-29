# Executed results

What has actually been run, on real hardware, versus what exists only as
generated files. FR-116 forbids reporting this feature complete on the strength
of files that have never been executed, so this page is the honest ledger.

Raw run output lives in `k8s-lab/results/`, which is deliberately **not**
tracked — it describes one machine's one run. This page is the curated summary
that is worth keeping in version control.

For what has NOT been executed, see [known-gaps.md](known-gaps.md).

---

## FR-018 — clean-state container build: EXECUTED, PASS

Recorded per FR-116: this is an executed result, not a generated file.

**When**: 2026-08-20
**Where**: macOS arm64, Docker 29.4.0, this workstation
**Command**: `docker build --no-cache` for each service, from the repository root

## Result

| Service | Clean build | Executable jar | Boots a Spring context |
|---|---|---|---|
| `auth-service` | PASS | `Main-Class: org.springframework.boot.loader.launch.JarLauncher`<br>`Start-Class: com.reuven.auth.AuthServiceApplication` | PASS — Spring Boot 4.1.0, Tomcat 11.0.22 on 8083, profile `test` |
| `order-service` | PASS | `Main-Class: org.springframework.boot.loader.launch.JarLauncher`<br>`Start-Class: com.reuven.orderservice.OrderServiceApplication` | not run standalone (needs the JWKS endpoint) |

Toolchain reported by the build itself (FR-004):

```
Apache Maven 3.9.11 (3e54c93a704957b63ee3494413a2b544fd3d825b)
Java version: 25.0.1, vendor: Eclipse Adoptium, runtime: /opt/java/openjdk
```

Reactor, confirming `browser-edge-starter` is now built into the image (A2):

```
hydra ............................ SUCCESS
infra-shared ..................... SUCCESS
infra-database ................... SUCCESS
rate-limit-starter ............... SUCCESS
browser-edge-starter ............. SUCCESS
auth-service ..................... SUCCESS
```

## What had to be fixed before this could pass

Three blockers, none introduced by this feature, each of which alone made a
container build impossible:

| # | Blocker | Where it was found |
|---|---|---|
| A1 | `COPY mvnw .` / `COPY .mvn .mvn` — no Maven wrapper exists in this repository, and none ever has | Phase 0 audit |
| A2 | `browser-edge-starter` absent from both the POM-copy and source-copy layers, though both services declare it | Phase 0 audit |
| **A8** | **`spring-boot:repackage` never runs** — the plugin sits in the root pom's `<pluginManagement>` with no `<executions>`, and the project does not use `spring-boot-starter-parent`, so `mvn package` produced a plain jar with no `Main-Class` | **Found during implementation, by building** |

A8 was not in the audit and could not have been: it is invisible in the source
and only appears when you build the artifact and look inside it. It means that
even with A1 and A2 fixed, `java -jar app.jar` would have failed at container
start with `no main manifest attribute in app.jar`.

## Verified image properties

```
Config.User        10001:10001                          (FR-057, matches runAsUser)
Entrypoint         ["java","-XX:+UseZGC",
                    "-Djava.security.egd=file:/dev/./urandom",
                    "-jar","app.jar"]                    exec form (FR-058)
JAVA_TOOL_OPTIONS  not set                               agent inert (D10)
OTel agent         /opt/otel/opentelemetry-javaagent.jar  21,312,487 bytes
Lua resources      lua/refresh_issue.lua
                   lua/refresh_revoke_all.lua
                   lua/refresh_revoke_family.lua
                   lua/refresh_rotate.lua               classpath layout preserved
                                                        (Constitution Principle III)
```

The Lua listing is worth its own line. `auth-service` loads those scripts by
classpath path, so a build that flattened or relocated resources would break a
load site no compiler checks. They are present at `lua/*.lua` exactly as the
load site expects.

## What this does NOT establish

The images build and `auth-service` starts far enough to initialise Tomcat and
its repositories. It has not been run against real Postgres and Redis, in a
cluster, behind the gateway — that is `make setup` followed by
`make test-integration`, and it requires `kind` and `helm`, which this
workstation does not currently have. See `docs/known-gaps.md`.

---

## US1 — reproducible platform: EXECUTED, PASS

Run on this workstation (macOS arm64, OrbStack-backed Docker 29.4.0,
kind v0.32.0, helm v4.2.4, Kubernetes v1.36.1).

| Check | Result |
|---|---|
| `cluster.sh create` | 3 nodes registered, all NotReady as expected with `disableDefaultCNI` |
| `platform.sh namespaces` | 4 namespaces, PSA pinned to v1.36 |
| `platform.sh gateway-api` | Gateway API v1.3.0 standard channel; no experimental CRDs |
| `platform.sh cilium` | chart 1.18.1 installed; all 3 nodes reach Ready |
| `platform.sh net-status` | **7/7** — agents healthy, kube-proxy replacement active, **no kube-proxy DaemonSet**, Envoy Ready 3/3 |
| `tests/smoke/net-test.sh` | **6/6** — real pod→pod **cross-node**, pod→Service via the kube-proxy replacement, cluster DNS |
| `certs.sh ensure` / `verify` | **4/4** and **8/8** — CA, leaf, truststore, TLS Secret, nothing tracked by git |
| `platform.sh gateway` | Gateway `Programmed`, NodePort pinned to 30443 |
| `platform.sh gw-status` | **6/6** — one GatewayClass, listeners resolved, declared NodePort |
| `tests/smoke/gw-test.sh` | **9/9** — TLS verified against the lab CA, **HTTP 404 with `server: envoy`** |

The last line is the US1 acceptance: a request from the workstation to
`https://acme.localhost` completes a verified TLS handshake and receives a
response produced **inside** the cluster. A 404 is the correct answer with no
routes installed — it proves Envoy terminated TLS and made a routing decision.

### Five defects found by executing, not by reading

Each of these produced a green-looking artifact and a broken environment.

| # | Defect | How it presented |
|---|---|---|
| 1 | **`mktemp` template with a suffix** — BSD `mktemp` does not substitute `X`s that are not at the end, so the rendered kind config was written to a literal filename and left empty. `kind create --config <empty>` silently used its **defaults**: one node, default CNI, kube-proxy on. | A cluster that looked healthy and was the opposite of the declared topology |
| 2 | **Bash 3.2 `local a=1 b=$a`** under `set -u` — macOS's Bash cannot reference a name declared in the same `local` statement. | `hidden: unbound variable`, every seeded-failure case failing for the wrong reason |
| 3 | **Bash 3.2 empty-array expansion** — `"${arr[@]}"` errors under `set -u` when empty. | `extra[@]: unbound variable` mid-install |
| 4 | **Cilium's operator probes for the Gateway API CRDs once, at startup** and disables Gateway support if absent, with no retry. The original checkpoint order installed Cilium first. | Gateway stuck at `Accepted=Unknown, Waiting for controller` forever, with nothing in its status naming the cause |
| 5 | **`envoy.log.format` broke the chart's own bootstrap template** — the rendered ConfigMap came out as `{"Error":"error converting YAML to JSON..."}`. | `cilium-envoy` crash-looping on `no such field: 'Error'`, three layers from the cause |

Defect 4 changed the design: `gateway-api` now runs **before** `cilium` in the
checkpoint order, and `setup.sh` says why.

Defect 5 also exposed a weakness in the lab's own checking: `net-status`
originally asserted only that the Envoy DaemonSet **existed**, and passed
cheerfully while all three Envoy pods were in `CrashLoopBackOff` — reporting the
gateway's entire data plane healthy when no gateway could serve. That is exactly
the asserted-pass FR-098 forbids. The check now reads `numberReady`.

### A finding that changes what the lab can claim: `*.localhost` wildcards

Measured directly, with a control:

| SAN | Requested host | Result |
|---|---|---|
| `*.localhost` | `acme.localhost` | **REJECTED** — curl exit 60, `subjectAltName does not match host name` |
| `*.lab.localhost` | `acme.lab.localhost` | accepted, HTTP 200 |

A TLS client will not match a wildcard against a **single-label parent**.
`localhost` is a public suffix, and the rule every mainstream client implements
refuses `*.<TLD>` outright — otherwise one certificate could impersonate a whole
top-level domain.

**Consequence, stated precisely:**

- FR-040 / SC-007 hold for **routing**. A new tenant needs no Gateway, no
  HTTPRoute, no listener — that is asserted by the new-tenant test.
- They do **not** hold for **TLS on this base domain**. The certificate has to
  enumerate tenant hostnames in its SAN.

This is a property of `.localhost`, **not** of Kubernetes-as-edge. With a real
base domain (`*.hydra.example.com`) the wildcard matches and the property is
fully preserved. It belongs in the Edge Finding as a limitation of the lab's
addressing choice, not as evidence against the architecture.

Changing the base domain to a two-label form was considered and rejected:
`EdgeConformanceFixture` fixes `acme.localhost` and `beta.localhost` as
constants, and serving anything else would mean editing Hydra's existing suite —
which SC-020 forbids outright.

---

## US2 — Hydra's real services in Kubernetes: EXECUTED, PASS

The full flow, run against the live cluster:

```
POST https://acme.localhost/api/v1/auth/login      -> 200, JWT issued (729 chars, roles ["ROLE_USER"])
POST https://acme.localhost/api/orders             -> 201, order LAB-0001 created
GET  https://acme.localhost/api/orders             -> 200, 1 order
GET  https://beta.localhost/api/orders             -> 200, 0 orders   <- tenant isolation
GET  https://acme.localhost/api/v1/tenant          -> {"status":"recognized","displayName":"Acme Corp"}
GET  https://beta.localhost/api/v1/tenant          -> {"status":"recognized","displayName":"Beta Inc"}
```

Everything above traversed the real path: workstation → kind port mapping →
fixed NodePort → Cilium Envoy (TLS terminated against the lab CA) → HTTPRoute →
ClusterIP → pod. Certificate verification was enabled for every request.

What each line proves beyond "it returned 200":

- **Both tenants resolve to themselves, not to `unknown`.** The `Host` header
  survived TLS termination and host-based listener matching untouched (FR-036).
- **`order-service` validated the JWT**, which means it fetched JWKS from
  `auth-service.hydra-app.svc.cluster.local:8083` over cluster DNS by service
  name (FR-045) — a pod address would have worked too, so the *listing*
  succeeding is what shows the Service name resolved.
- **Tenant isolation holds across the gateway.** `beta` signs in successfully
  and sees zero orders; the tenant came from the address, and the data followed.
- **The fixture's anti-drift guard passed**: `OK: the seeded credential
  authenticates against acme.localhost`. Row counts were never treated as
  success (D7).

Deployment state: 3 + 3 replicas Ready, both migration Jobs `Complete` before
any replica started (FR-052), fixture Job `Complete`, all on new ReplicaSets.

### Seven more defects found by executing

| # | Defect | How it presented |
|---|---|---|
| 6 | **Two Helm releases of one chart** (`hydra-lab-data` + `hydra-lab`) both claim the shared NetworkPolicies and PDBs | `invalid ownership metadata; annotation validation error` — fixed by one release upgraded in two steps |
| 7 | **Duplicate `JAVA_TOOL_OPTIONS` env key** — the shared env helper emitted it, the migration Job appended an empty override | Server-side apply refuses duplicates outright: `duplicate entries for key [name="JAVA_TOOL_OPTIONS"]`. Fixed with an explicit `noAgent` opt-out |
| 8 | **The migration Job raced Cilium's policy programming.** `rate-limit-starter` opens a Lettuce connection eagerly at context refresh; the JVM lost the race and the Job died where a Deployment would simply have restarted | `Unable to connect to redis...:6379` while an identical probe pod resolved it a minute later. Fixed with a dependency gate initContainer **and** `RATE_LIMIT_ENABLED=false` — a schema migration has no business rate-limiting, and turning the starter off kept the NetworkPolicy as narrow as it claims to be rather than widening it to make an error disappear |
| 9 | **The mounted ConfigMap was never loaded.** `application-lab.yml` is only read when the `lab` profile is active; the pods ran `test` alone | Silent — a configuration file that is not loaded produces no error at all. Surfaced only when the probes started returning 401. Fixed with `SPRING_PROFILES_ACTIVE=test,lab`, which also gives the mounted file precedence over the packaged `application-test.yml` |
| 10 | **A Helm hook Job mounting a chart-managed ConfigMap.** Hooks run *before* ordinary resources, so the Job saw the previous revision's copy | An edit to the ConfigMap was invisible to the Job; the Job kept failing on stale content; the failing hook aborted the upgrade; the Deployments therefore never received *any* new configuration. One stale mount stalled the whole release |
| 11 | **Health groups naming a contributor that does not exist is a startup failure** | `Health contributor 'redis' defined in 'management.endpoint.health.group.readiness.include' does not exist` — one ConfigMap serves both services and `order-service` has no Redis |
| 12 | **`user_roles.role` stores the enum constant, not the authority string** | `violates check constraint "user_roles_role_check"` on `ROLE_USER`; the stored value is `USER`. Worth noting the CHECK constraint was authored by the migration Job's Hibernate run — the schema caught the fixture's mistake |

### Two findings that changed the design

**The actuator health-group endpoints are unreachable in this repository.**

```
GET /actuator/health             -> 200
GET /actuator/health/readiness   -> 401
GET /actuator/health/liveness    -> 401
```

`SecurityCommons.authRules()` permits the **exact** path `/actuator/health` and
then falls through to `.anyRequest().authenticated()`. The kubelet received 401
on the liveness probe and killed every pod — observed as `exit 143` and
`Liveness probe failed: HTTP probe failed with statuscode: 401`.

Moving actuator to its own `management.server.port` was tried and does **not**
help: the parent context's `SecurityFilterChain` still applies, and the group
endpoints return 401 there too.

The one-line fix — `.requestMatchers("/actuator/health/**").permitAll()` — is a
change to shared service source, which FR-044 and the plan's structure decision
put outside this feature. So the probes were shaped around what is reachable:
`/actuator/health` for startup and readiness (it already aggregates each
service's real dependencies, so readiness means what it should), and a **TCP**
check for liveness (depends on nothing external, which is the property that
matters). FR-063's substance is preserved; its literal three-endpoint form is
not. The cost is stated in `values.yaml`: a TCP liveness probe cannot detect a
JVM that is alive but deadlocked.

**Gateway traffic carries Cilium's `reserved:ingress` identity, which a standard
NetworkPolicy cannot express.**

Every request through the gateway returned:

```
upstream connect error or disconnect/reset before headers. reset reason: connection timeout
```

while routes reported `Accepted` and all pods were healthy. A temporary
allow-all ingress made it work instantly, locating the fault in the policy.

When Cilium's Envoy proxies to a backend, the connection does **not** carry the
identity of a kube-system pod — it carries `reserved:ingress`. A standard
NetworkPolicy has no way to name that, so the traffic fell through to
default-deny. `fromEntities: [ingress]` exists only in `CiliumNetworkPolicy`, so
that single rule is now a Cilium CRD; every other rule in the file remains a
standard NetworkPolicy. FR-029 is untouched — still one GatewayClass, still no
standalone controller.

This one is genuine evidence for the Edge Finding: a Kubernetes edge whose
NetworkPolicy story requires vendor CRDs to express "let the gateway in" is a
real portability cost, and it is invisible until traffic actually flows.

---

## Full rebuild from nothing: EXECUTED — checkpoint verdicts SUPERSEDED

> **Correction.** The "15/15 checkpoints PASSED" below was produced by a
> checkpoint runner that **could not report a failure** — see "The checkpoint
> runner could not report a failure" later on this page. Those fifteen verdicts
> are not evidence and should not be cited. The **suite** results in this
> section (35/35 smoke, 21/21 integration, the drills, SC-008/010/011) came from
> a different mechanism that was never affected, and they stand.

`make cleanup` followed by `make setup`, on a machine with no cluster, no
registry and no images:

```
cluster            PASSED  1 control-plane + 2 workers, all Ready
namespaces         PASSED  4 namespaces; no app workload in default
gateway-api        PASSED  Gateway API v1.3.0 (standard channel)
cilium             PASSED  1.18.1: kube-proxy replacement, L7 proxy, policy, Hubble
registry           PASSED  reachable from the cluster by an executed pull
images             PASSED  both services built and published, revision-derived tag
certs              PASSED  CA + wildcard + truststore + TLS Secret
gateway            PASSED  Programmed on :443 via NodePort 30443
backing-services   PASSED  Postgres and Redis Ready, real probes passing
observability      PASSED  Prometheus, Grafana, OTel Collector, Tempo
argocd             PASSED  Ready, root Application registered
console            PASSED  Headlamp Ready
migrate            PASSED  schema authored by one instance per service
fixture            PASSED  tenants seeded AND a real sign-in succeeded
apps               PASSED  auth-service and order-service Ready behind the gateway
```

### Suites, executed against that environment

| Suite | Result |
|---|---|
| `tests/smoke/run.sh` | **35/35 PASS** |
| `tests/integration/run.sh` | **21/21 PASS** |
| `tests/failure/pod-delete.sh` | **6/6 PASS** — 100% availability through a pod deletion (SC-008) |
| `tests/failure/network-policy.sh` | **10/10 PASS** — 100% denied / 100% allowed (SC-013) |
| `tests/failure/concurrent-rotation.sh` | **9/9 PASS** — SC-010 |
| `tests/failure/cross-replica-limit.sh` | **7/7 PASS** — SC-011 |

### SC-010: Constitution Principle IV is now an observation

This is the result the constitution turns on. Principle IV — Atomic Distributed
State Mutations, NON-NEGOTIABLE — has been an argument about a Lua script. It is
now a measurement.

**120 concurrent rotations of ONE renewal credential, across 3 replicas:**

```
200 = 20     429 = 100     rejected = 0     5xx = 0
DISTINCT new credentials issued across all successes: 1
```

**One credential. Twenty observers.**

Getting the assertion right mattered more than running it. The obvious test —
"exactly one request returns 200" — reported a constitutional violation against
a perfectly correct implementation. `refresh-token.grace-ttl` (PT5S) exists so a
client that retries is not logged out: within the window the already-rotated
credential is honoured again and **the same** new token is returned. Concurrent
callers therefore *should* all succeed.

So the assertion is on **distinct credentials issued**. If two callers received
different new tokens, two independent rotations happened and the token family
has forked — one revocation would no longer revoke the other. They did not.

That assertion is *stricter* than counting successes, not laxer: it can tell
"one rotation replayed" from "many rotations", which counting cannot do in
either direction.

### SC-011: the rate limit is shared, not per-replica

20 sequential attempts from one address against a capacity of 5, with 3
replicas:

```
admitted = 2     throttled = 18
```

A per-replica limiter would have admitted up to 15. This is the failure mode
that is invisible in every single-instance test and silently multiplies a limit
by the replica count in production.

### SC-008: 100% availability through a pod deletion

```
total=816  success=816  failed=0  throttled=758  rate=100.00
```

The throttled count is worth reading. The first version of the load client
counted a 429 as lost service and reported **0.45%** availability against a
healthy cluster — it was measuring the rate limiter, not availability. A 429 is
the service answering correctly; lost service is 5xx or no response.

### Six further defects found by executing

| # | Defect | How it presented |
|---|---|---|
| 13 | **`make setup` never built the images.** Cleanup removes the registry and everything in it | Setup reached `migrate` and sat in ImagePullBackOff against a healthy registry. Fixed with an `images` checkpoint, placed early so a broken build surfaces before ten minutes of platform install |
| 14 | **Helm 4 persisted `--set` values.** The datastore phase sets `replicas=0`; the full deploy inherited it | Both services ran at **zero replicas** while every checkpoint reported success — 0 desired and 0 ready are equal. Surfaced three layers away as Services with no endpoints and a 503 gateway. Fixed with `--reset-values` |
| 15 | **`extraMounts` only on the control-plane node.** The scheduler put argocd-repo-server on a worker | `hostPath type check failed: /gitops-remote is not a directory`. A hostPath is a promise about *every* node a pod might land on; it would have "worked" on any run where the scheduler chose the control plane |
| 16 | **`argocd-check` passed with zero Applications.** It verified Deployments and the CRD | A delivery control plane running and reconciling nothing, reported healthy. Exactly the asserted-pass FR-098 forbids |
| 17 | **Bean validation runs before the rate-limit aspect.** `@Size(min=8)` on the password | Fifteen login attempts produced zero throttling against a working limiter — they were rejected as 400 at argument binding and never reached the aspect |
| 18 | **`/dev/tcp` is a bash feature.** The authorised-path probe ran it under busybox `sh` | 0/5 successes against a policy that was permitting the traffic. Fixed by making the authorised probe use the *same image and method* as the intruder, differing only in labels — which is what isolates the variable |

Defect 16 is the one worth dwelling on: the check that was supposed to enforce
"no component reported healthy without an executed check" was itself an asserted
pass. That is the failure mode the requirement exists to prevent, found in the
requirement's own enforcement.

---

## FR-102 / SC-020 — Hydra's existing suites pass unchanged: EXECUTED, PASS

`mvn -B test` over the whole reactor:

```
hydra ................................ SUCCESS
infra-shared ......................... SUCCESS
infra-database ....................... SUCCESS
rate-limit-starter ................... SUCCESS
browser-edge-starter ................. SUCCESS
auth-service ......................... SUCCESS [03:18 min]
order-service ........................ SUCCESS
integration-tests .................... SUCCESS

BUILD SUCCESS      0 failing suites, 0 errors
```

Including `Transparent edge: all five clauses pass` (6 tests) and `Hostile edge:
the suite detects and fails on each violation` (2 tests), both green.

**Zero assertions were modified.** `git diff --exit-code integration-tests/`
returns clean, and `edge-conformance.sh` asserts that before every run — so a
run that had required bending a clause could not have reported a pass.

The only files changed outside `k8s-lab/` in this entire feature are:

```
.dockerignore              (new)
auth-service/Dockerfile    (modified)
order-service/Dockerfile   (modified)
```

No service source, no service resource, no `pom.xml`, no test.

### A finding about the local environment, not the repository

The first attempt failed with:

```
liquibase.exception.ChangeLogParseException: Found 2 files with the path
'classpath:/db/changelog/db.changelog-master.yaml'
```

This looked exactly like research finding A3's predicted upgrade hazard — and it
was not. The cause was **stale build output**: `~/.m2` held an `order-service`
jar installed on 2026-08-19 whose `target/classes` still contained an orphaned
`db/changelog/` tree from an older resource layout. Maven copies resources
incrementally and does not remove files that have moved, so the jar carried both
the current `changes/` path and the abandoned `db/changelog/` one — colliding
with `auth-service`'s changelog at the identical path.

`mvn clean install` on the affected modules fixed it, and the suite passed.

Two things worth keeping from that:

1. **The repository is fine.** Anyone hitting this should suspect `target/`
   before suspecting the Liquibase configuration — the error names Liquibase and
   the cause is a stale directory.
2. It is a live demonstration of why A3's hazard is worth taking seriously.
   `LiquibaseAutoConfiguration` *is* on the integration-tests classpath and *does*
   attempt to parse those changelogs. The only reason it is harmless today is
   that it finds exactly one.

### Resource contention worth knowing about

The suite could not be run while the lab cluster was up. Testcontainers needs
Docker capacity, the kind nodes hold most of the allocation, and container
creation simply hung — the log sat unchanged for 30 minutes on
`Creating container for image: redis:8.8-alpine`.

Running order matters on a 15 GB Docker allocation: `make cleanup`, then
`mvn test`, then `make setup` again. The rebuild costs about eight minutes,
which is measured rather than estimated.

---

## SC-001 — setup timing: EXECUTED, but it timed an unverified run

```
Elapsed: 7m 49s     (budget: 45 minutes from a clean machine)
```

> **Correction.** This timed a run whose fifteen checkpoint verdicts were
> produced by the defective runner described later on this page, so "to fifteen
> passed checkpoints" overstates what was established. The **wall-clock figure
> itself is still a measurement** — the work was done and the images were built
> — and it remains far inside the 45-minute budget. What it does not establish
> is that the resulting environment had passed fifteen verified gates.
>
> For scale, the first pass of the SC-003 loop took **33m 49s** for the same
> sequence on a machine that had been running the lab for five hours.

From `make cleanup` to a deployed environment, including building and
publishing both service images. Well inside budget — and the budget is for a
genuinely cold machine, where node and chart images must also be pulled.

---

## SC-019 — the developer interface

`scripts/verify-targets.sh` checks that every target in
`contracts/developer-interface.md` exists, is documented in `make help`, and —
for the non-destructive ones — exits zero against a healthy environment.

Two failures it reported were real and are fixed:

- **`verify-versions`** — the GitOps canary carried `image: registry:3.0.0` and a
  numeric `sleep`, both caught by the lab's own guards. The canary is now a
  template rendered by `gitops.sh` from `versions.env`, and uses
  `sleep infinity`.
- **`cluster-health`** — failed during the window when Docker was saturated by
  the concurrent Maven run. Environmental, not a defect; it passes as part of
  `make validate`'s 17/17.

Eight targets the quickstart uses (`test-xff-forgery`, `test-new-tenant`,
`test-trace`, `test-gitops`, and others) were **missing from the Makefile** and
have been added — found by walking `quickstart.md` against the built lab (T158).

---

## The `make validate` suite interaction: DIAGNOSED AND FIXED

The previous session recorded `integration-suite` FAIL inside `make validate`
against a suite that returned 21/21 standalone, and attributed it to "the smoke
suite exhausts the per-address login limit; the integration suite's 180s
precondition budget is too narrow". **Measured, that diagnosis is wrong on both
halves, and the fix it implies would not have worked.**

### What was measured

| Measurement | Result |
|---|---|
| Logins made by the smoke suite | **exactly one** — it cannot exhaust a capacity-5 bucket |
| Login limiter dimensions | **two**, independent: `login-ip` and `login-username`, each capacity 5 / PT1M |
| Refill shape | Bucket4j `refillIntervally` — the whole capacity returns as a **lump** at a boundary |
| Recovery after one exhaustion | **71s**, well inside the existing 180s budget |
| Drain `labuser` to 429, then try a **different** username from the same address | **two further requests succeeded** — the two dimensions bind at different moments |
| Wait out a 429's `Retry-After`, then count consecutive sign-ins | **3**, not 5 — synchronised with one boundary, not the other |
| Wait a full quiet window (65s, zero login traffic), then count | **5** |

### The actual defect

The two buckets are keyed differently, created at different moments, and refill
on **independently phased boundaries**. Usable headroom is therefore
`min(ip_remaining, username_remaining)`, and **no single probe can measure it**.

The old precondition polled until **one** login returned 200 and declared the
window clear. The suite then spends **three more** (acme sign-in, beta sign-in,
wrong-password). So it passed its precondition honestly and ran out of tokens two
assertions later.

**A wider budget changes nothing** — the precondition was already passing. It was
measuring the wrong thing, not measuring it for too short a time.

### The fix

`scripts/lib/ratelimit.sh` establishes a state that is **known** rather than
inferred: drain every dimension to empty — a 429 consumes nothing, so this costs
only the tokens that were there — and then wait for the **first 200**, which
proves both dimensions refilled, because a sign-in needs a token from each. That
is a condition, observed, not a duration guessed (FR-015). It leaves capacity-1
sign-ins, and the suite spends three of them.

| Verification | Result |
|---|---|
| `tests/integration/run.sh` standalone | **21/21 PASS** |
| The same suite run **twice back-to-back** — strictly harder than the case that failed | **21/21 PASS, both times** |
| `make validate` | **17/17 PASS, `integration-suite` included** |

---

## FR-042 — the hostile edge: EXECUTED, PASS, after five defects

This is the check on the conformance suite itself: run the same unmodified suite
against a gateway that is **wrong on purpose**, and require it to fail and name
the clause. It had never been run. Running it found that **it could not have
worked**, in five separate ways.

| # | Defect | How it presented |
|---|---|---|
| 19 | **`RequestHeaderModifier` cannot set `Host`.** Gateway API excludes that header from the filter by specification, so a conformant implementation ignores it **silently** | The HTTPRoute reported `Accepted=True`, the filter was present in `.spec`, and `/api/v1/tenant` answered `{"status":"recognized"}` — a hostile configuration that was not hostile. The suite then passed, correctly, and the drill reported **"the suite PASSED against the hostile gateway"**: an accusation against a suite that was working the whole time. Fixed with `URLRewrite.hostname`, which produces the documented symptom |
| 20 | **An unenforceable precondition warned and continued.** The drill's own "the hostile configuration is in force" check *did* fail — and then logged "running the suite anyway" | That is what turned defect 19 into a false accusation instead of a clear report. Now fatal: if the edge cannot be made hostile, the drill has established nothing and says so |
| 21 | **`set -e` leaked out of `run_suite`.** It ended with a bare `set -e` to "restore" a flag the script never had — its top line is `set -uo pipefail` | Silent and destructive: the next statement is a `grep` that legitimately matches nothing, and the whole drill exited there. No clause check, no summary — **every executed check reported PASS and the run exited non-zero with nothing saying why** |
| 22 | **`applied` was `local` but read by the EXIT trap.** Exposed only by fixing 21 | The trap aborted with `applied: unbound variable` **before the revert ran**. The drill reported **5/5 PASS and exit 0 while leaving the gateway rewriting `Host` on every request.** A drill that does not restore is a failed drill however many of its assertions passed |
| 23 | **The clause check grepped `maven.log` for `Clause [0-9]+`** — a string the suite never prints. Surefire names the failing **method**; the clause wording lives in `@DisplayName` | It could only ever report "it failed but did not name a clause", against a suite that names it precisely. Now read from the Surefire XML and labelled from the suite's own annotation, so `integration-tests/` stays the single authority for the mapping |

Defects 21 and 22 are worth reading together: the first **masked** the second.
While `set -e` leaked, the drill died inside the function where the local was
still in scope, so the revert ran. Fixing the leak is what let the drill run to
completion — and reveal that its restore had been depending on a bug.

### The executed result

```
PASS  certificate verification is enabled and cannot be disabled here
PASS  integration-tests/ is unmodified
PASS  hostile configuration applied
      the hostile configuration is in force: satisfied after 2 evaluation(s), 3s
PASS  the suite FAILED against the hostile gateway, as required
PASS  it named the violated clause(s)
        Clause 1: Host reaches the service unmodified, so a known tenant resolves
        Clause 5: a second tenant resolves through the same edge with zero new configuration

==> reverting the hostile configuration
PASS  the environment is back to a state where conformance passes
      5 PASS   0 FAIL — exit 0, and the gateway confirmed serving correctly afterwards
```

The restore is now verified by **substance**, not status code. The hostile edge
returns HTTP 200 as well — it answers `{"status":"unknown"}` with a 200 — so the
original check could not tell a restored gateway from a still-hostile one.

---

## The remaining five failure drills: EXECUTED

Four of the nine were previously run. The other five have now been executed.

| Drill | Result |
|---|---|
| `bad-image` | **7/7 PASS** — ImagePullBackOff observable, gateway kept serving, healthy replicas untouched (`maxUnavailable: 0`), restore verified |
| `rolling-update` | **10/10 PASS** — **SC-009**: `total=1613 success=1613 failed=0`, ready replicas never dropped below desired |
| `cache-down` | **5/5 PASS** — **FR-056** fail-closed observed: with Redis at zero the request was **rejected (429)**, not passed through |
| `node-stop` | **6/6 PASS** — node observed NotReady in 40s, restore verified, and the drill prints its own five limitations |
| `readiness-fail` | **BLOCKED** — see below |

### Two more defects, both found by executing

**Defect 24 — a StatefulSet at zero omits `readyReplicas` entirely.**

`cache-down` scales Redis to zero and then waits for it to be gone. The idiom

```bash
"$($K ... -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)"
```

is wrong in exactly that case: `.status.readyReplicas` is `omitempty`, so a
workload at zero reports **nothing**, and the query returns an empty string while
kubectl **exits successfully** — the `|| echo 0` fires only on failure. The
condition compared `""` against `"0"` and never matched.

Measured: `redis is gone` timed out after **120s** against a Redis that had been
gone for 118 of them. The drill then went on to observe the correct fail-closed
429, so it reported the right behaviour and a failed assertion simultaneously.
With `ready_replicas()` the same condition is satisfied in **3s**.

**Defect 25 — `readiness-fail` logged PASS for a trigger that returned 401.**

The drill discarded the trigger's response and logged a pass unconditionally,
then failed the endpoint assertion 120s later and pointed at readiness. An
asserted pass on a *trigger* does the most damage of anywhere it can appear,
because every assertion after it is interpreted in its light (FR-098).

Reading the response showed the real state: with `readinessToggle.enabled=true`,

```
POST /actuator/serviceregistry?status=OUT_OF_SERVICE  ->  401
```

**The readiness toggle is unreachable for the same reason as the health-group
endpoints** (`known-gaps.md` §3): `SecurityCommons.authRules()` permits the exact
path `/actuator/health` and falls through to `.anyRequest().authenticated()`.
`readinessToggle.enabled=true` exposes the endpoint; it does not authorise it.

The drill now reports **BLOCKED** — not FAIL, and certainly not PASS. The
mechanism was never exercised, so nothing was established about readiness either
way. In the shipped default configuration the toggle is off and the drill
continues to report `SKIPPED-BY-CONFIGURATION`, which is unchanged and correct.

---

## SC-015 seeded component failures: ATTEMPTED, INVALIDATED BY THE ENVIRONMENT

Not a pass, and not a lab failure either. Recorded because a discarded run that
goes unmentioned is indistinguishable from one that never happened.

The run seeds a fault into one component at a time and requires `make validate`
to return non-zero **and name that component**. Case 1 behaved exactly as
specified:

```
==> seeding: applications
PASS  applications: validate returned non-zero (1)
PASS  applications: the verdict table names 'applications' as FAIL
PASS  applications: restored and verified
```

During case 2 the **Docker daemon stopped answering**. Every `docker` and
`kubectl` call hung; the `datastores` and `gateway` restores both timed out at
420s, and the run ended with `No cluster.` The daemon recovered on its own
several minutes later with all four containers still up, and the lab returned to
health once Redis was scaled back — without a rebuild.

**Cases 2 and 3 therefore establish nothing about SC-015 in either direction.**
Their failures are attributable to the host, not to the checks: the assertion
"the verdict table did not report 'datastores' as FAIL" was evaluated against a
`validate` run that could not reach a cluster at all.

One thing it did establish incidentally: the lab recovered from an abrupt daemon
hang and a workload left scaled to zero **without** a rebuild.

---

## The checkpoint runner could not report a failure: FOUND, FIXED

This is the most serious defect found in this feature, and it invalidates a
claim made repeatedly on this page. It was found by the SC-003 reproducibility
loop — which is what that criterion is for.

### The bug

`scripts/lib/checkpoint.sh` captured exit status like this:

```bash
if ! validation_out="$(bash -c "$validation" 2>&1)"; then
  validation_rc=$?
fi
```

In `if ! cmd; then`, `$?` inside the branch is the status of the **negation**,
not of `cmd`. When `cmd` fails, `! cmd` succeeds, and `$?` is **0**. Verified
directly:

```
$ if ! out="$(bash -c "exit 7")"; then rc=$?; fi ; echo $rc
0
$ out="$(bash -c "exit 7")" || rc=$? ; echo $rc
7
```

So `validation_rc` was **always zero**, `(( validation_rc == 0 ))` was always
true, and **every checkpoint reported PASSED regardless of what its validation
did.** The file's header states the invariant it was violating:

> A checkpoint may report PASSED only if its VALIDATION command exited zero.
> No checkpoint asserts its own success.

The identical bug on `action_rc` silenced the "the action exited N while the
validation passed" note — the one diagnostic that would have exposed this.

### How it surfaced

The `images` checkpoint printed, from its own validation command:

```
FAIL  refusing to publish a -dirty image  [FR-017]
--- image publish: 1 checks ---
  PASS 0   FAIL 1
image publish: FAIL
```

and was recorded on the very next line as:

```
PASS  checkpoint images  [/…/scripts/images.sh publish]
   auth-service and order-service built and published under a revision-derived tag
```

Setup then reported **"All 15 checkpoints PASSED"** with an empty registry, and
the first honest signal came two checkpoints later as `ImagePullBackOff` —
naming a registry that was perfectly healthy.

### What this invalidates

**Every "15/15 checkpoints PASSED" result recorded on this page was produced by
a runner that could not express a failure.** That includes the "Full rebuild
from nothing" section and the SC-001 timing figures, which timed a run whose
checkpoint verdicts were not verdicts.

What is **not** affected, because it never used this runner:

- `validate.sh`'s verdict table — its `check()` uses `if "$@"; then`, which is
  correct, and it is what caught the failure the checkpoints missed
- every suite result (`smoke 35/35`, `integration 21/21`, the drills, the
  conformance runs) — those come from `log_pass`/`log_fail` counters directly

That division is worth stating plainly: the aggregate reporter was sound and
the checkpoint gate was not, so the executed *suite* numbers on this page stand
and the *checkpoint* numbers do not.

### The fix

```bash
action_out="$(bash -c "$action" 2>&1)"     || action_rc=$?
validation_out="$(bash -c "$validation" 2>&1)" || validation_rc=$?
```

Verified against a deliberately failing validation:

```
==> checkpoint deliberately-failing: running
FAIL  checkpoint deliberately-failing  [exit 3]
  -> checkpoint_run returned 1, state FAILED
BLOCKED  checkpoint ok  (checkpoint 'deliberately-failing' failed earlier)
```

The failure propagates and blocks what follows, which is what FR-014 specifies.

---

## Two defects that made the lab dirty its own repository

Both found in the same run, and together they explain the empty registry.

### The lab deleted tracked files during cleanup

`k8s-lab/.gitops-remote/` — the bare repository Argo CD reconciles from — was
**tracked in git**, and `cleanup.sh` does `rm -rf` on it. So every cleanup left
24 tracked files showing as deleted, `git status --porcelain` was never empty,
the revision-derived image tag gained a `-dirty` suffix, and `images.sh publish`
**correctly refused** to publish an unreproducible tag (FR-017).

The lab dirtied its own repository during cleanup and then refused to build
because the repository was dirty. It is now gitignored and untracked, alongside
`results/` and `.certs/` — it is generated state, recreated by `gitops.sh`.

### A stale image tag outlived the registry it pointed at

`results/current-image-tag` is written by `images.sh publish` and read by
`app.sh` to decide which tag the chart deploys. `cleanup` keeps `results/` by
default — reasonably, it is run evidence — but this file is not evidence, it is
**live state**.

Because publish refused, it was never rewritten, so it still held
`dc8c1c9-dirty` from a previous session. The freshly created, empty registry was
then asked for an image that had never been published into it:

```
Failed to pull image "localhost:5001/hydra/auth-service:dc8c1c9-dirty":
  not found
```

while the current run had built and tagged `31e9344-dirty`. `cleanup` now
removes that pointer always, including when `results/` is kept.

---

## T156 (SC-003) — NOT COMPLETED, and now for a known reason

The unattended loop was built (`scripts/reproducibility.sh`, `make
validate-repro`) and **run**. It did not produce a reproducibility verdict, and
it did something more useful: it found the checkpoint defect above.

| Pass | Result |
|---|---|
| 1 | **FAIL** after 52m 44s — setup reported 15/15 (falsely), `validate` then reported 7 components FAIL |
| 2 | Aborted mid-run — `hydra-migrate-auth` in `ImagePullBackOff` on a stale tag |
| 3 | Not started |

The run was stopped deliberately once the cause was understood, because three
passes of a setup that **cannot report a failure** measure nothing.

### What a valid re-run requires, and the tension in it

`validate-full` → `setup` → `images` → `publish`, and publish refuses a `-dirty`
tag by design. With `.gitops-remote` untracked the lab no longer dirties the
tree itself, so the remaining source of dirt is ordinary uncommitted work.

**SC-003 therefore cannot be satisfied against a working tree with uncommitted
changes** — not because of a defect, but because FR-017 and SC-003 are saying
the same thing: a rebuild you cannot reproduce from a revision is not a
reproducible rebuild. The options are a clean tree, a dedicated checkout at a
known commit, or `ALLOW_DIRTY_PUBLISH=1` — and the third forfeits exactly the
property being measured, so it should not be used to produce an SC-003 result.

This is recorded as incomplete. It has not been established.
