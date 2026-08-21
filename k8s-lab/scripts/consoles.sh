#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# consoles.sh — the three consoles and the delivery status (FR-086, FR-088).
#
# THREE consoles, and no fourth may be added:
#
#   console-cluster    Headlamp   nodes, pods, events, logs, resource usage
#   console-metrics    Grafana    metrics AND TRACES — Tempo is queried through
#                                 Grafana, which is exactly why Tempo was chosen
#                                 over Jaeger (FR-080a). A tracing UI would be
#                                 the forbidden fourth console.
#   console-delivery   Argo CD    sync state and history
#
# Each is reached by ONE deterministic documented mechanism: a port-forward to
# a fixed local port. Fixed, because a documented address that changes per run
# is not documentation.
# ---------------------------------------------------------------------------
set -uo pipefail

LAB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${LAB_ROOT}/scripts/lib/versions.sh"
source "${LAB_ROOT}/scripts/lib/log.sh"
source "${LAB_ROOT}/scripts/lib/wait.sh"

K="kubectl --context ${LAB_KUBECONTEXT}"
QUIET=0
for a in "$@"; do [[ "$a" == "--quiet" ]] && QUIET=1; done

CONSOLE_PORT_CLUSTER=8081
CONSOLE_PORT_METRICS=3000
CONSOLE_PORT_DELIVERY=8080

# forward <namespace> <svc/name> <local:remote> <label> <extra notes...>
forward() {
  local ns="$1" target="$2" ports="$3" label="$4"; shift 4
  local local_port="${ports%%:*}"

  if ! $K -n "$ns" get "$target" >/dev/null 2>&1; then
    log_error "${label} is not installed (${target} in ${ns})"
    log_error "Run 'make setup' first."
    return 1
  fi

  printf '\n  %s\n' "${label}"
  printf '  %s\n' "http://localhost:${local_port}"
  local note
  for note in "$@"; do printf '  %s\n' "$note"; done
  printf '\n  Ctrl-C to stop.\n\n'

  # exec so Ctrl-C reaches kubectl directly rather than this wrapper.
  exec $K -n "$ns" port-forward "$target" "$ports"
}

cmd_cluster() {
  forward "${NS_DELIVERY}" svc/headlamp "${CONSOLE_PORT_CLUSTER}:80" \
    "Cluster console (Headlamp)" \
    "Covers nodes, namespaces, pods, deployments, services, events, logs and resource usage." \
    "Note: Headlamp acts with its own cluster-admin service account, so anything you can" \
    "click here, it can do. That is a lab posture — production uses per-user SSO and" \
    "RBAC-scoped tokens. See docs/production-mapping.md."
}

cmd_metrics() {
  forward "${NS_OBS}" svc/grafana "${CONSOLE_PORT_METRICS}:80" \
    "Metrics and traces (Grafana)" \
    "Dashboards: 'Hydra — RED' and 'Hydra — runtime, resources and scaling'." \
    "TRACES ARE HERE TOO — Explore -> Tempo. There is no separate tracing UI and none" \
    "may be added (FR-080a); that is why Tempo was chosen over Jaeger." \
    "Anonymous access with an Admin role: no credential exists to leak."
}

cmd_delivery() {
  forward "${NS_DELIVERY}" svc/argocd-server "${CONSOLE_PORT_DELIVERY}:80" \
    "Delivery console (Argo CD)" \
    "The 'hydra-lab' Application reconciles the umbrella chart from the lab's local git remote." \
    "Secrets are NOT in git — the tracked tree carries Secret names only (FR-085)."
}

# ---------------------------------------------------------------------------
# argocd-status (T134a) — FR-086's *status* half, read from the resources.
#
# Deliberately not "is the Argo CD pod running". A delivery controller that is
# up and reports every Application OutOfSync is not a working delivery plane,
# and pod readiness cannot tell the difference.
# ---------------------------------------------------------------------------
cmd_argocd_status() {
  (( QUIET )) || log_suite "argocd-status"

  if ! $K get crd applications.argoproj.io >/dev/null 2>&1; then
    log_fail "Argo CD is not installed" "no applications.argoproj.io CRD"
    log_summary; return 1
  fi

  local apps
  apps="$($K -n "${NS_DELIVERY}" get applications.argoproj.io -o json 2>/dev/null || echo '{}')"
  local count
  count="$(printf '%s' "$apps" | jq -r '.items | length' 2>/dev/null || echo 0)"

  if [[ "${count:-0}" == "0" ]]; then
    log_fail "no Argo CD Applications exist" "the root Application should reconcile the umbrella chart"
    log_summary; return 1
  fi

  local line name sync health revision reconciled
  while IFS=$'\t' read -r name sync health revision reconciled; do
    [[ -n "$name" ]] || continue
    line="${name}: sync=${sync} health=${health} revision=${revision:0:8} reconciled=${reconciled}"
    if [[ "$sync" == "Synced" && "$health" == "Healthy" ]]; then
      log_pass "$line" "read from the Application resource, not the UI"
    else
      log_fail "$line"
      # Name the likely cause rather than leaving the reader to guess.
      case "$health" in
        Progressing) log_context "Still converging. If it stays here, a workload is not becoming Ready." ;;
        Degraded)    log_context "A managed resource is failing. 'make dump' shows which." ;;
        Missing)     log_context "Argo CD expects resources that do not exist — the sync may never have run." ;;
      esac
      [[ "$sync" == "OutOfSync" ]] && \
        log_context "The cluster differs from the tracked desired state. That is drift, and selfHeal should be correcting it."
    fi
  done < <(printf '%s' "$apps" | jq -r '.items[] |
    [ .metadata.name,
      (.status.sync.status // "unknown"),
      (.status.health.status // "unknown"),
      (.status.sync.revision // "unknown"),
      (.status.reconciledAt // "never") ] | @tsv' 2>/dev/null)

  log_summary
}

# ---------------------------------------------------------------------------
# logs (T135) — structured logs for a named workload.
# ---------------------------------------------------------------------------
cmd_logs() {
  local workload="${WORKLOAD:-${2:-}}"
  if [[ -z "$workload" ]]; then
    printf 'usage: make logs WORKLOAD=<name>\n\n'
    printf 'Workloads in %s:\n' "${NS_APP}"
    $K -n "${NS_APP}" get deploy -o name 2>/dev/null | sed 's|deployment.apps/|  |'
    printf '\nDatastores in %s:\n' "${NS_DATA}"
    $K -n "${NS_DATA}" get statefulset -o name 2>/dev/null | sed 's|statefulset.apps/|  |'
    return 2
  fi

  local ns="${NS_APP}" kind="deploy"
  if $K -n "${NS_DATA}" get statefulset "$workload" >/dev/null 2>&1; then
    ns="${NS_DATA}"; kind="statefulset"
  elif ! $K -n "${NS_APP}" get deploy "$workload" >/dev/null 2>&1; then
    log_error "no workload named '${workload}' in ${NS_APP} or ${NS_DATA}"
    return 1
  fi

  printf '# %s/%s in %s — all replicas, following.\n' "$kind" "$workload" "$ns"
  printf '# Records carry trace_id and span_id from the OTel agent (FR-082);\n'
  printf '# paste one into Grafana -> Explore -> Tempo to see the whole request.\n\n'
  exec $K -n "$ns" logs "${kind}/${workload}" --all-containers --tail=200 -f
}

case "${1:-}" in
  cluster)       cmd_cluster ;;
  metrics)       cmd_metrics ;;
  delivery)      cmd_delivery ;;
  argocd-status) cmd_argocd_status ;;
  logs)          cmd_logs "$@" ;;
  *) log_error "usage: consoles.sh {cluster|metrics|delivery|argocd-status|logs}"; exit 2 ;;
esac
