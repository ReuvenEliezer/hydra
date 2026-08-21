{{/*
  _helpers.tpl — the ONLY template indirection permitted in this chart (FR-084).

  The rule exists because a chart is read far more often than it is written, and
  every helper is a jump the reader has to make. Four helpers, each earning its
  place by being used in three or more templates:

    hydra-lab.labels        the label set every object carries
    hydra-lab.selector      the subset that is a stable selector
    hydra-lab.image         the fully-qualified image reference
    hydra-lab.appEnv        the environment block both services share

  Anything used once is written inline where it is used, even when that repeats
  a few lines. Chasing a helper to discover a literal is worse than reading the
  literal.
*/}}

{{/* Every object in the chart carries these. */}}
{{- define "hydra-lab.labels" -}}
app.kubernetes.io/part-of: hydra-lab
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end }}

{{/*
  Selector labels for a workload. Call as:
      {{- include "hydra-lab.selector" (dict "name" "auth-service") | nindent 6 }}

  Deliberately does NOT include the chart version or the image tag: a selector
  that changes when the version changes orphans every existing pod, and Kubernetes
  will not let you fix it in place because selectors are immutable.
*/}}
{{- define "hydra-lab.selector" -}}
app.kubernetes.io/name: {{ .name }}
app.kubernetes.io/component: {{ .component | default "service" }}
{{- end }}

{{/*
  The image reference. Call as:
      {{ include "hydra-lab.image" (dict "svc" .Values.auth "root" $) }}

  The tag is required and has no default. A chart that defaults to `latest` when
  the tag is missing turns FR-017's immutability requirement into a suggestion,
  and the resulting pod is un-diagnosable: nothing records which build it ran.
*/}}
{{- define "hydra-lab.image" -}}
{{- $registry := .root.Values.global.imageRegistry -}}
{{- $tag := required "image tag is required and must be revision-derived (FR-017) — pass --set global.imageTag=<sha>" .root.Values.global.imageTag -}}
{{- if regexMatch "^(latest|stable|main|master)$" $tag -}}
{{- fail (printf "refusing image tag %q: tags must be revision-derived and immutable (FR-017)" $tag) -}}
{{- end -}}
{{- printf "%s/%s:%s" $registry .svc.imageName $tag -}}
{{- end }}

{{/*
  Environment shared by both services. Call as:
      {{- include "hydra-lab.appEnv" (dict "svc" .Values.auth "root" $ "name" "auth-service") | nindent 12 }}
*/}}
{{- define "hydra-lab.appEnv" -}}
{{/*
  D5: the services run under the `test` profile. Not a statement about how
  seriously the lab takes them — it is the only profile in this repository that
  binds a FILE-based KeyProvider (LocalKeyProvider is @Profile({"local","test"}))
  while keeping the real security chain. `local` swaps in a permissive chain,
  enables the H2 console and activates first-boot bootstrapping; `prod`/`staging`
  bind CloudKeyProvider to AWS Secrets Manager. Inventing a `k8s` profile would
  leave NO KeyProvider bean at all and fail at context startup (research.md A4).
  docs/known-gaps.md says this out loud so no reader concludes the lab runs
  something other than the real configuration.
*/}}
- name: SPRING_PROFILES_ACTIVE
  # TWO profiles, and the second one is load-bearing.
  #
  # `test` is the profile the services must run under: it is the only one in
  # this repository that binds a FILE-based KeyProvider (LocalKeyProvider is
  # @Profile({"local","test"})) while keeping the real security chain.
  #
  # `lab` exists purely so the mounted configuration is LOADED. A file named
  # application-lab.yml is only read when the `lab` profile is active — the
  # first version of this shipped the ConfigMap without it, and Spring ignored
  # the file completely. Nothing detected that until the probes started
  # returning 401 and the pods crash-looped, because a configuration file that
  # is silently not loaded produces no error at all.
  #
  # Profile ORDER matters too: later-listed profiles win, so application-lab.yml
  # from /config/ overrides the literals in the packaged application-test.yml.
  # That is what makes refresh-token.cookie.secure=true and ddl-auto=validate
  # actually take effect (D5) — an environment variable cannot reach them,
  # because application-test.yml sets them as literals rather than as
  # ${ENV:default} placeholders.
  #
  # No bean anywhere is bound to a `lab` profile, so adding it changes nothing
  # about which components are active. research.md A4's constraint is intact.
  value: "test,lab"
{{/*
  The mounted ConfigMap. Environment variables and this location together supply
  every lab-specific setting, so no application-*.yml is added to either
  service's resources (FR-044).
*/}}
- name: SPRING_CONFIG_ADDITIONAL_LOCATION
  # `optional:` matters. Spring treats a non-existent config location as a
  # startup failure by default, and the migration Job deliberately does not
  # mount /config — see job-migrate.yaml. Without the prefix, the Job dies on a
  # missing directory rather than doing its job.
  value: "optional:file:/config/"
- name: TENANT_BASE_DOMAINS
  value: {{ .root.Values.global.baseDomain | quote }}
- name: SPRING_DATASOURCE_URL
  value: "jdbc:postgresql://postgres.{{ .root.Values.global.dataNamespace }}.svc.cluster.local:5432/{{ .svc.database }}"
- name: SPRING_DATASOURCE_USERNAME
  valueFrom:
    secretKeyRef: {name: {{ .root.Values.secrets.postgres }}, key: username}
- name: SPRING_DATASOURCE_PASSWORD
  valueFrom:
    secretKeyRef: {name: {{ .root.Values.secrets.postgres }}, key: password}
- name: SPRING_DATA_REDIS_HOST
  value: "redis.{{ .root.Values.global.dataNamespace }}.svc.cluster.local"
- name: SPRING_DATA_REDIS_PORT
  value: "6379"
- name: SPRING_DATA_REDIS_PASSWORD
  valueFrom:
    secretKeyRef: {name: {{ .root.Values.secrets.redis }}, key: password}
{{/*
  FR-049: the concurrency model is a configuration value, and the active mode is
  observable at runtime — tests/perf/bench.sh reads it back from the running pod
  rather than trusting what it set.
*/}}
- name: SPRING_THREADS_VIRTUAL_ENABLED
  value: {{ .root.Values.concurrency.virtualThreads | quote }}
{{/*
  D10: this is what activates the OpenTelemetry agent. The agent is baked into
  the image and completely inert without this variable, which is what keeps the
  image usable outside the lab.
*/}}
{{/*
  `noAgent` lets a caller opt out. It exists because the migration Job must NOT
  export telemetry — a one-shot process produces a trace with no parent and a
  metric series that never continues, which shows up in dashboards as a
  permanently stalled service.
  The first version of that Job appended `JAVA_TOOL_OPTIONS: ""` after this
  block instead, which produced TWO entries for the same key. Kubernetes accepts
  that (last wins) but server-side apply refuses it outright:
    .spec.template.spec.containers[name="migrate"].env: duplicate entries for
    key [name="JAVA_TOOL_OPTIONS"]
  An opt-out is the honest shape; a second entry is a collision that happens to
  resolve.
*/}}
{{- if and .root.Values.observability.agentEnabled (not .noAgent) }}
- name: JAVA_TOOL_OPTIONS
  value: "-javaagent:/opt/otel/opentelemetry-javaagent.jar"
- name: OTEL_SERVICE_NAME
  value: {{ .name | quote }}
- name: OTEL_EXPORTER_OTLP_ENDPOINT
  value: "http://{{ .root.Values.observability.collectorService }}.{{ .root.Values.global.obsNamespace }}:4317"
- name: OTEL_EXPORTER_OTLP_PROTOCOL
  value: "grpc"
{{/*
  FR-080b: always_on IS A LAB SETTING AND NEVER A PRODUCTION RECOMMENDATION.
  A sampler that discards the request under investigation makes SC-012 — retrieve
  *this specific* request's trace — untestable. docs/observability.md repeats this
  where a reader looking for guidance will actually find it.
*/}}
- name: OTEL_TRACES_SAMPLER
  value: {{ .root.Values.observability.tracesSampler | quote }}
- name: OTEL_METRICS_EXPORTER
  value: "otlp"
- name: OTEL_LOGS_EXPORTER
  value: "none"
{{- end }}
{{- range $k, $v := .svc.extraEnv }}
- name: {{ $k }}
  value: {{ $v | quote }}
{{- end }}
{{- end }}
