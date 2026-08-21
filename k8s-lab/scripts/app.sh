#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# app.sh — deploying Hydra's services (FR-052, FR-052a, FR-053, FR-076).
#
# The ordering requirement is the whole point of this file:
#
#     migration Job  ->  fixture Job  ->  Deployments accepting traffic
#
# and no pod may accept traffic before both Jobs complete. Helm's pre-install
# hooks give the first half; the readiness gate here gives the second.
#
# Secret creation lives here too (T058). Every secret value is GENERATED at
# setup time and exists only in the cluster — never in source, a manifest, a
# chart, an image or version control (FR-053, FR-076, FR-085).
# ---------------------------------------------------------------------------
set -uo pipefail

LAB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${LAB_ROOT}/scripts/lib/versions.sh"
source "${LAB_ROOT}/scripts/lib/log.sh"
source "${LAB_ROOT}/scripts/lib/wait.sh"

K="kubectl --context ${LAB_KUBECONTEXT}"
CHART="${LAB_ROOT}/charts/hydra-lab"
RELEASE="hydra-lab"
QUIET=0
for a in "$@"; do [[ "$a" == "--quiet" ]] && QUIET=1; done
REDUCED="${LAB_REDUCED:-0}"

# ---------------------------------------------------------------------------
# The image tag the chart deploys. Written by images.sh at publish time so the
# two cannot disagree about which build is current.
# ---------------------------------------------------------------------------
current_tag() {
  if [[ -r "${LAB_RESULTS_DIR}/current-image-tag" ]]; then
    cat "${LAB_RESULTS_DIR}/current-image-tag"
  else
    "${LAB_ROOT}/scripts/images.sh" tag
  fi
}

helm_args() {
  local tag; tag="$(current_tag)"
  printf '%s\0' \
    "--namespace" "${NS_APP}" \
    "--set" "global.imageTag=${tag}" \
    "--set" "global.imageRegistry=${LAB_REGISTRY_HOST_ADDR}/hydra" \
    "--set" "global.appNamespace=${NS_APP}" \
    "--set" "global.dataNamespace=${NS_DATA}" \
    "--set" "global.obsNamespace=${NS_OBS}" \
    "--set" "global.baseDomain=${LAB_BASE_DOMAIN}" \
    "--set" "postgres.image=${POSTGRES_IMAGE}" \
    "--set" "redis.image=${REDIS_IMAGE}" \
    "--set" "gateway.name=hydra-gateway" \
    "--set" "gateway.namespace=${NS_APP}"
}

run_helm() {   # run_helm <extra args...>
  local -a args=()
  while IFS= read -r -d '' a; do args+=("$a"); done < <(helm_args)
  if (( REDUCED )); then
    args+=("--values" "${CHART}/values-reduced.yaml")
  fi
  helm "$@" ${args[@]+"${args[@]}"}
}

# ===========================================================================
# secrets (T058) — generated at setup time, never tracked
# ===========================================================================
cmd_secrets() {
  log_suite "secrets"

  # Idempotent: an existing Secret is kept rather than rotated. Rotating the
  # JWT signing key on every setup would invalidate every token issued before
  # it, which turns a re-run of `make setup` into a silent logout — and would
  # make FR-047 ("every replica serves identical signing material") accidentally
  # true only within a single run.
  ensure_secret_generic() {
    local ns="$1" name="$2"; shift 2
    if $K -n "$ns" get secret "$name" >/dev/null 2>&1; then
      log_pass "secret ${name} already exists in ${ns}" "kept, not rotated"
      return 0
    fi
    if $K -n "$ns" create secret generic "$name" "$@" >/dev/null 2>&1; then
      log_pass "secret ${name} created in ${ns}" "generated at setup time, never tracked"
    else
      log_fail "could not create secret ${name} in ${ns}"
      return 1
    fi
  }

  # Datastore credentials. Random, per installation.
  local pg_password redis_password
  pg_password="$(openssl rand -base64 24 | tr -d '/+=' | head -c 24)"
  redis_password="$(openssl rand -base64 24 | tr -d '/+=' | head -c 24)"

  for ns in "${NS_DATA}" "${NS_APP}"; do
    # Both namespaces: the datastores read them, and so do the services and the
    # Jobs. A Secret does not cross a namespace boundary, and the alternative —
    # putting the workloads in one namespace — would collapse the topology the
    # network policy is written against.
    ensure_secret_generic "$ns" "hydra-postgres-credentials" \
      --from-literal=username=hydra \
      --from-literal=password="$pg_password"
    ensure_secret_generic "$ns" "hydra-redis-credentials" \
      --from-literal=password="$redis_password"
  done

  # The RSA signing key (FR-047). One key, one Secret, mounted by every
  # auth-service replica — which is what makes a token issued by one replica
  # verifiable against the key set published by any other, by construction
  # rather than by coincidence.
  if ! $K -n "${NS_APP}" get secret hydra-jwt-signing-key >/dev/null 2>&1; then
    local keyfile
    keyfile="$(mktemp)"
    # PKCS#8, unencrypted: LocalKeyProvider reads a PEM private key from a path.
    if openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$keyfile" >/dev/null 2>&1; then
      $K -n "${NS_APP}" create secret generic hydra-jwt-signing-key \
        --from-file=private-key.pem="$keyfile" >/dev/null 2>&1 \
        && log_pass "JWT signing key created" "one Secret, mounted by every replica (FR-047)" \
        || log_fail "could not create the JWT signing key Secret"
    else
      log_fail "could not generate an RSA signing key"
    fi
    # Removed immediately. The key exists in the cluster and nowhere else.
    rm -f "$keyfile"
  else
    log_pass "JWT signing key already exists" "kept, not rotated — rotating would invalidate every issued token"
  fi

  # FR-085, as an executed check rather than a promise.
  local leaked
  leaked="$(cd "${LAB_ROOT}" && git grep -lE "$(printf '%s' "$pg_password" | head -c 12)" -- . 2>/dev/null || true)"
  if [[ -z "$leaked" ]]; then
    log_pass "no generated secret value appears in the tracked tree" "git grep"
  else
    log_fail "a generated secret value is present in tracked files: ${leaked}"
  fi

  log_summary
}

# ===========================================================================
# backing-services — Postgres and Redis, before anything tries to migrate
# ===========================================================================
cmd_backing_services() {
  log_suite "backing services"
  cmd_secrets || { log_summary; return 1; }

  # The datastores are templates in the umbrella chart, so this installs the
  # chart with only them enabled — everything else waits for images to exist.
  #
  # THE SAME RELEASE NAME as the full deploy, deliberately. The first version
  # used a separate `${RELEASE}-data` release and it failed on the second
  # install with:
  #
  #   NetworkPolicy "default-deny" in namespace "hydra-app" exists and cannot
  #   be imported into the current release: invalid ownership metadata
  #
  # Two releases of one chart both claim the shared objects (NetworkPolicies,
  # PDBs, ServiceAccounts), and Helm's ownership annotations correctly refuse
  # the collision. One release upgraded in two steps is what Helm is built for:
  # this step brings up the datastores, and cmd_deploy upgrades the same release
  # with the real image tag and real replica counts.
  if run_helm upgrade --install "${RELEASE}" "${CHART}" \
       --set migration.enabled=false \
       --set fixture.enabled=false \
       --set autoscaling.enabled=false \
       --set global.imageTag=none-yet-datastores-only \
       --set-string 'auth.replicas=0' \
       --set-string 'order.replicas=0' \
       --wait --timeout "${TIMEOUT_WORKLOAD_READY}s" >/dev/null 2>&1; then
    log_pass "backing services installed" "helm upgrade --install ${RELEASE} (datastores only)"
  else
    log_fail "backing services install did not complete"
    log_context "$($K -n "${NS_DATA}" get pods,pvc 2>&1)"
    log_context "$($K -n "${NS_DATA}" describe pod -l app.kubernetes.io/component=datastore 2>&1 | tail -25)"
  fi
  log_summary
}

cmd_backing_services_check() {
  (( QUIET )) || log_suite "backing services check"

  local sts
  for sts in postgres redis; do
    local ready
    ready="$($K -n "${NS_DATA}" get statefulset "$sts" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)"
    if [[ "${ready:-0}" == "1" ]]; then
      log_pass "${sts} StatefulSet Ready" "kubectl get statefulset ${sts}"
    else
      log_fail "${sts} not Ready (${ready:-0}/1)"
      log_context "$($K -n "${NS_DATA}" get pods -l app.kubernetes.io/name="$sts" -o wide 2>&1)"
      log_context "$($K -n "${NS_DATA}" logs "statefulset/${sts}" --tail=25 2>&1 || true)"
    fi
  done

  # The probes, run directly. `Ready` is the kubelet repeating what the probe
  # told it; running the probe here is a second, independent observation — and
  # the one that catches a probe which passes for the wrong reason.
  if $K -n "${NS_DATA}" exec statefulset/postgres -- \
       sh -c 'pg_isready -U "$POSTGRES_USER" -d postgres -h 127.0.0.1' >/dev/null 2>&1; then
    log_pass "postgres accepts connections" "pg_isready, executed"
  else
    log_fail "postgres does not accept connections" "pg_isready"
  fi

  if $K -n "${NS_DATA}" exec statefulset/redis -- \
       sh -c 'redis-cli -a "$REDIS_PASSWORD" --no-auth-warning ping' 2>/dev/null | grep -q PONG; then
    log_pass "redis answers an authenticated PING" "redis-cli ping, executed"
  else
    log_fail "redis does not answer an authenticated PING"
    log_context "A plain PING returning NOAUTH is a *response*, so a naive port check would pass here."
  fi

  # Both databases must exist before the migration Job runs, or Hibernate
  # creates its tables in `postgres` and the failure surfaces three steps later.
  local db
  for db in "auth_db" "order_db"; do
    if $K -n "${NS_DATA}" exec statefulset/postgres -- \
         sh -c "psql -U \"\$POSTGRES_USER\" -lqt | cut -d'|' -f1 | grep -qw ${db}" >/dev/null 2>&1; then
      log_pass "database ${db} exists" "psql -l"
    else
      log_fail "database ${db} does not exist"
      log_context "The init ConfigMap creates both on first initialisation of an empty data directory."
    fi
  done

  log_summary
}

# ===========================================================================
# migrate / fixture / deploy
# ===========================================================================
cmd_migrate() {
  log_suite "migrate"
  # The migration Jobs are Helm pre-install hooks, so they run as part of the
  # main chart install in cmd_deploy. Running them here as well would apply the
  # schema twice — harmless, but it would also mean the `migrate` checkpoint
  # reported on a different execution than the one the deployment used.
  #
  # So this checkpoint's ACTION is deliberately empty and its VALIDATION is what
  # matters: the schema exists and is the shape the replicas will validate
  # against. That ordering is enforced by cmd_deploy, which does not report
  # success until both Jobs have completed.
  log_info "schema is authored by the chart's pre-install hook Jobs (D6); this checkpoint validates the result"
  cmd_deploy_chart || { log_summary; return 1; }
  log_summary
}

cmd_migrate_check() {
  (( QUIET )) || log_suite "migrate check"

  local job
  for job in hydra-migrate-auth hydra-migrate-order; do
    local complete
    complete="$($K -n "${NS_APP}" get job "$job" \
      -o jsonpath='{.status.conditions[?(@.type=="Complete")].status}' 2>/dev/null || true)"
    if [[ "$complete" == "True" ]]; then
      log_pass "${job} completed" "status.conditions[Complete]"
    else
      log_fail "${job} did not complete"
      log_context "$($K -n "${NS_APP}" logs "job/${job}" --tail=40 2>&1 || true)"
    fi
  done

  # The schema itself. A completed Job is evidence the process exited zero; the
  # tables are evidence it did what it exists to do.
  local t
  for t in tenants users user_roles; do
    if $K -n "${NS_DATA}" exec statefulset/postgres -- \
         sh -c "psql -U \"\$POSTGRES_USER\" -d ${LAB_AUTH_DB:-auth_db} -Atc \"SELECT to_regclass('public.${t}')\"" 2>/dev/null | grep -qw "$t"; then
      log_pass "table ${t} exists in auth_db" "SELECT to_regclass"
    else
      log_fail "table ${t} does not exist in auth_db"
      log_context "The Job completed but the schema is absent — check its logs for a Hibernate error."
    fi
  done

  log_summary
}

cmd_fixture() {
  log_suite "fixture"
  log_info "tenants and users are seeded by the chart's post-install hook Job (D7)"
  log_info "the Job ends by performing a REAL SIGN-IN and fails if the credential is rejected"
  log_summary
}

cmd_fixture_check() {
  (( QUIET )) || log_suite "fixture check"

  if ! wait_for_job "${NS_APP}" hydra-fixture "${TIMEOUT_JOB_COMPLETE}"; then
    log_fail "fixture Job did not complete"
    log_context "$($K -n "${NS_APP}" logs job/hydra-fixture --tail=40 2>&1 || true)"
    log_summary; return 1
  fi
  log_pass "fixture Job completed" "status.conditions[Complete]"

  # The Job's own guard already proved a sign-in works. This re-reads the rows
  # so a failure here distinguishes "seed missing" from "seed present but
  # unusable" — two different problems with two different fixes.
  local tenants
  tenants="$($K -n "${NS_DATA}" exec statefulset/postgres -- \
    sh -c "psql -U \"\$POSTGRES_USER\" -d auth_db -Atc \"SELECT string_agg(url_identifier, ',' ORDER BY url_identifier) FROM tenants\"" 2>/dev/null | tr -d '\r')"
  if [[ "$tenants" == *"${LAB_PRIMARY_TENANT}"* && "$tenants" == *"${LAB_SECOND_TENANT}"* ]]; then
    log_pass "tenants seeded: ${tenants}" "matches EdgeConformanceFixture's constants (research.md A7)"
  else
    log_fail "expected ${LAB_PRIMARY_TENANT} and ${LAB_SECOND_TENANT}, found: ${tenants:-<none>}"
  fi

  # gamma must NOT be here. SC-007 adds it later, against a running gateway, to
  # demonstrate that a new tenant needs no gateway change. Seeding it now would
  # quietly destroy that test.
  if [[ "$tenants" != *"${LAB_LATE_TENANT}"* ]]; then
    log_pass "${LAB_LATE_TENANT} is deliberately absent" "SC-007 adds it after the gateway is programmed"
  else
    log_fail "${LAB_LATE_TENANT} was seeded up front, which destroys the SC-007 demonstration"
  fi

  log_summary
}

# Install the full chart. Shared by migrate and deploy so the hooks run once.
cmd_deploy_chart() {
  local tag; tag="$(current_tag)"

  # A release left in `pending-install` / `pending-upgrade` blocks every later
  # attempt with "another operation (install/upgrade/rollback) is in progress",
  # which names a concurrent operation that is usually long gone — the real
  # cause is an interrupted run. Detecting it here turns a confusing message
  # into an actionable one.
  local status
  status="$(helm -n "${NS_APP}" status "${RELEASE}" -o json 2>/dev/null | jq -r '.info.status // empty' 2>/dev/null || true)"
  case "$status" in
    pending-*)
      log_fail "helm release '${RELEASE}' is stuck in '${status}'" "an earlier run was interrupted"
      log_info "This blocks every subsequent upgrade. Recover with:"
      log_info "    helm -n ${NS_APP} rollback ${RELEASE}     # to the last completed revision"
      log_info "    helm -n ${NS_APP} history ${RELEASE}      # to see what that was"
      return 1
      ;;
  esac
  log_info "deploying image tag ${tag}"
  if [[ "$tag" == *-dirty ]]; then
    log_info "NOTE: -dirty tag. Fine for an inner loop; not reproducible, so no recorded result should rest on it."
  fi

  # --reset-values is load-bearing, not hygiene.
  #
  # The backing-services phase installs this same release with
  # `--set auth.replicas=0 --set order.replicas=0` so the datastores can come up
  # before anything tries to migrate. Helm PERSISTS values supplied with --set
  # into the release, and a later `helm upgrade` that does not reset them
  # inherits them — so the full deploy silently kept both services at ZERO
  # replicas while every checkpoint reported success, because 0 desired and 0
  # ready are equal.
  #
  # The visible symptom was three layers away: Services with no endpoints, and a
  # gateway returning 503 for every request.
  if run_helm upgrade --install "${RELEASE}" "${CHART}" \
       --reset-values \
       --wait --timeout "${TIMEOUT_JOB_COMPLETE}s" 2>&1; then
    log_pass "chart installed" "helm upgrade --install ${RELEASE}"
    return 0
  fi
  log_fail "chart install did not complete"
  log_context "$($K -n "${NS_APP}" get pods,jobs -o wide 2>&1)"
  log_context "$($K -n "${NS_APP}" get events --sort-by=.lastTimestamp 2>&1 | tail -20)"
  return 1
}

cmd_deploy() {
  log_suite "app deploy"
  cmd_deploy_chart || { log_summary; return 1; }

  # FR-052 / FR-052a, enforced rather than hoped for: no pod accepts traffic
  # until BOTH Jobs are done. Helm's --wait covers the hooks; this is the
  # explicit assertion, because "the hook ran" and "the schema is there" are
  # different claims.
  local job
  for job in hydra-migrate-auth hydra-migrate-order; do
    wait_for_job "${NS_APP}" "$job" "${TIMEOUT_JOB_COMPLETE}" \
      && log_pass "${job} completed before any replica started" "FR-052" \
      || log_fail "${job} did not complete"
  done

  local d
  for d in auth-service order-service; do
    wait_for_rollout "${NS_APP}" "deploy/${d}" "${TIMEOUT_WORKLOAD_READY}" \
      && log_pass "${d} rolled out" "kubectl rollout status" \
      || log_fail "${d} did not roll out"
  done

  log_summary
}

cmd_status() {
  (( QUIET )) || log_suite "app status"

  local d
  for d in auth-service order-service; do
    local desired ready restarts
    desired="$($K -n "${NS_APP}" get deploy "$d" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 0)"
    ready="$($K -n "${NS_APP}" get deploy "$d" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)"
    restarts="$($K -n "${NS_APP}" get pods -l app.kubernetes.io/name="$d" \
      -o jsonpath='{range .items[*]}{.status.containerStatuses[0].restartCount}{" "}{end}' 2>/dev/null || true)"

    if [[ "${ready:-0}" == "${desired:-0}" && "${desired:-0}" != "0" ]]; then
      log_pass "${d}: ${ready}/${desired} Ready" "restarts: ${restarts:-0}"
    else
      log_fail "${d}: ${ready:-0}/${desired:-0} Ready"
      log_context "$($K -n "${NS_APP}" get pods -l app.kubernetes.io/name="$d" -o wide 2>&1)"
      log_context "$($K -n "${NS_APP}" describe pods -l app.kubernetes.io/name="$d" 2>&1 | grep -A6 'Events:' | tail -20)"
    fi

    # A restart count above zero is not automatically a failure — a drill may
    # have caused it — but it is never noise, so it is always surfaced.
    local total=0 r
    for r in ${restarts:-}; do total=$(( total + r )); done
    (( total > 0 )) && log_info "${d} has ${total} container restart(s); check whether a drill explains them"
  done

  (( QUIET )) || {
    printf '\nPods:\n';   $K -n "${NS_APP}" get pods -o wide 2>&1
    printf '\nRoutes:\n'; $K -n "${NS_APP}" get httproute 2>&1
    printf '\nHPAs:\n';   $K -n "${NS_APP}" get hpa 2>&1
  }

  log_summary
}

case "${1:-status}" in
  secrets)                 cmd_secrets ;;
  backing-services)        cmd_backing_services ;;
  backing-services-check)  cmd_backing_services_check ;;
  migrate)                 cmd_migrate ;;
  migrate-check)           cmd_migrate_check ;;
  fixture)                 cmd_fixture ;;
  fixture-check)           cmd_fixture_check ;;
  deploy)                  cmd_deploy ;;
  status)                  cmd_status ;;
  *) log_error "usage: app.sh {secrets|backing-services|migrate|fixture|deploy|status|*-check}"; exit 2 ;;
esac
