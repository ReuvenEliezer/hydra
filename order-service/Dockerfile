# ---------------------------------------------------------------------------
# order-service — multi-stage build.
#
# Mirrors auth-service/Dockerfile, and resolves the same two blockers recorded
# as research findings A1 and A2 (specs/005-k8s-production-lab/research.md):
#
#   A1  `COPY mvnw .` / `COPY .mvn .mvn` referenced a Maven wrapper that does
#       not exist in this repository and never has. Replaced by a pinned Maven
#       toolchain image, which also means the host's Java version is irrelevant
#       to the image build.
#
#   A2  `browser-edge-starter` — a declared dependency, annotated in this
#       service's own pom.xml with a comment pointing at
#       BrowserEdgeAutoConfiguration — was in neither the POM-copy nor the
#       source-copy layer. It is what emits Hydra's cross-origin headers.
#
# One further correction: the previous version copied `infra-shared` and
# `infra-database` but not `rate-limit-starter`, while the POM layer copied all
# three. A reactor build with `-am` needs the sources of every module it
# resolves, so that asymmetry was a second reason the build could not succeed.
# ---------------------------------------------------------------------------

ARG MAVEN_BUILDER_IMAGE=maven:3.9.11-eclipse-temurin-25
ARG JAVA_RUNTIME_IMAGE=eclipse-temurin:25-jre-alpine

# =========================== builder =======================================
FROM ${MAVEN_BUILDER_IMAGE} AS builder
WORKDIR /workspace

# FR-004: the build states which toolchain performed it.
RUN mvn -version

COPY pom.xml .
COPY infra-shared/pom.xml           infra-shared/pom.xml
COPY infra-database/pom.xml         infra-database/pom.xml
COPY rate-limit-starter/pom.xml     rate-limit-starter/pom.xml
COPY browser-edge-starter/pom.xml   browser-edge-starter/pom.xml
COPY auth-service/pom.xml           auth-service/pom.xml
COPY order-service/pom.xml          order-service/pom.xml
COPY integration-tests/pom.xml      integration-tests/pom.xml

RUN mvn -B -q dependency:go-offline -pl order-service -am -DskipTests || true

COPY infra-shared         infra-shared
COPY infra-database       infra-database
COPY rate-limit-starter   rate-limit-starter
COPY browser-edge-starter browser-edge-starter
COPY order-service        order-service

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
# and the missing browser-edge-starter (A2).
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
RUN mvn -B package spring-boot:repackage -pl order-service -DskipTests

# The repackaged archive must actually be executable. `docker build` succeeding
# proves the layers assembled, not that the jar has a main class — which is
# exactly the failure above, and it is silent until a pod crash-loops.
# The check uses the JDK's own `jar` tool, not `unzip`: the Maven image has no
# unzip, and the first version of this guard failed for that reason while the
# repackage had actually succeeded — a guard that fails for its own reasons is
# worse than no guard, because the next person disables it.
RUN set -eu; \
    jarfile="$(ls /workspace/order-service/target/*.jar | head -1)"; \
    mkdir -p /tmp/manifest-check; cd /tmp/manifest-check; \
    jar --extract --file "$jarfile" META-INF/MANIFEST.MF; \
    if grep -q '^Main-Class:' META-INF/MANIFEST.MF; then \
      echo "OK: $(grep '^Main-Class:' META-INF/MANIFEST.MF)"; \
      echo "OK: $(grep '^Start-Class:' META-INF/MANIFEST.MF)"; \
    else \
      echo "FATAL: order-service jar has no Main-Class — spring-boot:repackage did not run"; \
      exit 1; \
    fi

ARG OTEL_JAVA_AGENT_URL=https://github.com/open-telemetry/opentelemetry-java-instrumentation/releases/download/v2.20.0/opentelemetry-javaagent.jar
RUN mkdir -p /opt/otel \
 && curl -fsSL -o /opt/otel/opentelemetry-javaagent.jar "${OTEL_JAVA_AGENT_URL}" \
 && test -s /opt/otel/opentelemetry-javaagent.jar

# =========================== runtime =======================================
FROM ${JAVA_RUNTIME_IMAGE}

# Same explicit uid/gid as auth-service, for the same reason: the pod spec's
# runAsUser must match the image, and an implicitly assigned id does not
# survive a base-image bump (FR-057).
RUN addgroup -g 10001 -S hydra \
 && adduser  -u 10001 -S hydra -G hydra -h /app -s /sbin/nologin

WORKDIR /app

COPY --from=builder --chown=10001:10001 /workspace/order-service/target/*.jar app.jar
COPY --from=builder --chown=10001:10001 /opt/otel/opentelemetry-javaagent.jar /opt/otel/opentelemetry-javaagent.jar

USER 10001:10001
EXPOSE 8082

# Exec form so the JVM receives SIGTERM directly (FR-058).
# ZGenerational removed as provably inert; java.security.egd retained because it
# is not — both measured, in k8s-lab/docs/jvm-flags.md.
ENTRYPOINT ["java", \
  "-XX:+UseZGC", \
  "-Djava.security.egd=file:/dev/./urandom", \
  "-jar", "app.jar"]
