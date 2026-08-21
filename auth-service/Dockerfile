# ---------------------------------------------------------------------------
# auth-service — multi-stage build.
#
# Two blockers had to be resolved before this file could build at all from a
# clean checkout (recorded as research findings A1 and A2 in
# specs/005-k8s-production-lab/research.md):
#
#   A1  The builder stage began `COPY mvnw .` / `COPY .mvn .mvn`. Neither the
#       wrapper script nor the .mvn directory exists in this repository, and
#       neither ever did — `git ls-files` has no record of them. Any clean-state
#       build failed on the first COPY, before a line of Java was compiled.
#       Resolved by building on a PINNED Maven toolchain image instead of
#       committing wrapper binaries the repository has deliberately never
#       carried. The toolchain is declared in k8s-lab/versions.env and printed
#       by the build, so "which toolchain produced this image" is answered by
#       output rather than by assumption (FR-004).
#
#   A2  `browser-edge-starter` is a declared dependency of this service and was
#       absent from both the POM-copy and the source-copy layers. The reactor
#       build inside the image could not resolve it. That module is what emits
#       Hydra's cross-origin headers, so an image built without it would violate
#       the transparent edge contract *from the inside* — Clause 2 would fail
#       for a reason having nothing to do with any gateway.
#
# The version literals below are the one place in the lab where a version is
# written outside versions.env, because a Dockerfile cannot read an env file at
# build time. `k8s-lab/scripts/images.sh` passes them as build arguments from
# the matrix, and the defaults here exist only so a bare `docker build` works;
# `make verify-versions` treats ARG defaults as declarations, not drift.
# ---------------------------------------------------------------------------

ARG MAVEN_BUILDER_IMAGE=maven:3.9.11-eclipse-temurin-25
ARG JAVA_RUNTIME_IMAGE=eclipse-temurin:25-jre-alpine

# =========================== builder =======================================
FROM ${MAVEN_BUILDER_IMAGE} AS builder
WORKDIR /workspace

# FR-004: the build states which toolchain performed it, as its first act.
RUN mvn -version

# --- POM layer (cached independently of sources) --------------------------
COPY pom.xml .
COPY infra-shared/pom.xml           infra-shared/pom.xml
COPY infra-database/pom.xml         infra-database/pom.xml
COPY rate-limit-starter/pom.xml     rate-limit-starter/pom.xml
COPY browser-edge-starter/pom.xml   browser-edge-starter/pom.xml
COPY auth-service/pom.xml           auth-service/pom.xml
COPY order-service/pom.xml          order-service/pom.xml
COPY integration-tests/pom.xml      integration-tests/pom.xml

# Dependency resolution as its own layer, so a source-only change does not
# re-download the world.
RUN mvn -B -q dependency:go-offline -pl auth-service -am -DskipTests || true

# --- source layer ---------------------------------------------------------
# Whole module trees, never individual files. Resource layout is load-bearing
# here: auth-service loads its Redis rotation scripts by CLASSPATH PATH
# (lua/<name>.lua), so flattening or relocating resources would break a load
# site that no compiler checks. Constitution Principle III; the integration
# suite executes that load site against this image so a broken layout fails a
# test rather than lurking.
COPY infra-shared         infra-shared
COPY infra-database       infra-database
COPY rate-limit-starter   rate-limit-starter
COPY browser-edge-starter browser-edge-starter
COPY auth-service         auth-service

# THREE steps, not one, and the reason is a build defect this feature found
# (recorded as research finding A8; see k8s-lab/docs/images.md).
#
# `spring-boot-maven-plugin` is declared in the root pom's <pluginManagement>
# with a version and NO <executions> block, and this repository does not use
# `spring-boot-starter-parent`. Without that parent, nothing binds the
# plugin's `repackage` goal to the package phase — so `mvn package` produces a
# PLAIN jar with no BOOT-INF, no Main-Class and no Start-Class, and
# `java -jar app.jar` fails with "no main manifest attribute".
#
# That is a pre-existing condition, not one introduced here: it means these
# images could never have run, independently of the missing Maven wrapper (A1)
# and the missing browser-edge-starter (A2). The service has only ever been
# started from an IDE or `mvn spring-boot:run`, both of which build a classpath
# rather than an executable archive.
#
# The fix is applied HERE rather than in the poms, because the plan's structure
# decision confines this feature's blast radius outside k8s-lab/ to these two
# Dockerfiles. Binding the execution in the poms is the better long-term fix
# and is recorded as such in k8s-lab/docs/known-gaps.md.
#
# Why three invocations: `spring-boot:repackage` must run in the SAME lifecycle
# as `package` ("Source file is not available" otherwise), and a `-pl <svc>
# -am` reactor would apply the goal to the library modules too, which have no
# main class. So the siblings are installed to the local repository first, and
# the service is then packaged and repackaged alone.
RUN mvn -B install -N -DskipTests
RUN mvn -B install -pl infra-shared,infra-database,rate-limit-starter,browser-edge-starter -DskipTests
RUN mvn -B package spring-boot:repackage -pl auth-service -DskipTests

# The repackaged archive must actually be executable. `docker build` succeeding
# proves the layers assembled, not that the jar has a main class — which is
# exactly the failure above, and it is silent until a pod crash-loops.
# The check uses the JDK's own `jar` tool, not `unzip`: the Maven image has no
# unzip, and the first version of this guard failed for that reason while the
# repackage had actually succeeded — a guard that fails for its own reasons is
# worse than no guard, because the next person disables it.
RUN set -eu; \
    jarfile="$(ls /workspace/auth-service/target/*.jar | head -1)"; \
    mkdir -p /tmp/manifest-check; cd /tmp/manifest-check; \
    jar --extract --file "$jarfile" META-INF/MANIFEST.MF; \
    if grep -q '^Main-Class:' META-INF/MANIFEST.MF; then \
      echo "OK: $(grep '^Main-Class:' META-INF/MANIFEST.MF)"; \
      echo "OK: $(grep '^Start-Class:' META-INF/MANIFEST.MF)"; \
    else \
      echo "FATAL: auth-service jar has no Main-Class — spring-boot:repackage did not run"; \
      exit 1; \
    fi

# The OpenTelemetry agent is fetched in the builder, not the runtime stage, so
# the runtime image keeps no download tooling (D10, FR-057).
ARG OTEL_JAVA_AGENT_URL=https://github.com/open-telemetry/opentelemetry-java-instrumentation/releases/download/v2.20.0/opentelemetry-javaagent.jar
RUN mkdir -p /opt/otel \
 && curl -fsSL -o /opt/otel/opentelemetry-javaagent.jar "${OTEL_JAVA_AGENT_URL}" \
 && test -s /opt/otel/opentelemetry-javaagent.jar

# =========================== runtime =======================================
FROM ${JAVA_RUNTIME_IMAGE}

# FR-057: a dedicated non-root identity with EXPLICIT numeric ids. Explicit,
# because the pod spec's runAsUser/runAsGroup must match the image, and
# `adduser -S` picks whatever id happens to be free — which differs between
# base image versions and produces a permission failure that names nothing.
RUN addgroup -g 10001 -S hydra \
 && adduser  -u 10001 -S hydra -G hydra -h /app -s /sbin/nologin

WORKDIR /app

COPY --from=builder --chown=10001:10001 /workspace/auth-service/target/*.jar app.jar

# Baked in, and INERT. No JAVA_TOOL_OPTIONS is set in this image: the agent
# does nothing unless the chart supplies -javaagent at deploy time (D10). That
# is what keeps the image usable outside the lab.
COPY --from=builder --chown=10001:10001 /opt/otel/opentelemetry-javaagent.jar /opt/otel/opentelemetry-javaagent.jar

USER 10001:10001
EXPOSE 8083

# Exec form, deliberately. Shell form would put /bin/sh at PID 1 and the JVM
# beneath it, so SIGTERM would reach the shell and never the JVM — graceful
# shutdown would silently become a 30-second kill on every rollout (FR-058).
#
# -XX:+ZGenerational was removed: on Java 25 the JVM warns "Ignoring option
# ZGenerational; support was removed in 24.0" and starts anyway, so it was
# provably inert (FR-059). Measured, not assumed — see k8s-lab/docs/jvm-flags.md.
#
# -Djava.security.egd is RETAINED. It is not inert: it changes the selected
# SecureRandom implementation from NativePRNG to DRBG. Removing it would change
# the cryptographic primitive a credential-issuing service seeds with, as a side
# effect of tidying a Dockerfile. Same document, with the measurements.
ENTRYPOINT ["java", \
  "-XX:+UseZGC", \
  "-Djava.security.egd=file:/dev/./urandom", \
  "-jar", "app.jar"]
