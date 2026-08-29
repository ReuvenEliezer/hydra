# Image lifecycle: from source to running pod

Every step an image takes, and what can go wrong at each. FR-021 asks for this
documented end to end.

```text
  repository working tree
        │
        │ ① revision-derived tag
        ▼
  docker build (builder stage: pinned Maven toolchain image)
        │  ├─ mvn -version                     ← FR-004: which toolchain built this
        │  ├─ POM layer            (cached separately from sources)
        │  ├─ source layer         (whole module trees, layout preserved)
        │  ├─ install siblings -> local repo
        │  ├─ package + spring-boot:repackage  ← A8, see below
        │  ├─ Main-Class guard                 ← fails the build if repackage did not run
        │  └─ fetch the OTel agent
        ▼
  docker build (runtime stage: pinned JRE image)
        │  ├─ uid/gid 10001 created explicitly ← FR-057
        │  ├─ app.jar + the agent, chowned
        │  └─ exec-form ENTRYPOINT             ← FR-058, so the JVM gets SIGTERM
        ▼
  local image: localhost:5001/hydra/<service>:<sha>
        │
        │ ② docker push
        ▼
  lab registry
        │
        │ ③ containerd mirror (see registry.md)
        ▼
  kubelet pulls
        ▼
  running pod
```

## ① The tag

```
localhost:5001/hydra/auth-service:8f3c1d2
localhost:5001/hydra/auth-service:8f3c1d2-dirty
```

Derived from `git rev-parse --short HEAD`, never `latest`, never re-pushed
(FR-017). `make image-publish` refuses to overwrite an existing tag unless
`ALLOW_TAG_OVERWRITE=1`, because a re-pushed tag destroys the only link between
a running pod and the code inside it.

`-dirty` means `git status --porcelain` was non-empty — including untracked
files, which is deliberate: a new source file that has not been committed is
exactly the case where the image cannot be rebuilt from its recorded revision.
`make image-publish` refuses a `-dirty` tag without `ALLOW_DIRTY_PUBLISH=1`.

## ② The build, and the three things that had to be fixed

A container build of this repository was **impossible** before this feature, for
three independent reasons. Two were found by the Phase 0 audit; the third was
found by building.

### A1 — the Maven wrapper does not exist

Both Dockerfiles began:

```dockerfile
COPY mvnw .
COPY .mvn .mvn
```

Neither file has ever existed in this repository — `git ls-files` has no record
of them. Every clean-state build failed on the first `COPY`.

**Fixed** by building on a pinned Maven toolchain image
(`MAVEN_BUILDER_IMAGE` in `versions.env`) instead of committing wrapper
binaries. A side benefit: the host's Java version becomes irrelevant to the
image build, so a workstation with Java 21 still produces a correct Java 25
image. The host's Java still matters for `make test-edge-conformance`, which is
why `make doctor` still checks it.

### A2 — `browser-edge-starter` was not in the build

Both services declare a dependency on it; neither Dockerfile copied its POM or
its sources. The reactor build inside the image could not resolve it.

This one is worse than a build failure would suggest. `browser-edge-starter` is
what emits Hydra's cross-origin headers — so an image that somehow built without
it would violate the transparent edge contract **from the inside**: the services
would emit no CORS headers at all, and Clause 2 of the conformance suite would
fail for a reason having nothing to do with any gateway.

**Fixed** by adding it to both the POM-copy and source-copy layers.
`order-service` had a second asymmetry of the same kind: its POM layer copied
`rate-limit-starter` while its source layer did not.

### A8 — `spring-boot:repackage` never ran

**Found during implementation, not in the audit**, because it is invisible in
the source and only appears when you build the artifact and look inside it.

`spring-boot-maven-plugin` is declared in the root pom's `<pluginManagement>`
with a version and **no `<executions>` block**, and this project does not use
`spring-boot-starter-parent`. Without that parent, nothing binds the `repackage`
goal to the `package` phase. `mvn package` therefore produced:

```
META-INF/MANIFEST.MF     Manifest-Version, Created-By, Build-Jdk-Spec — and nothing else
com/reuven/auth/...      classes
lua/                     resources
                         no BOOT-INF, no Main-Class, no Start-Class
```

A plain jar. `java -jar app.jar` fails with `no main manifest attribute in
app.jar`. So even with A1 and A2 fixed, every container would have crash-looped
at start.

The services have only ever been run from an IDE or `mvn spring-boot:run`, both
of which construct a classpath rather than an executable archive — which is why
this survived unnoticed.

**Fixed in the Dockerfiles**, not in the poms, because this feature's blast
radius outside `k8s-lab/` is deliberately those two files (plan.md, Structure
Decision). The build now runs:

```dockerfile
RUN mvn -B install -N -DskipTests
RUN mvn -B install -pl infra-shared,infra-database,rate-limit-starter,browser-edge-starter -DskipTests
RUN mvn -B package spring-boot:repackage -pl <service> -DskipTests
```

Three invocations rather than one, because:

- `spring-boot:repackage` must run in the **same lifecycle** as `package`, or it
  fails with `Source file is not available, make sure 'package' runs as part of
  the same lifecycle`.
- A `-pl <service> -am` reactor would apply the goal to the library modules too,
  and they have no main class.

So the siblings go to the local repository first, and the service is then
packaged and repackaged alone.

**The better long-term fix** is to bind the execution in the service poms:

```xml
<plugin>
  <groupId>org.springframework.boot</groupId>
  <artifactId>spring-boot-maven-plugin</artifactId>
  <executions>
    <execution><goals><goal>repackage</goal></goals></execution>
  </executions>
</plugin>
```

That is recorded in [known-gaps.md](known-gaps.md) as work this feature
deliberately did not do.

### The guard

Because A8 was silent, the build now asserts against it:

```dockerfile
RUN ... jar --extract --file "$jarfile" META-INF/MANIFEST.MF; \
    if grep -q '^Main-Class:' META-INF/MANIFEST.MF; then ... else exit 1; fi
```

It uses the JDK's own `jar` tool rather than `unzip`, which the Maven image does
not carry — the first version of this guard failed for that reason while the
repackage had actually succeeded, and a guard that fails for its own reasons is
worse than no guard, because the next person disables it.

## Layer caching, and what it costs

The POM layer is copied and resolved before any source, so a source-only change
does not re-resolve dependencies. The consequence worth knowing: on a cached
build the `mvn -version` layer does not re-run, so the toolchain banner FR-004
asks for is absent from that build's output. `make image-build` says so rather
than printing a previous build's banner as if it were this one, and
`make image-build-clean` always shows it.

## ③ Publishing and pulling

See [registry.md](registry.md) — in particular the four different addresses one
registry has, which is the single most confusing thing about a local registry
and the cause of `ImagePullBackOff` errors that name the wrong component.

## Verifying an image without deploying it

```bash
docker inspect -f '{{.Config.User}}' localhost:5001/hydra/auth-service:<tag>
# 10001:10001

docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' localhost:5001/hydra/auth-service:<tag> | grep JAVA_TOOL_OPTIONS
# nothing — the OTel agent is baked in but inert (D10)

docker run --rm --entrypoint ls localhost:5001/hydra/auth-service:<tag> -l /opt/otel/opentelemetry-javaagent.jar
```

`make image-build` runs all of these as executed checks after every build.

## Production mapping

| Lab | Production |
|---|---|
| Built on the workstation, pushed to a loopback registry | Built in CI from a tagged commit, pushed to a managed registry |
| Tag = git sha, immutability by convention | Tag = git sha, immutability enforced by the registry |
| No signing, no scanning | Signed (cosign/notation), scanned, admission-gated |
| `-dirty` tags possible | Impossible — CI has no dirty tree |
| Agent baked into the image | Same, or injected by an operator at admission |
