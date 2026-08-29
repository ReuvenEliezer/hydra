#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# doctor.sh — `make doctor` (FR-001..FR-004, SC-002, data-model §3).
#
# Reports whether this host can run the lab, one line per check, then a single
# readiness statement. Exits non-zero if any *required* check failed.
#
# THE INSTALL-NOTHING GUARANTEE (FR-003), which is the whole point of this
# script: it installs nothing, modifies nothing, upgrades nothing, and writes
# nothing outside its own stdout. Not a package, not a config file, not a
# kubeconfig entry, not a docker network. It reports and it instructs. Every
# remedy below is a line for a human to run, never a line this script runs.
#
# That is testable, and it is tested: tests/smoke/doctor-seeded-failures.sh
# seeds each missing prerequisite, asserts the diagnostic names that specific
# tool, exits non-zero, and leaves no side effect behind (SC-002).
#
# WARN vs FAIL: WARN is used here and nowhere else in the lab. A host check can
# legitimately be "workable but not what we'd recommend" — 8 GB of RAM, an
# unusual architecture. A suite check cannot; see lib/log.sh.
# ---------------------------------------------------------------------------
set -uo pipefail

LAB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${LAB_ROOT}/scripts/lib/versions.sh"
source "${LAB_ROOT}/scripts/lib/log.sh"
source "${LAB_ROOT}/scripts/lib/maven.sh"

REQUIRED_FAILURES=0
fail_required() { log_fail "$1" "${2:-}"; REQUIRED_FAILURES=$((REQUIRED_FAILURES + 1)); }
remedy() { printf '        %s→ %s%s\n' "${_C_DIM}" "$*" "${_C_RESET}"; }

log_suite "doctor — host readiness for k8s-lab"
printf 'Nothing on this host will be installed, modified or upgraded by this command (FR-003).\n'

# Compares a semver-ish observed version against a required minimum. Returns 0
# if observed >= required. Tolerates a leading 'v' and trailing suffixes.
version_ge() {
  local observed="${1#v}" required="${2#v}"
  observed="${observed%%[^0-9.]*}"; required="${required%%[^0-9.]*}"
  [[ -z "$observed" ]] && return 1
  printf '%s\n%s\n' "$required" "$observed" | sort -V -C
}

# =========================================================================
# T015 — container CLI and container daemon, as two distinct findings.
# =========================================================================
# "docker: command not found" and "Cannot connect to the Docker daemon" are
# different problems with different fixes, and collapsing them into "Docker is
# not available" sends people to the wrong remedy. The spec's environmental
# edge case names this distinction explicitly.
log_section "container runtime"

CONTAINER_CLI=""
if command -v docker >/dev/null 2>&1; then
  CONTAINER_CLI="docker"
  log_pass "container CLI present" "$(command -v docker)"
elif command -v podman >/dev/null 2>&1; then
  CONTAINER_CLI="podman"
  log_warn "container CLI is podman, not docker" "$(command -v podman)"
  remedy "kind supports podman via KIND_EXPERIMENTAL_PROVIDER=podman, but this lab is verified on docker only."
else
  fail_required "container CLI is not installed" "neither docker nor podman on PATH"
  remedy "Install Docker Desktop (macOS) or Docker Engine (Linux), then re-run make doctor."
fi

if [[ -n "$CONTAINER_CLI" ]]; then
  if daemon_version="$("$CONTAINER_CLI" info --format '{{.ServerVersion}}' 2>/dev/null)" && [[ -n "$daemon_version" ]]; then
    log_pass "container daemon is running" "${CONTAINER_CLI} server ${daemon_version}"
  else
    fail_required "container CLI is installed but the daemon is not running" "${CONTAINER_CLI} info failed"
    remedy "Start Docker Desktop, or: sudo systemctl start docker"
    remedy "This is a different problem from 'not installed' — the CLI is present and working."
  fi
fi

# =========================================================================
# T016 — kind, kubectl, helm: presence AND version, compared against the
# version matrix rather than against a literal in this file.
# =========================================================================
log_section "kubernetes tooling"

check_tool() {
  local name="$1" required="$2" version_cmd="$3" install_hint="$4"
  if ! command -v "$name" >/dev/null 2>&1; then
    fail_required "${name} is not installed" "required ${required}"
    remedy "$install_hint"
    return 1
  fi
  local observed
  observed="$(eval "$version_cmd" 2>/dev/null | head -1 || true)"
  if [[ -z "$observed" ]]; then
    log_warn "${name} is installed but did not report a version" "$(command -v "$name")"
    return 0
  fi
  if version_ge "$observed" "$required"; then
    log_pass "${name} ${observed}" "required >= ${required} (versions.env)"
  else
    fail_required "${name} ${observed} is older than the pinned ${required}" "versions.env"
    remedy "$install_hint"
  fi
}

check_tool kind "${KIND_VERSION}" \
  "kind version | awk '{print \$2}'" \
  "brew install kind   (or see https://kind.sigs.k8s.io/docs/user/quick-start/#installation)"

# Deliberately not `-o json | jq`: the seeded-failure suite showed that a host
# without jq silently downgraded this check from FAIL to WARN, because the
# version probe produced nothing and "no version reported" is a softer verdict
# than "too old". A diagnostic whose findings depend on another optional tool
# reports on the wrong thing.
check_tool kubectl "${KUBECTL_VERSION}" \
  "kubectl version --client 2>/dev/null | sed -n 's/^Client Version: *//p'" \
  "brew install kubernetes-cli   (kubectl must be within one minor of ${KUBERNETES_VERSION})"

check_tool helm "${HELM_VERSION}" \
  "helm version --short | sed 's/+.*//'" \
  "brew install helm"

# =========================================================================
# T017 — the Java toolchain, and the question that actually matters:
# which Java will Maven use?
# =========================================================================
# The image build no longer depends on the host's Java at all (D2 pins a Maven
# toolchain image, which is what resolves research.md A1). The host's Java
# still matters for one thing: `make test-edge-conformance` runs Hydra's
# existing suite through the host's Maven. So both checks stay, and the second
# is the one people get wrong — `java -version` and "the JDK Maven runs on" are
# routinely different, and the failure surfaces as a compiler error that names
# neither.
log_section "java toolchain"

JAVA_REQUIRED_MAJOR=25

java_major_of() {   # extract the major version from a `java -version` blob
  sed -n 's/.*version "\([0-9][0-9]*\).*/\1/p' <<< "$1" | head -1
}

if command -v java >/dev/null 2>&1; then
  java_raw="$(java -version 2>&1 | head -1)"
  java_major="$(java_major_of "$java_raw")"
  if [[ -n "$java_major" ]] && (( java_major >= JAVA_REQUIRED_MAJOR )); then
    log_pass "java ${java_major}" "$(command -v java) — ${java_raw}"
  else
    log_warn "java ${java_major:-unknown} is below the project's Java ${JAVA_REQUIRED_MAJOR}" "$java_raw"
    remedy "Needed only for 'make test-edge-conformance'. The image build uses ${MAVEN_BUILDER_IMAGE} and ignores host Java."
  fi
else
  log_warn "java is not installed" "not on PATH"
  remedy "Needed only for 'make test-edge-conformance'. Everything else runs in containers."
fi

if MVN_BIN="$(lab_resolve_mvn)"; then
  mvn_src="$(lab_mvn_source)"
  if [[ "$mvn_src" == "wrapper-dist" ]]; then
    log_warn "maven is not on PATH, but a distribution was found" "${MVN_BIN}"
    remedy "This repository has no Maven wrapper (research.md A1); the distribution above is what the"
    remedy "conformance target will use. 'brew install maven' would make it a normal PATH lookup."
  fi
  # Ask Maven itself, rather than inferring from JAVA_HOME. Maven reports the
  # runtime it will actually use, which is the only answer worth having.
  mvn_java="$(lab_mvn_java_major "$MVN_BIN")"
  mvn_runtime="$("$MVN_BIN" -version 2>/dev/null | sed -n 's/^Java version:.*runtime: //p' | head -1)"
  if [[ -n "$mvn_java" ]] && (( mvn_java >= JAVA_REQUIRED_MAJOR )); then
    log_pass "maven will build with Java ${mvn_java}" "${mvn_runtime:-runtime not reported}"
  else
    log_warn "maven will build with Java ${mvn_java:-unknown}, not ${JAVA_REQUIRED_MAJOR}" "${mvn_runtime:-?}"
    remedy "export JAVA_HOME=\$(/usr/libexec/java_home -v ${JAVA_REQUIRED_MAJOR})   # macOS"
    remedy "This is the check that catches 'java -version says 25 but Maven compiles with 21'."
  fi
else
  log_warn "no maven found" "not on PATH and no distribution under ~/.m2/wrapper/dists"
  remedy "Needed only for 'make test-edge-conformance'. Note this repository has no Maven wrapper (research.md A1)."
fi

# =========================================================================
# T018 — CPU, memory, architecture, free ports, container storage.
# =========================================================================
log_section "host capacity"

CPU_MIN=4
MEM_MIN_GB=8
MEM_RECOMMENDED_GB=16

case "$(uname -s)" in
  Darwin)
    cpu_count="$(sysctl -n hw.ncpu 2>/dev/null || echo 0)"
    mem_bytes="$(sysctl -n hw.memsize 2>/dev/null || echo 0)"
    mem_gb=$(( mem_bytes / 1024 / 1024 / 1024 ))
    ;;
  Linux)
    cpu_count="$(nproc 2>/dev/null || echo 0)"
    mem_kb="$(awk '/MemTotal/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"
    mem_gb=$(( mem_kb / 1024 / 1024 ))
    ;;
  *)
    cpu_count=0; mem_gb=0 ;;
esac

if (( cpu_count >= CPU_MIN )); then
  log_pass "CPU cores: ${cpu_count}" "minimum ${CPU_MIN}"
else
  fail_required "CPU cores: ${cpu_count}" "minimum ${CPU_MIN}"
  remedy "A three-node cluster with six application pods will not schedule on fewer."
fi

if (( mem_gb >= MEM_RECOMMENDED_GB )); then
  log_pass "memory: ${mem_gb} GB" "recommended ${MEM_RECOMMENDED_GB} GB"
elif (( mem_gb >= MEM_MIN_GB )); then
  log_warn "memory: ${mem_gb} GB — below the ${MEM_RECOMMENDED_GB} GB recommendation"
  remedy "Use 'make setup-reduced'. It will print exactly which components it disables and which scenarios that makes unavailable (FR-091)."
else
  fail_required "memory: ${mem_gb} GB" "minimum ${MEM_MIN_GB} GB"
  remedy "Even reduced-footprint mode needs ${MEM_MIN_GB} GB."
fi

# The container runtime's own allocation is the number that actually binds on
# macOS: the host may have 64 GB while Docker Desktop is limited to 4.
if [[ "$CONTAINER_CLI" == "docker" ]] && docker info >/dev/null 2>&1; then
  docker_mem_bytes="$(docker info --format '{{.MemTotal}}' 2>/dev/null || echo 0)"
  docker_mem_gb=$(( docker_mem_bytes / 1024 / 1024 / 1024 ))
  docker_cpus="$(docker info --format '{{.NCPU}}' 2>/dev/null || echo 0)"
  if (( docker_mem_gb >= MEM_MIN_GB )); then
    log_pass "container runtime allocation: ${docker_cpus} CPU, ${docker_mem_gb} GB" "docker info"
  else
    fail_required "container runtime is limited to ${docker_mem_gb} GB" "docker info MemTotal"
    remedy "Docker Desktop → Settings → Resources → raise Memory to at least ${MEM_MIN_GB} GB."
    remedy "The host having more RAM does not help; this is the ceiling the cluster actually gets."
  fi
fi

arch="$(uname -m)"
case "$arch" in
  arm64|aarch64) log_pass "architecture: ${arch}" "verified on this platform" ;;
  x86_64|amd64)  log_pass "architecture: ${arch}" "verified on this platform" ;;
  *)             log_warn "architecture: ${arch} is not one this lab has been verified on" ;;
esac

case "$(uname -s)" in
  Darwin|Linux) log_pass "operating system: $(uname -s)" "supported" ;;
  *)
    fail_required "operating system: $(uname -s) is not supported" "macOS and Linux only"
    remedy "Native Windows is not a target. Use WSL2 with a Linux container runtime."
    ;;
esac

# Free ports. 443 is not negotiable — it is the one deterministic exposure
# mechanism (FR-030, D8), so a conflict is a required failure rather than a
# nudge to pick another port.
log_section "ports"
port_in_use() {
  if command -v lsof >/dev/null 2>&1; then
    lsof -nP -iTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1
  else
    netstat -an 2>/dev/null | grep -qE "[.:]$1[[:space:]]+.*LISTEN"
  fi
}
port_holder() {
  command -v lsof >/dev/null 2>&1 || { printf 'unknown (lsof unavailable)'; return; }
  lsof -nP -iTCP:"$1" -sTCP:LISTEN -F c 2>/dev/null | sed -n 's/^c//p' | sort -u | tr '\n' ' '
}

for spec in "443:required:HTTPS — the gateway's only exposure path" \
            "80:optional:HTTP — used by the redirect listener only" \
            "${REGISTRY_PORT}:required:the lab image registry"; do
  port="${spec%%:*}"; rest="${spec#*:}"; level="${rest%%:*}"; desc="${rest#*:}"
  if port_in_use "$port"; then
    holder="$(port_holder "$port")"
    if [[ "$level" == "required" ]]; then
      fail_required "port ${port} is in use — ${desc}" "held by: ${holder:-unknown}"
      remedy "Free port ${port}, or change the mapping in cluster/kind-cluster.yaml and versions.env."
    else
      log_warn "port ${port} is in use — ${desc}" "held by: ${holder:-unknown}"
    fi
  else
    log_pass "port ${port} is free" "${desc}"
  fi
done

# Container storage. kind node images, the two service images, the platform
# charts and the observability stack together need real headroom, and the
# failure when it runs out is an ImagePull error that reads like a registry
# problem.
log_section "container storage"
DISK_MIN_GB=25
if [[ "$CONTAINER_CLI" == "docker" ]] && docker info >/dev/null 2>&1; then
  # DockerRootDir is a path *inside* the daemon's filesystem. On Linux that is
  # also a host path and df answers directly. On macOS it is a path inside the
  # Docker Desktop VM, so df on the host reports the wrong volume or nothing at
  # all — the honest measurement there is the host volume backing the VM's disk
  # image, since that is what actually runs out.
  docker_root="$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || echo /)"
  measured_at=""
  avail_gb=""

  if [[ "$(uname -s)" == "Darwin" ]]; then
    for vm_data in "${HOME}/Library/Containers/com.docker.docker/Data" \
                   "${HOME}/.docker/desktop" \
                   "${HOME}"; do
      if [[ -d "$vm_data" ]]; then
        avail_gb="$(df -g "$vm_data" 2>/dev/null | awk 'NR==2 {print $4}')"
        measured_at="$vm_data"
        break
      fi
    done
  else
    avail_gb="$(df -BG "$docker_root" 2>/dev/null | awk 'NR==2 {gsub("G","",$4); print $4}')"
    measured_at="$docker_root"
  fi

  if [[ -n "$avail_gb" ]] && (( avail_gb >= DISK_MIN_GB )); then
    log_pass "container storage: ${avail_gb} GB available" "minimum ${DISK_MIN_GB} GB, measured at ${measured_at}"
  elif [[ -n "$avail_gb" ]]; then
    fail_required "container storage: ${avail_gb} GB available" "minimum ${DISK_MIN_GB} GB, measured at ${measured_at}"
    remedy "docker system df    # see what is using it"
    remedy "docker image prune  # reclaim, at your discretion — this script will not run it"
  else
    log_warn "container storage could not be measured" "no readable volume for ${docker_root}"
    remedy "Check manually: docker system df"
  fi
fi

# =========================================================================
# Supporting CLI tools the suites use directly.
# =========================================================================
log_section "suite tooling"
for tool in curl jq openssl git; do
  if command -v "$tool" >/dev/null 2>&1; then
    log_pass "${tool} present" "$(command -v "$tool")"
  else
    fail_required "${tool} is not installed" "used by the lab's Bash suites"
    remedy "brew install ${tool}"
  fi
done
if command -v keytool >/dev/null 2>&1; then
  log_pass "keytool present" "$(command -v keytool) — builds the PKCS#12 truststore (FR-032b)"
else
  log_warn "keytool is not installed" "part of a JDK"
  remedy "Without it certs.sh cannot write lab-truststore.p12, so 'make test-edge-conformance' cannot verify TLS."
fi

# =========================================================================
# T019 — the readiness statement and the exit code.
# =========================================================================
printf '\n'
printf -- '-----------------------------------------------------------\n'
printf '  %d passed   %d failed (required)   %d warnings\n' \
  "${LOG_PASS_COUNT}" "${REQUIRED_FAILURES}" "${LOG_WARN_COUNT}"
printf -- '-----------------------------------------------------------\n'

if (( REQUIRED_FAILURES > 0 )); then
  printf '%sENVIRONMENT NOT READY%s\n' "${_C_RED}" "${_C_RESET}"
  printf '\n%d required check(s) failed. Each FAIL above is followed by what to do about it.\n' "${REQUIRED_FAILURES}"
  printf 'Nothing has been installed or changed on this host.\n'
  exit 1
fi

printf '%sENVIRONMENT READY%s\n' "${_C_GREEN}" "${_C_RESET}"
if (( LOG_WARN_COUNT > 0 )); then
  printf '\n%d warning(s). The lab will run; read them before drawing conclusions from a benchmark.\n' "${LOG_WARN_COUNT}"
fi
printf '\nNext: make setup\n'
exit 0
