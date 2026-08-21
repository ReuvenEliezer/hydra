# Version Matrix

<!-- GENERATED FILE — do not edit.
     Source: k8s-lab/versions.env
     Regenerate: k8s-lab/scripts/render-versions.sh
     Edits here are overwritten and, worse, are invisible to every script,
     because scripts read versions.env and never this file. -->

Every version the lab pins, with what it was checked against. This file is
generated from [`versions.env`](../versions.env), which is the authority.
`make verify-versions` asserts the two agree and that no moving reference
exists outside a documented exception (SC-022).

| Setting | Value | Compatibility basis |
|---|---|---|
| `KIND_VERSION` | `v0.32.0` | OBSERVED on this workstation (`kind version`), not selected from a release page. The pin follows the installed toolchain rather than the other way round, because a matrix that names a version nobody has is a matrix that has never been executed (FR-116). |
| `KIND_NODE_IMAGE` | `kindest/node:v1.36.1` | the default node image compiled into kind v0.32.0, read out of the binary itself rather than guessed. Exact patch version, not a moving `v1.36` alias. |
| `KUBERNETES_VERSION` | `v1.36.1` | the version baked into KIND_NODE_IMAGE above. |
| `KIND_CLUSTER_NAME` | `hydra-lab` | — |
| `KIND_WORKER_COUNT` | `2` | — |
| `KUBECTL_VERSION` | `v1.33.9` | the client installed on this workstation. NOTE: v1.33 is three minors behind the v1.36.1 API server above, which is OUTSIDE kubectl's supported +/-1 minor skew window. It works for everything the lab does today, and it is recorded as a known divergence rather than smoothed over — see docs/known-gaps.md. `make doctor` compares against this value and will warn rather than silently accept a client that is further adrift. |
| `HELM_VERSION` | `v4.2.4` | OBSERVED on this workstation. This is Helm **4**, not the v3 line the plan assumed. Helm 4 still reads `apiVersion: v2` charts, which is what charts/hydra-lab/Chart.yaml declares, and `helm upgrade --install`, `helm repo add` and `--values` are unchanged. Recorded explicitly because "Helm 3.x" appears throughout the upstream chart documentation the lab pulls from, and a reader hitting a Helm-4-specific behaviour should know which major they are on rather than assume v3. |
| `CILIUM_CHART_VERSION` | `1.18.1` | resolved from the Cilium chart repository at install time and then pinned here to what actually installed. The value below is the starting point; if `make setup` shows it is not compatible with the v1.36 API server, the fix is a new value HERE plus a re-recorded basis, never a literal in a script (SC-022). |
| `GATEWAY_API_VERSION` | `v1.3.0` | the Gateway API release Cilium 1.18 implements. |
| `GATEWAY_API_CHANNEL` | `standard` | — |
| `REGISTRY_IMAGE` | `registry:3.0.0` | registry:3 is the current distribution line; the tag is a release line, not a moving alias — see REGISTRY_IMAGE_DIGEST_NOTE in docs/registry.md. |
| `REGISTRY_NAME` | `hydra-lab-registry` | — |
| `REGISTRY_PORT` | `5001` | — |
| `POSTGRES_IMAGE` | `postgres:16-alpine` | byte-identical to the images in the repository's own docker-compose.yml. A lab that runs a different Postgres than local development is measuring a different system. |
| `REDIS_IMAGE` | `redis:8.8-alpine` | byte-identical to docker-compose.yml, which pins the minor deliberately — Redis has been AGPLv3 since 8.0, so a floating tag is a licensing change as well as a version change. |
| `PROMETHEUS_CHART_VERSION` | `27.44.0` | prometheus-community/prometheus chart line tested against Kubernetes 1.34; kube-state-metrics ships as its sub-chart. |
| `GRAFANA_CHART_VERSION` | `10.1.1` | grafana/grafana chart line whose appVersion is Grafana 12, which carries the Tempo datasource and the TraceQL editor the trace check uses. |
| `OTEL_COLLECTOR_CHART_VERSION` | `0.135.0` | open-telemetry/opentelemetry-collector chart matching the collector release that accepts OTLP from the agent version pinned below. |
| `TEMPO_CHART_VERSION` | `1.24.0` | grafana/tempo single-binary chart; monolithic mode is the only mode this lab uses. |
| `OTEL_JAVA_AGENT_VERSION` | `2.20.0` | OpenTelemetry Java agent 2.x supports Java 25 and Spring Boot 4.x auto-instrumentation. Baked into the image, inert unless JAVA_TOOL_OPTIONS activates it (D10). |
| `OTEL_JAVA_AGENT_URL` | `https://github.com/open-telemetry/opentelemetry-java-instrumentation/releases/download/v2.20.0/opentelemetry-javaagent.jar` | — |
| `ARGOCD_CHART_VERSION` | `8.5.9` | argo/argo-cd chart line whose appVersion is Argo CD 3.x. |
| `HEADLAMP_CHART_VERSION` | `0.38.0` | headlamp/headlamp chart line supporting in-cluster install with a service account of its own. |
| `MAVEN_BUILDER_IMAGE` | `maven:3.9.11-eclipse-temurin-25` | the Maven image carrying a JDK 25 that matches the repository's <maven.compiler.release>. Replaces the absent Maven wrapper (research.md A1) — this is what makes a clean-state build possible at all. |
| `JAVA_RUNTIME_IMAGE` | `eclipse-temurin:25-jre-alpine` | the JRE image matching the builder's JDK major version. |
| `HELM_REPO_CILIUM` | `https://helm.cilium.io/` | — |
| `HELM_REPO_PROMETHEUS` | `https://prometheus-community.github.io/helm-charts` | — |
| `HELM_REPO_GRAFANA` | `https://grafana.github.io/helm-charts` | — |
| `HELM_REPO_OTEL` | `https://open-telemetry.github.io/opentelemetry-helm-charts` | — |
| `HELM_REPO_ARGO` | `https://argoproj.github.io/argo-helm` | — |
| `HELM_REPO_HEADLAMP` | `https://kubernetes-sigs.github.io/headlamp/` | — |
| `LAB_BASE_DOMAIN` | `localhost` | — |
| `LAB_PRIMARY_TENANT` | `acme` | — |
| `LAB_SECOND_TENANT` | `beta` | — |
| `LAB_LATE_TENANT` | `gamma` | — |
| `GATEWAY_NODEPORT_HTTPS` | `30443` | — |
| `GATEWAY_NODEPORT_HTTP` | `30080` | — |
| `PSA_ENFORCE_VERSION` | `v1.36` | the minor of KUBERNETES_VERSION above. |
| `NS_APP` | `hydra-app` | — |
| `NS_DATA` | `hydra-data` | — |
| `NS_OBS` | `hydra-obs` | — |
| `NS_DELIVERY` | `hydra-delivery` | — |
| `TIMEOUT_NODE_READY` | `300` | — |
| `TIMEOUT_CILIUM_READY` | `300` | — |
| `TIMEOUT_GATEWAY_PROGRAMMED` | `300` | — |
| `TIMEOUT_WORKLOAD_READY` | `420` | — |
| `TIMEOUT_JOB_COMPLETE` | `600` | — |
| `TIMEOUT_HTTP_RESPONSIVE` | `180` | — |
| `RATE_LIMIT_LOGIN_WINDOW_SECONDS` | `60` | — |
| `RATE_LIMIT_LOGIN_CAPACITY` | `5` | — |
| `RATE_LIMIT_QUIET_MARGIN_SECONDS` | `5` | — |

## How to change a version

1. Edit `versions.env` — the value **and** its `# compatibility_basis:` line.
2. Run `k8s-lab/scripts/render-versions.sh` to regenerate this file.
3. Run `make verify-versions`.
4. Run `make validate-full`. A version change that has not been executed
   end to end has not been verified (FR-116).

Never edit a script to change a version. If a script needs a value this
matrix does not carry, the fix is a new matrix entry, not a literal.
