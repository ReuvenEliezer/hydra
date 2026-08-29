#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# maven.sh — locating the Maven that will run Hydra's existing test suite.
#
# This repository has no Maven wrapper (research.md A1) — `./mvnw` does not
# exist and never did. The image build no longer cares, because D2 replaced the
# wrapper stage with a pinned toolchain image. One path still needs a Maven on
# the workstation: `make test-edge-conformance`, which runs Hydra's *existing*
# suite in the host JVM so that no assertion has to be touched (SC-020).
#
# So this resolver looks in two places, in order:
#
#   1. `mvn` on PATH — the normal case.
#   2. A Maven distribution under ~/.m2/wrapper/dists/. Maven's own wrapper
#      downloads a full distribution there, and it commonly outlives the
#      wrapper script that fetched it. On a machine where someone once ran a
#      wrapper build, that distribution is a perfectly good Maven, and refusing
#      to see it would mean reporting "no Maven" on a host that has one.
#
# It never installs anything, and it never picks a distribution silently: the
# caller is told which Maven was chosen and where it came from.
# ---------------------------------------------------------------------------
set -uo pipefail

# lab_resolve_mvn — prints the path to a usable mvn, or nothing. Exit 0 if found.
lab_resolve_mvn() {
  if command -v mvn >/dev/null 2>&1; then
    command -v mvn
    return 0
  fi
  local candidate
  # Newest first, so a host with several distributions gets the most recent.
  for candidate in $(ls -t "${HOME}"/.m2/wrapper/dists/*/*/apache-maven-*/bin/mvn 2>/dev/null); do
    if [[ -x "$candidate" ]]; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  return 1
}

# lab_mvn_source — 'PATH' or 'wrapper-dist', for reporting.
lab_mvn_source() {
  command -v mvn >/dev/null 2>&1 && { printf 'PATH'; return 0; }
  lab_resolve_mvn >/dev/null 2>&1 && { printf 'wrapper-dist'; return 0; }
  printf 'none'
  return 1
}

# lab_mvn_java_major <mvn-path> — the Java major version Maven will actually
# use, asked of Maven rather than inferred from JAVA_HOME.
lab_mvn_java_major() {
  local mvn_bin="$1"
  "$mvn_bin" -version 2>/dev/null | sed -n 's/^Java version: \([0-9][0-9]*\).*/\1/p' | head -1
}
