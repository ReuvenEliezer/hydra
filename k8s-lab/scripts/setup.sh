#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# setup.sh — the ordered checkpoint runner (FR-014, data-model §2).
#
# One command takes a diagnosed host to a validated environment. Every stage is
# a checkpoint: it does work, then a *separate* validation command decides the
# verdict. The first failure halts the run and every later checkpoint reports
# BLOCKED — never "not run yet", which reads as success to a tired eye.
#
# Checkpoint order, and why it is this order:
#
#   cluster           nothing exists before the API server
#   namespaces        every Secret and namespaced install below needs its
#                     namespace to already exist. NOT an umbrella-chart
#                     template: the chart installs last and cannot create the
#                     namespace its own prerequisites already needed (T025)
#   gateway-api       CRDs must exist before CILIUM STARTS, not merely before a
#                     Gateway is applied. Cilium's operator probes for them once
#                     at startup and disables Gateway API support if they are
#                     absent — with no later retry and no message on the Gateway
#                     itself. Learned by executing it.
#   cilium            the only CNI; nodes stay NotReady until it is running
#   registry          images must have somewhere to go before they are built
#   images            build and publish BOTH service images. Not in the
#                     published checkpoint list, and its absence made setup
#                     unsatisfiable on a clean machine: cleanup removes the
#                     registry and everything in it, so `migrate` reached
#                     ImagePullBackOff with a perfectly healthy registry. Placed
#                     early because it is the slowest step — a broken build
#                     should surface before ten minutes of platform install,
#                     not after
#   certs             the Gateway's listener references the TLS Secret, so the
#                     Secret must exist before the Gateway can be Programmed
#   gateway           GatewayClass + Gateway + its NodePort Service. Applied as
#                     a platform object, not a chart template, because US1 must
#                     reach a Programmed Gateway with no chart installed (T039)
#   backing-services  Postgres and Redis, before anything tries to migrate
#   observability     the collector endpoint must exist before app pods that
#                     export to it start, or the first minutes are blind
#   argocd            delivery control plane
#   console           Headlamp
#   migrate           schema, exactly one instance, before any replica (D6)
#   fixture           tenants and users, before any traffic (D7)
#   apps              the Deployments themselves
#
# Two of these — `namespaces` and `gateway` — extend the list data-model §2
# published. Both additions, and the one ordering correction (`certs` before
# `gateway`, where §2's draft had them reversed and the Gateway would have hung
# un-Programmed waiting for a Secret that did not exist yet), are recorded in
# data-model §2 under "Amendments made during implementation".
# ---------------------------------------------------------------------------
set -uo pipefail

LAB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${LAB_ROOT}/scripts/lib/versions.sh"
source "${LAB_ROOT}/scripts/lib/log.sh"
source "${LAB_ROOT}/scripts/lib/wait.sh"
source "${LAB_ROOT}/scripts/lib/checkpoint.sh"

S="${LAB_ROOT}/scripts"
REDUCED=0
SKIP_DOCTOR=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --reduced)     REDUCED=1; shift ;;
    --skip-doctor) SKIP_DOCTOR=1; shift ;;
    *) log_error "unknown argument: $1"; exit 2 ;;
  esac
done
export LAB_REDUCED="$REDUCED"

log_suite "setup${REDUCED:+}"
if (( REDUCED )); then
  printf '%s\n' "Mode: REDUCED FOOTPRINT (values-reduced.yaml)"
  "${S}/reduced-mode-notice.sh" || true
fi

start_epoch="$(date +%s)"

# --- Gate: the host diagnostic (data-model §3: it gates checkpoint(cluster)) ---
if (( ! SKIP_DOCTOR )); then
  log_section "host diagnostic"
  if ! "${S}/doctor.sh"; then
    log_error "The host is not ready. setup will not attempt a cluster on a host the diagnostic rejected."
    log_error "Fix the FAIL lines above, then re-run. \`make doctor\` installs nothing — the fixes are yours to make."
    exit 1
  fi
fi

# --- The checkpoints -------------------------------------------------------
# Each is: name, action, validation. The verdict comes only from the validation.

# Validated with `registered`, NOT `health`. `health` asserts every node is
# Ready, and nodes do not become Ready until a CNI is running — which is the
# `cilium` checkpoint, three steps below. Validating this checkpoint with
# `health` demanded a property that cannot be true yet, and it was masked for
# as long as checkpoint.sh reported every checkpoint as PASSED.
# Node readiness is asserted by `platform.sh cilium`, at the moment it becomes
# achievable; full `health` runs in validate.sh once the environment is up.
checkpoint_run "cluster" \
  "${S}/cluster.sh create" \
  "${S}/cluster.sh registered --quiet" \
  "kind cluster '${LAB_CLUSTER}': 1 control-plane + ${KIND_WORKER_COUNT} workers registered (Ready comes with the CNI)"

checkpoint_run "namespaces" \
  "${S}/platform.sh namespaces" \
  "${S}/platform.sh namespaces-check" \
  "namespaces ${NS_APP}, ${NS_DATA}, ${NS_OBS}, ${NS_DELIVERY} exist; no app workload in default"

# gateway-api BEFORE cilium, and this ordering is load-bearing rather than
# tidy. Cilium's operator checks for the Gateway API CRDs ONCE, at startup:
#
#   "Required GatewayAPI resources are not found, please refer to docs for
#    installation instructions"
#
# and then runs with Gateway API support silently disabled. Every Gateway
# applied afterwards sits at `Accepted=Unknown, reason=Pending, message=Waiting
# for controller` forever, and nothing in the Gateway's own status says why —
# it looks exactly like a Gateway waiting for a controller that is starting up.
# Installing the CRDs first is the whole fix. Found by executing this, not by
# reading documentation.
checkpoint_run "gateway-api" \
  "${S}/platform.sh gateway-api" \
  "${S}/platform.sh gateway-api-check" \
  "Gateway API ${GATEWAY_API_VERSION} (${GATEWAY_API_CHANNEL} channel) CRDs installed"

checkpoint_run "cilium" \
  "${S}/platform.sh cilium" \
  "${S}/platform.sh net-status --quiet" \
  "Cilium ${CILIUM_CHART_VERSION}: kube-proxy replacement, L7 proxy, policy, Hubble"

checkpoint_run "registry" \
  "${S}/registry.sh create" \
  "${S}/registry.sh status --quiet" \
  "local registry at ${LAB_REGISTRY_HOST_ADDR}, reachable from the cluster"

# An `images` checkpoint, which the published checkpoint list did not have —
# and its absence made `make setup` impossible to satisfy on a clean machine.
#
# Found by running it: after a full cleanup, setup reached `migrate` and sat in
# ImagePullBackOff, because cleanup removes the registry container along with
# everything in it and nothing in setup ever put the images back. The failure
# named the registry, which was healthy; the missing step was two checkpoints
# earlier.
#
# It sits after `registry` because the images need somewhere to go, and before
# `certs` only because certs is cheap and images are slow — putting the long
# step early means a broken build is discovered before ten minutes of platform
# installation rather than after it.
checkpoint_run "images" \
  "${S}/images.sh build && ALLOW_DIRTY_PUBLISH=${ALLOW_DIRTY_PUBLISH:-0} ${S}/images.sh publish" \
  "${S}/images.sh publish" \
  "auth-service and order-service built and published under a revision-derived tag"

checkpoint_run "certs" \
  "${S}/certs.sh ensure" \
  "${S}/certs.sh verify" \
  "lab CA + *.${LAB_BASE_DOMAIN} wildcard, TLS Secret in ${NS_APP}, truststore written"

checkpoint_run "gateway" \
  "${S}/platform.sh gateway" \
  "${S}/platform.sh gw-status --quiet" \
  "Gateway 'hydra-gateway' Programmed on :443 via NodePort ${GATEWAY_NODEPORT_HTTPS}"

checkpoint_run "backing-services" \
  "${S}/app.sh backing-services" \
  "${S}/app.sh backing-services-check" \
  "Postgres and Redis Ready in ${NS_DATA}, real probes passing"

checkpoint_run "observability" \
  "${S}/platform.sh observability" \
  "${S}/platform.sh observability-check" \
  "Prometheus, Grafana, OTel Collector and Tempo Ready in ${NS_OBS}"

checkpoint_run "argocd" \
  "${S}/platform.sh argocd" \
  "${S}/platform.sh argocd-check" \
  "Argo CD Ready in ${NS_DELIVERY}, root Application registered"

checkpoint_run "console" \
  "${S}/platform.sh console" \
  "${S}/platform.sh console-check" \
  "Headlamp Ready in ${NS_DELIVERY}"

checkpoint_run "migrate" \
  "${S}/app.sh migrate" \
  "${S}/app.sh migrate-check" \
  "schema authored by one instance per service (D6); replicas will run ddl-auto=validate"

checkpoint_run "fixture" \
  "${S}/app.sh fixture" \
  "${S}/app.sh fixture-check" \
  "tenants ${LAB_PRIMARY_TENANT}/${LAB_SECOND_TENANT} seeded and a real sign-in succeeded (D7)"

# The ACTION is deliberately empty. The chart is installed once, by the
# `migrate` checkpoint, and Helm's hooks run migration -> fixture -> Deployments
# in that order inside that single install. Running `app.sh deploy` again here
# starts a SECOND helm operation against the same release while the first may
# still be settling, which leaves it in `pending-upgrade` and blocks every
# later attempt with "another operation (install/upgrade/rollback) is in
# progress" — a message that names a concurrent operation rather than the
# duplicate step that caused it.
#
# So this checkpoint only VALIDATES, which is what a checkpoint is for.
checkpoint_run "apps" \
  "" \
  "${S}/app.sh status --quiet" \
  "auth-service and order-service Ready behind the gateway"

# --- Report ----------------------------------------------------------------
elapsed=$(( $(date +%s) - start_epoch ))
printf '\nElapsed: %dm %ds (SC-001 budget: 45m from a clean machine)\n' \
  $(( elapsed / 60 )) $(( elapsed % 60 ))

if ! checkpoint_report; then
  exit 1
fi

cat <<SUMMARY

Environment is up. Next:

  make test          smoke + integration + edge conformance + failure drills
  make validate      the aggregated verdict
  make console-metrics / console-cluster / console-delivery

The tenant addresses are https://${LAB_PRIMARY_HOST} and https://${LAB_SECOND_HOST}.
Nothing was written to /etc/hosts and no privilege was elevated (FR-033).
SUMMARY
