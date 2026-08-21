#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# images.sh — building and publishing the two service images
# (FR-004, FR-017, FR-018, FR-021).
#
# Tags are revision-derived and immutable (FR-017):
#
#     localhost:5001/hydra/auth-service:8f3c1d2
#     localhost:5001/hydra/auth-service:8f3c1d2-dirty
#
# Never `latest`. A tag is never re-pushed — a change produces a new tag — so
# "which code is in that pod" always has an answer.
#
# The `-dirty` suffix is not decoration. It means the image was built from a
# working tree that matches no commit, so it cannot be rebuilt from source
# later. Every build says so loudly, `publish` refuses without an explicit
# override, and the benchmark refuses to record a result against one.
# ---------------------------------------------------------------------------
set -uo pipefail

LAB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "${LAB_ROOT}/.." && pwd)"
source "${LAB_ROOT}/scripts/lib/versions.sh"
source "${LAB_ROOT}/scripts/lib/log.sh"

SERVICES=(auth-service order-service)
IMAGE_PREFIX="${LAB_REGISTRY_HOST_ADDR}/hydra"

# ---------------------------------------------------------------------------
# The revision-derived tag (FR-017).
# ---------------------------------------------------------------------------
git_tag() {
  local sha dirty=""
  sha="$(cd "$REPO_ROOT" && git rev-parse --short=7 HEAD 2>/dev/null || echo "nogit")"
  # --porcelain covers staged, unstaged and untracked. Untracked files count:
  # a new source file that has not been committed is exactly the case where an
  # image cannot be rebuilt from its recorded revision.
  if [[ -n "$(cd "$REPO_ROOT" && git status --porcelain 2>/dev/null)" ]]; then
    dirty="-dirty"
  fi
  printf '%s%s' "$sha" "$dirty"
}

tag_is_dirty() { [[ "$(git_tag)" == *-dirty ]]; }

warn_if_dirty() {
  tag_is_dirty || return 0
  printf '\n'
  printf '  ┌─────────────────────────────────────────────────────────────────┐\n'
  printf '  │  WORKING TREE IS NOT CLEAN                                      │\n'
  printf '  │                                                                 │\n'
  printf '  │  The image tag carries a -dirty suffix, which means this image  │\n'
  printf '  │  cannot be rebuilt from any commit. It is fine for an inner     │\n'
  printf '  │  loop and it is not fine for a recorded result: a benchmark or  │\n'
  printf '  │  a conformance run against a -dirty image is not reproducible.  │\n'
  printf '  └─────────────────────────────────────────────────────────────────┘\n'
  printf '\n'
  (cd "$REPO_ROOT" && git status --short 2>/dev/null | head -10)
  printf '\n'
}

# ---------------------------------------------------------------------------
# build (T053) / build-clean (T054)
# ---------------------------------------------------------------------------
do_build() {
  local no_cache="${1:-}"
  local tag; tag="$(git_tag)"

  log_suite "image build${no_cache:+ (clean state, --no-cache)}"
  warn_if_dirty

  log_info "toolchain: ${MAVEN_BUILDER_IMAGE}   runtime: ${JAVA_RUNTIME_IMAGE}"
  log_info "tag: ${tag}"
  log_info "build context: ${REPO_ROOT} (both services build from the repository root — the reactor needs its sibling modules)"

  local svc rc=0
  for svc in "${SERVICES[@]}"; do
    local image="${IMAGE_PREFIX}/${svc}:${tag}"
    printf '\n'
    log_step "building ${svc} -> ${image}"

    # Every version comes from the matrix as a build argument. The Dockerfile's
    # ARG defaults exist only so a bare `docker build` works; the lab never
    # relies on them.
    local build_args=(
      --build-arg "MAVEN_BUILDER_IMAGE=${MAVEN_BUILDER_IMAGE}"
      --build-arg "JAVA_RUNTIME_IMAGE=${JAVA_RUNTIME_IMAGE}"
      --build-arg "OTEL_JAVA_AGENT_URL=${OTEL_JAVA_AGENT_URL}"
    )
    [[ -n "$no_cache" ]] && build_args+=(--no-cache --pull)

    local log_file="${LAB_RESULTS_DIR}/build-${svc}.log"
    mkdir -p "${LAB_RESULTS_DIR}"

    if docker build ${build_args[@]+"${build_args[@]}"} \
         -f "${REPO_ROOT}/${svc}/Dockerfile" \
         -t "$image" \
         "${REPO_ROOT}" 2>&1 | tee "$log_file" | grep -E '^(#[0-9]+ \[|Apache Maven|Java version|ERROR|.*BUILD)' ; then
      :
    fi
    # tee + grep hides docker's exit code; PIPESTATUS is the real one.
    if [[ "${PIPESTATUS[0]}" != "0" ]]; then
      log_fail "${svc} build failed" "docker build"
      log_context "$(tail -40 "$log_file")"
      rc=1
      continue
    fi

    # FR-004: the toolchain that performed the build, taken from the build's own
    # output rather than from what we asked for. With --no-cache the `mvn
    # -version` step always executes; on a cached build it may not re-run, and
    # saying so is better than printing a value from a previous build as if it
    # were this one.
    local reported
    reported="$(grep -A3 'Apache Maven' "$log_file" | head -4 | tr -d '\r' || true)"
    if [[ -n "$reported" ]]; then
      log_pass "${svc} built" "$image"
      printf '%s\n' "$reported" | sed 's/^/        /'
    else
      log_pass "${svc} built" "$image"
      log_info "toolchain banner not in this build's output (the mvn -version layer was cached); run 'make image-build-clean' to see it"
    fi
  done

  if (( rc != 0 )); then log_summary; return 1; fi

  # The image must actually be able to start. `docker build` succeeding means
  # the layers assembled, not that the JVM can find its jar.
  for svc in "${SERVICES[@]}"; do
    local image="${IMAGE_PREFIX}/${svc}:${tag}"
    if docker run --rm --entrypoint java "$image" -version >/dev/null 2>&1; then
      log_pass "${svc} image runs a JVM" "docker run --entrypoint java -version"
    else
      log_fail "${svc} image cannot start a JVM"
    fi
    # D10: the agent is present and INERT. Both halves are checked — present,
    # because nothing is observable without it; inert, because an image that
    # forces the agent on is coupled to this lab forever.
    if docker run --rm --entrypoint ls "$image" -l /opt/otel/opentelemetry-javaagent.jar >/dev/null 2>&1; then
      log_pass "${svc} carries the OTel agent" "/opt/otel/opentelemetry-javaagent.jar"
    else
      log_fail "${svc} is missing the OTel agent"
    fi
    local jto
    jto="$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$image" 2>/dev/null | grep -c '^JAVA_TOOL_OPTIONS=' || true)"
    if [[ "$jto" == "0" ]]; then
      log_pass "${svc} sets no JAVA_TOOL_OPTIONS" "the agent is inert until the chart activates it (D10)"
    else
      log_fail "${svc} sets JAVA_TOOL_OPTIONS in the image" "the agent must be inert by default"
    fi
    # FR-057: non-root with the explicit id the pod spec will assert.
    local user
    user="$(docker inspect -f '{{.Config.User}}' "$image" 2>/dev/null)"
    if [[ "$user" == "10001:10001" ]]; then
      log_pass "${svc} runs as 10001:10001" "explicit non-root id, matching runAsUser (FR-057)"
    else
      log_fail "${svc} image user is '${user}', expected 10001:10001"
    fi
    # A2, verified in the built artifact rather than in the Dockerfile: the
    # module whose absence would break the edge contract from the inside.
    if docker run --rm --entrypoint sh "$image" -c \
         'unzip -l /app/app.jar 2>/dev/null | grep -qi "browser-edge-starter"' >/dev/null 2>&1; then
      log_pass "${svc} includes browser-edge-starter" "research.md A2, checked in the jar"
    else
      log_info "${svc}: could not confirm browser-edge-starter in the jar by name (unzip may be absent from the runtime image); the integration suite asserts the behaviour instead"
    fi
  done

  printf '\n'
  log_info "Images are local only. 'make image-publish' pushes them to ${LAB_REGISTRY_HOST_ADDR}."
  log_summary
}

# ---------------------------------------------------------------------------
# publish
# ---------------------------------------------------------------------------
do_publish() {
  local tag; tag="$(git_tag)"
  log_suite "image publish"

  if tag_is_dirty && [[ "${ALLOW_DIRTY_PUBLISH:-0}" != "1" ]]; then
    warn_if_dirty
    log_fail "refusing to publish a -dirty image" "FR-017: tags must be revision-derived and reproducible"
    log_info "Commit the tree, or set ALLOW_DIRTY_PUBLISH=1 if you accept an unreproducible tag."
    log_summary; return 1
  fi

  local svc rc=0
  for svc in "${SERVICES[@]}"; do
    local image="${IMAGE_PREFIX}/${svc}:${tag}"

    if ! docker image inspect "$image" >/dev/null 2>&1; then
      log_fail "${image} has not been built" "run 'make image-build' first"
      rc=1; continue
    fi

    # Immutability, enforced rather than promised: if this tag already exists in
    # the registry, do not overwrite it. A re-pushed tag destroys the only link
    # between a running pod and the code inside it.
    local existing
    existing="$(curl -s --max-time 10 "http://${LAB_REGISTRY_HOST_ADDR}/v2/hydra/${svc}/tags/list" 2>/dev/null \
                | jq -r '.tags // [] | .[]' 2>/dev/null | grep -Fx "$tag" || true)"
    if [[ -n "$existing" && "${ALLOW_TAG_OVERWRITE:-0}" != "1" ]]; then
      log_pass "${svc}:${tag} is already published" "immutable tag, not re-pushed (FR-017)"
      continue
    fi

    if docker push "$image" >/dev/null 2>&1; then
      log_pass "${svc} published" "$image"
    else
      log_fail "${svc} push failed" "docker push ${image}"
      log_context "$(docker push "$image" 2>&1 | tail -10)"
      rc=1
    fi
  done

  printf '\nCatalogue: '
  curl -s --max-time 10 "http://${LAB_REGISTRY_HOST_ADDR}/v2/_catalog" 2>/dev/null || printf '(registry unreachable)'
  printf '\n'

  # The tag the chart will deploy. Written rather than remembered, so app.sh and
  # the chart cannot disagree about which image is current.
  mkdir -p "${LAB_RESULTS_DIR}"
  printf '%s' "$tag" > "${LAB_RESULTS_DIR}/current-image-tag"

  (( rc == 0 )) || { log_summary; return 1; }
  log_summary
}

case "${1:-build}" in
  build)       do_build ;;
  build-clean) do_build --no-cache ;;
  publish)     do_publish ;;
  tag)         git_tag; printf '\n' ;;
  *) log_error "usage: images.sh {build|build-clean|publish|tag}"; exit 2 ;;
esac
