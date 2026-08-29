#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# platform.sh — everything between a bare cluster and a place applications can
# run: namespaces, Cilium, the Gateway API, the Gateway itself, observability,
# Argo CD and the cluster console.
#
# Every subcommand comes in a pair: a *doer* (`cilium`, `gateway`, …) and a
# *checker* (`net-status`, `gw-status`, `…-check`). The checkpoint runner calls
# the doer as its action and the checker as its validation, and only the
# checker decides the verdict — which is the mechanism behind FR-098. A
# `helm install` that exits zero and leaves nothing serving must not be able to
# report PASS, and here it structurally cannot.
# ---------------------------------------------------------------------------
set -uo pipefail

LAB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${LAB_ROOT}/scripts/lib/versions.sh"
source "${LAB_ROOT}/scripts/lib/log.sh"
source "${LAB_ROOT}/scripts/lib/wait.sh"

K="kubectl --context ${LAB_KUBECONTEXT}"
QUIET=0
for a in "$@"; do [[ "$a" == "--quiet" ]] && QUIET=1; done
REDUCED="${LAB_REDUCED:-0}"

require_helm() {
  command -v helm >/dev/null 2>&1 || {
    log_error "helm is not installed. 'make doctor' names this and tells you how to fix it."
    exit 1
  }
}

# helm_repo <name> <url> — idempotent; `helm repo add` on an existing name with
# the same URL is a no-op, and with a different URL it is an error we want.
helm_repo() {
  helm repo add "$1" "$2" >/dev/null 2>&1 || true
  helm repo update "$1" >/dev/null 2>&1 || true
}

# Substitute ${VAR} occurrences from the environment. envsubst is not on a
# stock macOS, and adding a dependency for six substitutions is not worth it.
render() {
  local file="$1" line out=""
  while IFS= read -r line; do
    line="${line//\$\{GATEWAY_NODEPORT_HTTPS\}/${GATEWAY_NODEPORT_HTTPS}}"
    line="${line//\$\{GATEWAY_NODEPORT_HTTP\}/${GATEWAY_NODEPORT_HTTP}}"
    line="${line//\$\{NS_APP\}/${NS_APP}}"
    line="${line//\$\{NS_OBS\}/${NS_OBS}}"
    line="${line//\$\{NS_DATA\}/${NS_DATA}}"
    line="${line//\$\{NS_DELIVERY\}/${NS_DELIVERY}}"
    line="${line//\$\{LAB_BASE_DOMAIN\}/${LAB_BASE_DOMAIN}}"
    line="${line//\$\{PSA_ENFORCE_VERSION\}/${PSA_ENFORCE_VERSION}}"
    out+="${line}
"
  done < "$file"
  printf '%s' "$out"
}

# ===========================================================================
# namespaces (T025)
# ===========================================================================
cmd_namespaces() {
  log_suite "namespaces"
  # Rendered, not applied raw: the Pod Security Admission enforce-version is a
  # matrix value. `latest` is the idiomatic PSA value and is a moving reference
  # by definition — the same manifest enforces different rules after a cluster
  # upgrade, which is the surprise pinning exists to prevent.
  local rendered
  rendered="$(render "${LAB_ROOT}/platform/namespaces.yaml")"
  if printf '%s' "$rendered" | $K apply -f - >/dev/null 2>&1; then
    log_pass "namespaces applied" "kubectl apply (PSA pinned to ${PSA_ENFORCE_VERSION})"
  else
    log_fail "could not apply namespaces"
    log_context "$(printf '%s' "$rendered" | $K apply -f - 2>&1)"
  fi
  log_summary
}

cmd_namespaces_check() {
  (( QUIET )) || log_suite "namespaces check"
  local ns
  for ns in "${NS_APP}" "${NS_DATA}" "${NS_OBS}" "${NS_DELIVERY}"; do
    if $K get ns "$ns" >/dev/null 2>&1; then
      log_pass "namespace ${ns} exists" "kubectl get ns ${ns}"
    else
      log_fail "namespace ${ns} missing"
    fi
  done

  # FR-074, asserted against reality rather than against intent. `default`
  # accumulates workloads by accident — a stray `kubectl run`, a probe pod
  # someone forgot to delete — and the whole point of naming the namespaces is
  # that nothing of the lab's lives outside them.
  local stray
  stray="$($K -n default get pods,deploy,statefulset --no-headers 2>/dev/null | grep -v '^No resources' | wc -l | tr -d ' ')"
  if [[ "$stray" == "0" ]]; then
    log_pass "no workload in the default namespace" "FR-074"
  else
    log_fail "${stray} workload(s) found in the default namespace (FR-074)"
    log_context "$($K -n default get pods,deploy,statefulset 2>&1)"
  fi
  log_summary
}

# ===========================================================================
# cilium (T032)
# ===========================================================================
cmd_cilium() {
  require_helm
  log_suite "cilium"
  helm_repo cilium "${HELM_REPO_CILIUM}"

  # kind's API server address, discovered rather than assumed. With
  # kubeProxyMode:none there is no kube-proxy to provide the in-cluster
  # kubernetes.default route, so Cilium has to be told where the API server is
  # — this is the single most common cause of a Cilium agent that starts and
  # then cannot talk to anything.
  local api_host api_port
  api_host="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' \
              "${LAB_CLUSTER}-control-plane" 2>/dev/null | head -1)"
  api_port=6443
  if [[ -z "$api_host" ]]; then
    log_fail "could not determine the control-plane node address"
    log_summary; return 1
  fi
  log_info "API server for Cilium: ${api_host}:${api_port} (discovered, not assumed)"

  local extra=()
  if (( REDUCED )); then
    # D18: the Hubble *UI* goes; the relay stays, so `hubble observe` still
    # works. What reduced mode removes is a web console, not visibility.
    extra+=(--set hubble.ui.enabled=false)
    log_info "reduced mode: Hubble UI disabled (relay retained)"
  fi

  if helm upgrade --install cilium cilium/cilium \
       --version "${CILIUM_CHART_VERSION}" \
       --namespace kube-system \
       --values "${LAB_ROOT}/platform/cilium/values.yaml" \
       --set "k8sServiceHost=${api_host}" \
       --set "k8sServicePort=${api_port}" \
       ${extra[@]+"${extra[@]}"} \
       --wait --timeout "${TIMEOUT_CILIUM_READY}s" >/dev/null 2>&1; then
    log_pass "cilium chart ${CILIUM_CHART_VERSION} installed" "helm upgrade --install"
  else
    log_fail "cilium install did not complete"
    log_context "$($K -n kube-system get pods -l k8s-app=cilium 2>&1)"
    log_context "$($K -n kube-system logs -l k8s-app=cilium --tail=30 2>&1 | tail -30)"
    log_summary; return 1
  fi

  # Nodes only become Ready once a CNI is running. This is the moment that
  # happens, so it is asserted here rather than in cluster-create where it
  # could not possibly have been true.
  local expected=$(( 1 + KIND_WORKER_COUNT ))
  wait_for_output "all ${expected} nodes reach Ready now that a CNI exists" "${TIMEOUT_NODE_READY}" \
    "$expected" \
    bash -c "$K get nodes --no-headers 2>/dev/null | awk '\$2==\"Ready\"' | wc -l | tr -d ' '" \
    || { log_summary; return 1; }
  log_pass "all ${expected} nodes Ready" "CNI is up"

  log_summary
}

# ---------------------------------------------------------------------------
# net-status (T033) — Cilium health per node.
# ---------------------------------------------------------------------------
cmd_net_status() {
  (( QUIET )) || log_suite "net-status"

  local expected agents_ready
  expected=$(( 1 + KIND_WORKER_COUNT ))
  agents_ready="$($K -n kube-system get pods -l k8s-app=cilium --no-headers 2>/dev/null \
                  | awk '$3=="Running"' | wc -l | tr -d ' ')"
  if [[ "$agents_ready" == "$expected" ]]; then
    log_pass "cilium agent Running on all ${expected} nodes" "kubectl -n kube-system get pods -l k8s-app=cilium"
  else
    log_fail "cilium agent Running on ${agents_ready}/${expected} nodes"
    log_context "$($K -n kube-system get pods -l k8s-app=cilium -o wide 2>&1)"
  fi

  # Per-node health from the agent itself. `Running` is a kubelet opinion;
  # `cilium-dbg status` is the datapath's own.
  local pod node
  while IFS= read -r pod; do
    [[ -n "$pod" ]] || continue
    node="$($K -n kube-system get pod "$pod" -o jsonpath='{.spec.nodeName}' 2>/dev/null)"
    local brief
    brief="$($K -n kube-system exec "$pod" -c cilium-agent -- cilium-dbg status --brief 2>/dev/null | tr -d '\r')"
    if [[ "$brief" == "OK" ]]; then
      log_pass "cilium datapath healthy on ${node}" "cilium-dbg status --brief"
    else
      log_fail "cilium datapath on ${node}: ${brief:-no answer}"
      log_context "$($K -n kube-system exec "$pod" -c cilium-agent -- cilium-dbg status 2>&1 | head -25)"
    fi
  done < <($K -n kube-system get pods -l k8s-app=cilium -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null)

  # FR-023: the kube-proxy replacement must be the actual datapath, not an
  # option that happens to be set. Ask the agent what mode it is in.
  local first_agent kpr
  first_agent="$($K -n kube-system get pods -l k8s-app=cilium -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
  if [[ -n "$first_agent" ]]; then
    kpr="$($K -n kube-system exec "$first_agent" -c cilium-agent -- cilium-dbg status 2>/dev/null \
           | sed -n 's/^KubeProxyReplacement: *//p' | head -1 | tr -d '\r')"
    if [[ "$kpr" == True* ]]; then
      log_pass "kube-proxy replacement active" "cilium-dbg status: ${kpr}"
    else
      log_fail "kube-proxy replacement is not active" "cilium-dbg status: ${kpr:-unknown}"
      log_context "The cluster was created with kubeProxyMode:none. Without the replacement there is no service routing at all."
    fi
    # There must be no kube-proxy DaemonSet at all — if one exists, the
    # replacement is layered on top of it and neither path is the one tested.
    if $K -n kube-system get daemonset kube-proxy >/dev/null 2>&1; then
      log_fail "a kube-proxy DaemonSet exists alongside the replacement (FR-023)"
    else
      log_pass "no kube-proxy DaemonSet exists" "kubeProxyMode:none honoured"
    fi
  fi

  # Envoy is present as Cilium's data plane — the FR-029 shape.
  #
  # Existence is NOT the check. The first version of this asserted only that the
  # DaemonSet existed, and it passed cheerfully while all three Envoy pods sat in
  # CrashLoopBackOff with a malformed bootstrap config — i.e. it reported the
  # gateway's entire data plane healthy when no gateway could possibly serve.
  # That is exactly the asserted-pass FR-098 forbids, so the check now reads
  # numberReady.
  if $K -n kube-system get daemonset cilium-envoy >/dev/null 2>&1; then
    local envoy_desired envoy_ready
    envoy_desired="$($K -n kube-system get daemonset cilium-envoy -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null || echo 0)"
    envoy_ready="$($K -n kube-system get daemonset cilium-envoy -o jsonpath='{.status.numberReady}' 2>/dev/null || echo 0)"
    if [[ "${envoy_ready:-0}" == "${envoy_desired:-0}" && "${envoy_desired:-0}" != "0" ]]; then
      log_pass "Cilium's Envoy Ready on ${envoy_ready}/${envoy_desired} nodes" "the gateway's data plane, not a separate controller (FR-029)"
    else
      log_fail "Cilium's Envoy Ready on ${envoy_ready:-0}/${envoy_desired:-0} nodes"
      log_context "$($K -n kube-system get pods -l k8s-app=cilium-envoy -o wide 2>&1)"
      log_context "$($K -n kube-system logs -l k8s-app=cilium-envoy --tail=10 2>&1 | tail -10)"
      log_context "A crash-looping Envoy means the Gateway cannot serve, whatever the Gateway's own status says."
    fi
  else
    log_fail "Cilium's Envoy DaemonSet is missing" "envoy.enabled must be true for the Gateway"
  fi

  log_summary
}

# ===========================================================================
# gateway-api (T038)
# ===========================================================================
cmd_gateway_api() {
  log_suite "gateway-api CRDs"

  local crd_dir="${LAB_ROOT}/platform/gateway-api/crds"
  local base="https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/${GATEWAY_API_CHANNEL}-install.yaml"

  # Vendored CRDs are preferred: an offline steady state is an explicit
  # assumption of this lab (D8), and a setup that reaches the public internet
  # for a CRD bundle is not reproducible on a plane. The download path exists
  # so the first run on a fresh clone can populate the vendor directory.
  if [[ -s "${crd_dir}/${GATEWAY_API_CHANNEL}-install.yaml" ]]; then
    log_info "using the vendored CRD bundle (offline-capable)"
  else
    log_info "vendored CRD bundle absent — fetching ${GATEWAY_API_VERSION} ${GATEWAY_API_CHANNEL} channel once"
    mkdir -p "$crd_dir"
    if ! curl -fsSL "$base" -o "${crd_dir}/${GATEWAY_API_CHANNEL}-install.yaml"; then
      log_fail "could not fetch the Gateway API CRDs"
      log_context "URL: ${base}
Vendor them by hand into ${crd_dir}/ if this workstation has no network access."
      log_summary; return 1
    fi
    log_pass "CRD bundle vendored" "${crd_dir}/${GATEWAY_API_CHANNEL}-install.yaml"
  fi

  if $K apply -f "${crd_dir}/${GATEWAY_API_CHANNEL}-install.yaml" >/dev/null 2>&1; then
    log_pass "Gateway API ${GATEWAY_API_VERSION} CRDs applied" "${GATEWAY_API_CHANNEL} channel"
  else
    log_fail "could not apply the Gateway API CRDs"
    log_summary; return 1
  fi
  log_summary
}

cmd_gateway_api_check() {
  (( QUIET )) || log_suite "gateway-api check"
  local crd
  # FR-027: stable API versions where available. gatewayclasses/gateways/
  # httproutes are v1; referencegrants is v1beta1 in the standard channel.
  for crd in gatewayclasses.gateway.networking.k8s.io \
             gateways.gateway.networking.k8s.io \
             httproutes.gateway.networking.k8s.io \
             referencegrants.gateway.networking.k8s.io; do
    if $K get crd "$crd" >/dev/null 2>&1; then
      local served
      served="$($K get crd "$crd" -o jsonpath='{range .spec.versions[?(@.served==true)]}{.name} {end}' 2>/dev/null)"
      log_pass "CRD ${crd}" "served versions: ${served}"
    else
      log_fail "CRD ${crd} is not installed"
    fi
  done

  # The experimental channel must NOT be present: FR-027 says standard channel,
  # and mixing them produces CRDs whose fields Cilium may not implement.
  if $K get crd tlsroutes.gateway.networking.k8s.io >/dev/null 2>&1; then
    log_fail "an experimental-channel CRD (TLSRoute) is installed" "FR-027 specifies the standard channel"
  else
    log_pass "no experimental-channel CRDs installed" "standard channel only (FR-027)"
  fi
  log_summary
}

# ===========================================================================
# gateway (T040) — GatewayClass + Gateway + fixed NodePort
# ===========================================================================
cmd_gateway() {
  log_suite "gateway"

  if $K apply -f "${LAB_ROOT}/platform/gateway-api/gatewayclass.yaml" >/dev/null 2>&1; then
    log_pass "GatewayClass 'cilium' applied" "kubectl apply"
  else
    log_fail "could not apply the GatewayClass"; log_summary; return 1
  fi

  if $K apply -f "${LAB_ROOT}/platform/gateway-api/gateway.yaml" >/dev/null 2>&1; then
    log_pass "Gateway 'hydra-gateway' applied in ${NS_APP}" "kubectl apply"
  else
    log_fail "could not apply the Gateway"; log_summary; return 1
  fi

  # Cilium creates the Gateway's Service. Wait for it before patching, because
  # patching a Service that does not exist yet fails in a way that looks like a
  # manifest error.
  if ! wait_for "Cilium creates the Gateway's Service" "${TIMEOUT_GATEWAY_PROGRAMMED}" \
       bash -c "$K -n ${NS_APP} get svc cilium-gateway-hydra-gateway >/dev/null 2>&1"; then
    log_context "$($K -n ${NS_APP} get gateway hydra-gateway -o yaml 2>&1 | tail -40)"
    log_summary; return 1
  fi

  # Pin the fixed NodePorts kind's extraPortMappings bind host 443/80 to.
  #
  # A PATCH, not an apply. Cilium owns this Service — type LoadBalancer, no
  # selector, ownerReference to the Gateway — and applying a full Service spec
  # fights it over the type and the port names, which it reverts. Patching only
  # the nodePort field is preserved across reconciliation. See the long note in
  # platform/gateway-api/gateway-service.yaml; both facts were established by
  # running it, not by reading.
  #
  # The patch is built from the port NUMBER, not an array index: the controller
  # does not guarantee port ordering, and an index-based patch silently swaps
  # HTTP and HTTPS the day it changes.
  local svc="cilium-gateway-hydra-gateway"
  local ops="" idx port want
  while IFS=' ' read -r idx port; do
    [[ -n "$port" ]] || continue
    case "$port" in
      443) want="${GATEWAY_NODEPORT_HTTPS}" ;;
      80)  want="${GATEWAY_NODEPORT_HTTP}" ;;
      *)   continue ;;
    esac
    [[ -n "$ops" ]] && ops+=","
    ops+="{\"op\":\"replace\",\"path\":\"/spec/ports/${idx}/nodePort\",\"value\":${want}}"
  done < <($K -n "${NS_APP}" get svc "$svc" -o json 2>/dev/null \
           | jq -r '.spec.ports | to_entries[] | "\(.key) \(.value.port)"')

  if [[ -z "$ops" ]]; then
    log_fail "could not read the Gateway Service's ports to patch them"
  elif $K -n "${NS_APP}" patch svc "$svc" --type=json -p "[${ops}]" >/dev/null 2>&1; then
    log_pass "Gateway Service pinned to NodePorts ${GATEWAY_NODEPORT_HTTPS}/${GATEWAY_NODEPORT_HTTP}" \
             "the one deterministic exposure mechanism (FR-030)"
  else
    log_fail "could not pin the Gateway Service to its fixed NodePorts"
    log_context "$($K -n "${NS_APP}" patch svc "$svc" --type=json -p "[${ops}]" 2>&1)"
  fi

  # FR-037: if the implementation enables any CORS handling by default, it is
  # explicitly disabled. Cilium's Gateway API does not enable CORS by default;
  # the check that this remains true is an executed assertion in
  # tests/integration/edge-headers.sh, not a comment here.

  if ! wait_for_output "Gateway reports Programmed" "${TIMEOUT_GATEWAY_PROGRAMMED}" "True" \
       bash -c "$K -n ${NS_APP} get gateway hydra-gateway -o jsonpath='{.status.conditions[?(@.type==\"Programmed\")].status}' 2>/dev/null"; then
    log_context "$($K -n ${NS_APP} get gateway hydra-gateway -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.reason}: {.message}{\"\n\"}{end}' 2>&1)"
    log_context "A Gateway that will not become Programmed is usually a missing or unreadable TLS Secret — check the 'certs' checkpoint."
    log_summary; return 1
  fi
  log_pass "Gateway Programmed" "status.conditions[Programmed]=True"

  log_summary
}

# ---------------------------------------------------------------------------
# gw-status (T041)
# ---------------------------------------------------------------------------
cmd_gw_status() {
  (( QUIET )) || log_suite "gw-status"

  if $K get gatewayclass cilium >/dev/null 2>&1; then
    local accepted controller
    accepted="$($K get gatewayclass cilium -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}' 2>/dev/null)"
    controller="$($K get gatewayclass cilium -o jsonpath='{.spec.controllerName}' 2>/dev/null)"
    if [[ "$accepted" == "True" ]]; then
      log_pass "GatewayClass 'cilium' Accepted" "controller ${controller}"
    else
      log_fail "GatewayClass 'cilium' is not Accepted" "Accepted=${accepted:-<none>}"
    fi
  else
    log_fail "GatewayClass 'cilium' does not exist"
    log_summary; return 1
  fi

  # FR-029, checked rather than assumed: exactly one GatewayClass, and it is
  # Cilium's. A second one would mean a standalone controller got installed.
  local class_count
  class_count="$($K get gatewayclass --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  if [[ "$class_count" == "1" ]]; then
    log_pass "exactly one GatewayClass exists" "no standalone gateway controller (FR-029)"
  else
    log_fail "${class_count} GatewayClasses exist — a standalone controller may have been installed (FR-029)"
    log_context "$($K get gatewayclass 2>&1)"
  fi

  local programmed
  programmed="$($K -n "${NS_APP}" get gateway hydra-gateway \
    -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null)"
  if [[ "$programmed" == "True" ]]; then
    log_pass "Gateway 'hydra-gateway' Programmed" "status.conditions[Programmed]"
  else
    log_fail "Gateway 'hydra-gateway' not Programmed" "Programmed=${programmed:-<none>}"
    log_context "$($K -n "${NS_APP}" get gateway hydra-gateway -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.reason}: {.message}{"\n"}{end}' 2>&1)"
  fi

  # Listener-level status: a Gateway can be Programmed while one listener's
  # certificateRefs are unresolvable, and the request that fails then names
  # nothing useful.
  local bad_listeners
  bad_listeners="$($K -n "${NS_APP}" get gateway hydra-gateway -o json 2>/dev/null | jq -r '
    (.status.listeners // [])[]
    | select(((.conditions // [])[] | select(.type=="ResolvedRefs") | .status) != "True")
    | .name' 2>/dev/null || true)"
  if [[ -z "$bad_listeners" ]]; then
    log_pass "every listener resolved its references" "including the TLS Secret (FR-032)"
  else
    log_fail "listener(s) with unresolved references: ${bad_listeners}"
  fi

  # Routes. ZERO routes is a valid US1 state — routes arrive with the chart in
  # US2 — so this reports rather than fails when there are none.
  local route_count unaccepted
  route_count="$($K -n "${NS_APP}" get httproute --no-headers 2>/dev/null | grep -c . 2>/dev/null | head -1 | tr -d ' ')"
  [[ -n "$route_count" ]] || route_count=0
  if [[ "$route_count" == "0" ]]; then
    log_pass "no HTTPRoutes yet" "valid before the umbrella chart is installed (US1)"
  else
    unaccepted="$($K -n "${NS_APP}" get httproute -o json 2>/dev/null | jq -r '
      .items[]
      | select([ (.status.parents // [])[] | (.conditions // [])[] | select(.type=="Accepted") | .status ] | index("True") | not)
      | .metadata.name' 2>/dev/null || true)"
    if [[ -z "$unaccepted" ]]; then
      log_pass "all ${route_count} HTTPRoute(s) Accepted" "status.parents[].conditions[Accepted]"
    else
      log_fail "HTTPRoute(s) not Accepted: ${unaccepted}"
      log_context "$($K -n "${NS_APP}" get httproute -o yaml 2>&1 | grep -A6 'conditions:' | head -30)"
    fi
  fi

  # The exposure path, end to end in configuration terms.
  local nodeport
  nodeport="$($K -n "${NS_APP}" get svc cilium-gateway-hydra-gateway \
    -o jsonpath='{.spec.ports[?(@.port==443)].nodePort}' 2>/dev/null)"
  if [[ "$nodeport" == "${GATEWAY_NODEPORT_HTTPS}" ]]; then
    log_pass "Gateway Service on the declared NodePort ${nodeport}" "host 443 is mapped to it by kind"
  else
    log_fail "Gateway Service NodePort is '${nodeport:-<none>}', declared ${GATEWAY_NODEPORT_HTTPS}"
    log_context "kind's extraPortMappings bind host 443 to ${GATEWAY_NODEPORT_HTTPS}. A different port means nothing reaches the gateway."
  fi

  log_summary
}

# ===========================================================================
# observability (T096)
# ===========================================================================
cmd_observability() {
  require_helm
  log_suite "observability"

  if (( REDUCED )); then
    log_info "reduced mode: Tempo will not be installed (D18, FR-091)"
    log_info "  consequence: the end-to-end trace scenario (SC-012) is UNAVAILABLE, not passing"
  fi

  helm_repo prometheus-community "${HELM_REPO_PROMETHEUS}"
  helm_repo grafana "${HELM_REPO_GRAFANA}"
  helm_repo open-telemetry "${HELM_REPO_OTEL}"

  # Order matters: the collector must exist before Prometheus is told to scrape
  # it, and Tempo before the collector is told to export to it. Installing in
  # dependency order avoids a first-minutes window of scrape failures that look
  # like faults.
  if (( ! REDUCED )); then
    if helm upgrade --install tempo grafana/tempo \
         --version "${TEMPO_CHART_VERSION}" --namespace "${NS_OBS}" \
         --values "${LAB_ROOT}/platform/observability/tempo-values.yaml" \
         --wait --timeout "${TIMEOUT_WORKLOAD_READY}s" >/dev/null 2>&1; then
      log_pass "tempo ${TEMPO_CHART_VERSION} installed" "the only trace store (FR-080a)"
    else
      log_fail "tempo install did not complete"
      log_context "$($K -n "${NS_OBS}" get pods 2>&1)"
    fi
  else
    log_skip "tempo" "reduced mode disables the trace store (D18)"
  fi

  if helm upgrade --install otel-collector open-telemetry/opentelemetry-collector \
       --version "${OTEL_COLLECTOR_CHART_VERSION}" --namespace "${NS_OBS}" \
       --values "${LAB_ROOT}/platform/observability/otel-collector-values.yaml" \
       --set "config.exporters.otlp/tempo.endpoint=tempo.${NS_OBS}.svc.cluster.local:4317" \
       --wait --timeout "${TIMEOUT_WORKLOAD_READY}s" >/dev/null 2>&1; then
    log_pass "opentelemetry-collector ${OTEL_COLLECTOR_CHART_VERSION} installed" "OTLP/gRPC on 4317"
  else
    log_fail "otel-collector install did not complete"
    log_context "$($K -n "${NS_OBS}" logs -l app.kubernetes.io/name=opentelemetry-collector --tail=30 2>&1 | tail -30)"
  fi

  if helm upgrade --install prometheus prometheus-community/prometheus \
       --version "${PROMETHEUS_CHART_VERSION}" --namespace "${NS_OBS}" \
       --values "${LAB_ROOT}/platform/observability/prometheus-values.yaml" \
       --wait --timeout "${TIMEOUT_WORKLOAD_READY}s" >/dev/null 2>&1; then
    log_pass "prometheus ${PROMETHEUS_CHART_VERSION} installed" "with kube-state-metrics"
  else
    log_fail "prometheus install did not complete"
    log_context "$($K -n "${NS_OBS}" get pods 2>&1)"
  fi

  # Dashboards are delivered as a ConfigMap the Grafana sidecar picks up, so
  # they are versioned with the lab rather than clicked into a database that
  # disappears with the cluster.
  if $K -n "${NS_OBS}" create configmap hydra-lab-dashboards \
       --from-file="${LAB_ROOT}/platform/observability/dashboards/" \
       --dry-run=client -o yaml 2>/dev/null \
     | $K label --local -f - grafana_dashboard=1 --dry-run=client -o yaml 2>/dev/null \
     | $K apply -f - >/dev/null 2>&1; then
    log_pass "dashboards applied as a ConfigMap" "picked up by Grafana's sidecar"
  else
    log_fail "could not apply the dashboard ConfigMap"
  fi

  if helm upgrade --install grafana grafana/grafana \
       --version "${GRAFANA_CHART_VERSION}" --namespace "${NS_OBS}" \
       --values "${LAB_ROOT}/platform/observability/grafana-values.yaml" \
       --wait --timeout "${TIMEOUT_WORKLOAD_READY}s" >/dev/null 2>&1; then
    log_pass "grafana ${GRAFANA_CHART_VERSION} installed" "the only UI — metrics and traces (FR-080a, FR-088)"
  else
    log_fail "grafana install did not complete"
    log_context "$($K -n "${NS_OBS}" get pods 2>&1)"
  fi

  log_summary
}

cmd_observability_check() {
  (( QUIET )) || log_suite "observability check"
  local d
  for d in otel-collector-opentelemetry-collector prometheus-server grafana; do
    if $K -n "${NS_OBS}" get deploy "$d" >/dev/null 2>&1; then
      wait_for_rollout "${NS_OBS}" "deploy/${d}" 180 \
        && log_pass "${d} Ready" "kubectl rollout status" \
        || log_fail "${d} not Ready"
    else
      log_fail "${d} not found in ${NS_OBS}"
    fi
  done

  if (( REDUCED )); then
    log_skip "tempo" "reduced mode: no trace store, so SC-012 is unavailable — never a pass (D18)"
  else
    if $K -n "${NS_OBS}" get statefulset tempo >/dev/null 2>&1 || $K -n "${NS_OBS}" get deploy tempo >/dev/null 2>&1; then
      log_pass "tempo present" "kubectl get tempo workload"
    else
      log_fail "tempo not found in ${NS_OBS}"
    fi
  fi

  # FR-080a, checked: no parallel tracing UI. Jaeger would be exactly that.
  local jaeger
  jaeger="$($K get pods -A --no-headers 2>/dev/null | grep -ci jaeger || true)"
  if [[ "$jaeger" == "0" ]]; then
    log_pass "no parallel tracing UI installed" "Grafana queries Tempo (FR-080a)"
  else
    log_fail "a parallel tracing UI appears to be installed (FR-080a)"
  fi

  log_summary
}

# ===========================================================================
# argocd (T129) / console (T133)
# ===========================================================================
cmd_argocd() {
  require_helm
  log_suite "argocd"
  helm_repo argo "${HELM_REPO_ARGO}"

  if helm upgrade --install argocd argo/argo-cd \
       --version "${ARGOCD_CHART_VERSION}" --namespace "${NS_DELIVERY}" \
       --values "${LAB_ROOT}/platform/argocd/values.yaml" \
       --wait --timeout "${TIMEOUT_WORKLOAD_READY}s" >/dev/null 2>&1; then
    log_pass "argo-cd ${ARGOCD_CHART_VERSION} installed" "helm upgrade --install"
  else
    log_fail "argo-cd install did not complete"
    log_context "$($K -n "${NS_DELIVERY}" get pods 2>&1)"
    log_summary; return 1
  fi

  # The git remote Argo CD reconciles from. Local and bare, so the delivery
  # loop is demonstrable with no network and no hosting account (D15).
  "${LAB_ROOT}/scripts/gitops.sh" init || log_fail "could not prepare the local gitops remote"

  # The Application's repoURL is whatever gitops.sh created, so it is rendered
  # rather than committed — a committed file:// path would be one developer's
  # home directory baked into the tracked tree.
  local repo_url branch app_rendered
  # The IN-CLUSTER path, not the workstation path. They refer to the same bare
  # repository through different filesystems: the workstation writes to
  # k8s-lab/.gitops-remote, and kind bind-mounts that into every node at
  # /gitops-remote, which is what the repo-server pod can actually open.
  repo_url="${LAB_GITOPS_REPO_IN_CLUSTER}"
  branch="$("${LAB_ROOT}/scripts/gitops.sh" branch)"
  app_rendered="$(sed -e "s|\${GITOPS_REPO_URL}|${repo_url}|g" \
                      -e "s|\${GITOPS_BRANCH}|${branch}|g" \
                      "${LAB_ROOT}/platform/argocd/root-application.yaml")"
  if printf '%s' "$app_rendered" | $K apply -f - >/dev/null 2>&1; then
    log_pass "root Application registered" "reconciles ${repo_url} (${branch})"
  else
    log_fail "could not register the root Application"
    log_context "$(printf '%s' "$app_rendered" | $K apply -f - 2>&1)"
  fi
  log_summary
}

cmd_argocd_check() {
  (( QUIET )) || log_suite "argocd check"
  wait_for_rollout "${NS_DELIVERY}" deploy/argocd-server 240 \
    && log_pass "argocd-server Ready" "kubectl rollout status" \
    || log_fail "argocd-server not Ready"
  wait_for_rollout "${NS_DELIVERY}" deploy/argocd-repo-server 240 \
    && log_pass "argocd-repo-server Ready" "kubectl rollout status" \
    || log_fail "argocd-repo-server not Ready"
  if $K get crd applications.argoproj.io >/dev/null 2>&1; then
    log_pass "Application CRD installed" "kubectl get crd applications.argoproj.io"
  else
    log_fail "Application CRD missing"
  fi

  # The ROOT APPLICATION must exist, and this check was missing.
  #
  # The original argocd-check verified the Deployments and the CRD and reported
  # PASS while ZERO Applications existed — a delivery control plane that is
  # running and reconciling nothing. The smoke suite caught it three steps
  # later, which is exactly the asserted-pass FR-098 exists to forbid: the
  # component was reported healthy without a check on the thing it is for.
  local app_count
  app_count="$($K -n "${NS_DELIVERY}" get applications.argoproj.io --no-headers 2>/dev/null | grep -c . || true)"
  if [[ "${app_count:-0}" -ge 1 ]]; then
    log_pass "${app_count} Argo CD Application(s) registered" "kubectl get applications"
  else
    log_fail "no Argo CD Application exists" "the root Application reconciles nothing"
    log_context "Argo CD is running and has nothing to do. Check that root-application.yaml applied:"
    log_context "$($K -n "${NS_DELIVERY}" get applications.argoproj.io 2>&1)"
  fi
  log_summary
}

cmd_console() {
  require_helm
  log_suite "console (Headlamp)"
  helm_repo headlamp "${HELM_REPO_HEADLAMP}"
  if helm upgrade --install headlamp headlamp/headlamp \
       --version "${HEADLAMP_CHART_VERSION}" --namespace "${NS_DELIVERY}" \
       --values "${LAB_ROOT}/platform/headlamp/values.yaml" \
       --wait --timeout "${TIMEOUT_WORKLOAD_READY}s" >/dev/null 2>&1; then
    log_pass "headlamp ${HEADLAMP_CHART_VERSION} installed" "in-cluster console (FR-087, D16)"
  else
    log_fail "headlamp install did not complete"
    log_context "$($K -n "${NS_DELIVERY}" get pods 2>&1)"
  fi
  log_summary
}

cmd_console_check() {
  (( QUIET )) || log_suite "console check"
  wait_for_rollout "${NS_DELIVERY}" deploy/headlamp 180 \
    && log_pass "headlamp Ready" "kubectl rollout status" \
    || log_fail "headlamp not Ready"
  log_summary
}

# ===========================================================================
# install / status — the aggregate entry points
# ===========================================================================
cmd_install() {
  cmd_namespaces      && \
  cmd_cilium          && \
  cmd_gateway_api     && \
  cmd_gateway         && \
  cmd_observability   && \
  cmd_argocd          && \
  cmd_console
}

cmd_status() {
  log_suite "platform status"
  printf '\nCilium:\n';        $K -n kube-system get pods -l k8s-app=cilium -o wide 2>&1 | head -6
  printf '\nGateway:\n';       $K -n "${NS_APP}" get gateway,httproute 2>&1 | head -10
  printf '\nObservability:\n'; $K -n "${NS_OBS}" get pods 2>&1 | head -10
  printf '\nDelivery:\n';      $K -n "${NS_DELIVERY}" get pods 2>&1 | head -10
  printf '\n'
  cmd_net_status && cmd_gw_status
}

case "${1:-status}" in
  namespaces)          cmd_namespaces ;;
  namespaces-check)    cmd_namespaces_check ;;
  cilium)              cmd_cilium ;;
  net-status)          cmd_net_status ;;
  gateway-api)         cmd_gateway_api ;;
  gateway-api-check)   cmd_gateway_api_check ;;
  gateway)             cmd_gateway ;;
  gw-status)           cmd_gw_status ;;
  observability)       cmd_observability ;;
  observability-check) cmd_observability_check ;;
  argocd)              cmd_argocd ;;
  argocd-check)        cmd_argocd_check ;;
  console)             cmd_console ;;
  console-check)       cmd_console_check ;;
  install)             cmd_install ;;
  status)              cmd_status ;;
  *) log_error "usage: platform.sh {namespaces|cilium|gateway-api|gateway|observability|argocd|console|install|status|net-status|gw-status|*-check}"; exit 2 ;;
esac
