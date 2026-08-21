# Known gaps and divergences

What this lab does **not** cover, what it does differently from production, and
what it found and deliberately did not fix.

FR-116 forbids reporting this feature complete on the strength of generated
files. This page is the other half of that: the things that are true and
inconvenient. [executed-results.md](executed-results.md) records what was
actually run.

---

## 1. Three build defects, two fixed here and one left alone

A container build of this repository was **impossible** before this feature.

| # | Defect | Status |
|---|---|---|
| A1 | `COPY mvnw .` referenced a Maven wrapper that has never existed in this repository | **Fixed** — pinned Maven toolchain image |
| A2 | `browser-edge-starter` was in neither Dockerfile, though both services declare it | **Fixed** — added to both layers |
| A8 | `spring-boot:repackage` never ran, so `mvn package` produced a plain jar with no `Main-Class` | **Worked around in the Dockerfiles** |

### A8 deserves a proper fix that this feature did not make

`spring-boot-maven-plugin` sits in the root pom's `<pluginManagement>` with a
version and **no `<executions>` block**, and the project does not use
`spring-boot-starter-parent`. Nothing binds the `repackage` goal to the
`package` phase, so `java -jar app.jar` fails with `no main manifest attribute`.

The Dockerfiles now run `mvn install` for the siblings and then
`mvn package spring-boot:repackage` for the service. That works, and it is the
wrong place for the fix. The right fix is four lines in each service pom:

```xml
<plugin>
  <groupId>org.springframework.boot</groupId>
  <artifactId>spring-boot-maven-plugin</artifactId>
  <executions>
    <execution><goals><goal>repackage</goal></goals></execution>
  </executions>
</plugin>
```

It was not made here because the plan confines this feature's blast radius
outside `k8s-lab/` to the two Dockerfiles. **Anyone touching the build should do
this and delete the workaround.**

---

## 2. Liquibase is wired, on the classpath, and does not run

`liquibase-core` is on `auth-service`'s runtime classpath and its master
changelog sits at Spring Boot's **default** location. Under Boot 3 that would
run at startup. Under Boot 4 it does not: per-technology auto-configuration
moved out of `spring-boot-autoconfigure` into dedicated modules, and
`org.springframework.boot:spring-boot-liquibase` appears **nowhere** in either
service's dependency tree. `liquibase-core` ships no `AutoConfiguration.imports`,
so it cannot self-register, and `infra-database` is a POM-only aggregator with no
`src/`, so no hand-written `SpringLiquibase` bean exists either.

**The real schema authority is Hibernate `ddl-auto`.** The lab runs it through a
single-instance Job (D6) rather than letting three replicas issue concurrent DDL.

### The upgrade hazard, which is the part that matters

Adding `spring-boot-liquibase` — a one-line change someone will eventually make
while "fixing the Liquibase setup" — **silently activates two never-executed
changelogs against a schema Hibernate has been authoring since the project
began.** And it would still not find `order-service`'s changelog, which sits at
a non-default path with nothing pointing at it.

Do not add that dependency casually. Adopting Liquibase is real work with real
value; it is a project of its own.

---

## 3. The actuator health-group endpoints are unreachable

Measured on the running cluster:

```
GET /actuator/health             -> 200
GET /actuator/health/readiness   -> 401
GET /actuator/health/liveness    -> 401
```

`SecurityCommons.authRules()` permits the **exact** path `/actuator/health` and
falls through to `.anyRequest().authenticated()`. The kubelet received 401 on the
liveness probe and killed every pod (`exit 143`).

Moving actuator to its own `management.server.port` does **not** help — the
parent context's `SecurityFilterChain` still applies. Tried and measured.

**Consequence for FR-063**: the probes use `/actuator/health` for startup and
readiness, and a **TCP** check for liveness. Readiness and liveness remain
genuinely distinct, which is the property that matters. The cost: a TCP liveness
probe cannot detect a JVM that is alive but deadlocked.

**The fix, for whoever owns that code:**

```java
.requestMatchers("/actuator/health/**").permitAll()
```

One line in `SecurityCommons`. FR-044 put it outside this feature.

### The same cause reaches further than the probes: FR-064

The readiness toggle has the same problem, and it was found by running the drill
rather than by reading. With `readinessToggle.enabled=true` and the endpoint
exposed:

```
POST /actuator/serviceregistry?status=OUT_OF_SERVICE  ->  401
```

**`readinessToggle.enabled=true` exposes the endpoint; it does not authorise
it.** The value gate and the security chain are two independent doors, and only
one of them is under this feature's control.

So the readiness drill reports **BLOCKED** when the toggle is on: the mechanism
was never exercised, so nothing was established about readiness in either
direction. With the toggle off — the shipped default — it reports
`SKIPPED-BY-CONFIGURATION`, which is unchanged and correct.

A wider matcher (`/actuator/**`) would cover both this and the health groups, and
it is a wider claim than the health-group fix, so it deserves its own thought
about what else lives under `/actuator` — `metrics` is exposed here, `env` and
`configprops` deliberately are not.

---

## 3a. The login limiter has two independently phased dimensions

Not a gap so much as a property that is easy to get wrong, and did get wrong
here. `auth-service` limits login on **two** dimensions:

```
login-ip        capacity 5 / PT1M   keyed by address
login-username  capacity 5 / PT1M   keyed by username
```

Both are Bucket4j `refillIntervally` buckets, so capacity returns as a **lump**
at a boundary rather than gradually. The two buckets are keyed differently and
created at different moments, so they refill on **independently phased**
boundaries — measured: draining `labuser` to 429 left the address bucket with two
tokens still available to a different username from the same address.

**The consequence for anything that signs in more than once:** usable headroom is
`min(ip_remaining, username_remaining)`, and **no single probe can measure it**. A
sign-in returning 200 says one token existed on both dimensions. It says nothing
about the next one. Waiting out a 429's `Retry-After` synchronises with one
boundary and not the other — measured at 3 usable sign-ins, not 5.

The only client-side way to reach a known state is to drive every dimension to
empty and then observe the refill; `scripts/lib/ratelimit.sh` does exactly that,
and carries the measurements.

---

## 4. `*.localhost` wildcard certificates are rejected

Measured, with a control:

| SAN | Requested host | Result |
|---|---|---|
| `*.localhost` | `acme.localhost` | **REJECTED** (curl exit 60) |
| `*.lab.localhost` | `acme.lab.localhost` | accepted (HTTP 200) |

A TLS client will not match a wildcard against a **single-label parent**;
`localhost` is a public suffix. So the lab's certificate enumerates tenant
hostnames in its SAN.

**FR-040 / SC-007 hold for routing** — a new tenant needs no Gateway, no
HTTPRoute, no listener, and `tests/integration/new-tenant.sh` asserts exactly
that. They do **not** hold for TLS on this base domain.

This is a property of `.localhost`, **not** of Kubernetes-as-edge. With a real
base domain (`*.hydra.example.com`) the wildcard matches and the property is
whole. A two-label lab domain was rejected because `EdgeConformanceFixture` fixes
`acme.localhost` and `beta.localhost` as constants, and changing them would mean
editing Hydra's existing suite — which SC-020 forbids.

---

## 5. Gateway ingress needs a Cilium CRD, not a standard NetworkPolicy

Every request through the gateway returned `upstream connect error ... connection
timeout` while routes reported `Accepted` and pods were healthy.

Cilium's Envoy proxies to backends with the `reserved:ingress` identity, **not**
the identity of a kube-system pod. A standard NetworkPolicy cannot name that, so
the traffic fell through to default-deny. The rule is now a
`CiliumNetworkPolicy` with `fromEntities: [ingress]`; every other rule in the
file remains standard.

**This is genuine evidence for the Edge Finding.** A Kubernetes edge whose
NetworkPolicy story requires vendor CRDs to express "let the gateway in" is a
real portability cost, and it is invisible until traffic actually flows.

---

## 6. First-boot bootstrap is deliberately bypassed (FR-052b)

The fixture seeds tenants and users before any traffic, so `auth-service`'s users
table is never empty and first-boot bootstrap never runs. `BootstrapService` is
`@Profile({"local"})` and the lab runs `test`, so it is doubly inactive.

**The concurrent-bootstrap race is therefore neither proven safe nor proven
broken here.** It is out of scope, not resolved.

---

## 7. The services run under a profile named `test`

`SPRING_PROFILES_ACTIVE=test,lab`. That is a **naming accident of this
repository**, not a statement about how seriously the lab takes the deployment.

`test` is the only profile that binds a **file-based** `KeyProvider`
(`LocalKeyProvider` is `@Profile({"local","test"})`) while keeping the real
security chain. `local` swaps in a permissive chain, enables the H2 console and
activates bootstrapping. `prod`/`staging` bind `CloudKeyProvider` to AWS Secrets
Manager. Inventing a `k8s` profile would leave **no `KeyProvider` bean at all**
and fail at context startup (research.md A4).

`lab` exists only so the mounted `application-lab.yml` is loaded — a
profile-specific file is ignored unless its profile is active, and the first
version of this shipped without it, so Spring silently ignored the entire
ConfigMap. No bean is bound to `lab`.

---

## 8. Argo CD reconciles a delivery slice, not the umbrella chart

The `hydra-lab` release is installed by the Helm CLI; Argo CD owns
`gitops/delivery-canary.yaml`. Two controllers owning the same objects produces
ownership conflicts — this lab already hit the Helm form of it
(`invalid ownership metadata`) — and Argo's `selfHeal` would actively revert
whatever the CLI did.

**Demonstrated**: reconciliation, drift detection, self-healing, convergence
without a deploy command, on a real workload through a real controller.

**Not demonstrated**: Argo CD managing Hydra's services. Production would put
the chart in git and delete the Helm CLI path.

---

## 9. `-Djava.security.egd` is not inert, and its choice is unowned

The flag changes the selected `SecureRandom` from `NativePRNG` to `DRBG`
(measured; see [jvm-flags.md](jvm-flags.md)). It is **retained** because removing
it would change the cryptographic primitive a credential-issuing service seeds
with, as a side effect of tidying a Dockerfile.

Which of the two is right for these services is a real question with a real
answer, and **it is not this feature's question**. What the lab established is
only that the choice is currently being made by a flag most people believe does
nothing.

---

## 10. kubectl is three minors behind the API server

`versions.env` pins `KUBECTL_VERSION=v1.33.9` against a `v1.36.1` API server —
outside kubectl's supported ±1 minor skew window. It works for everything the lab
does; it is recorded rather than smoothed over, and `make doctor` compares
against the matrix so a client drifting further is visible.

---

## 11. Storage, secrets and exposure are lab-shaped

| | Lab | Production |
|---|---|---|
| Storage | kind hostPath — no replication, no snapshots, gone with the node | Network-attached volumes |
| Secrets | Kubernetes Secrets, base64 in etcd, created by a shell script | Managed secret store, rotation, audit |
| Registry | Plain HTTP, no auth, loopback-bound | TLS, IAM-scoped pulls, signing, scanning |
| Consoles | Port-forward, anonymous access | SSO, RBAC, audit logging |
| Headlamp | **cluster-admin** service account | Per-user SSO with scoped RBAC |

See [production-mapping.md](production-mapping.md).

---

## 12. What no lab on one machine can establish

- Real cloud load-balancer behaviour
- Real node failure (see the node-stop drill's own caveats)
- Multi-zone or multi-region anything
- Managed control-plane upgrade behaviour
- Real certificate issuance and rotation
- Production traffic shape, volume or adversaries

The benchmark states these again in its own Limitations section, because that is
where someone is most likely to over-read a number.
