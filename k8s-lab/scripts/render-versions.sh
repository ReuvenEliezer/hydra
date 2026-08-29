#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# render-versions.sh — renders versions.env into docs/versions.md (data-model §1).
#
# docs/versions.md is generated and must never be hand-edited: a human-edited
# copy of the matrix is precisely the drift between documentation and reality
# that FR-006 exists to prevent. The generated file says so in its own header,
# and `verify-versions.sh` fails if the rendering is stale.
# ---------------------------------------------------------------------------
set -euo pipefail

LAB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${LAB_ROOT}/docs/versions.md"
SRC="${LAB_ROOT}/versions.env"

{
  echo "# Version Matrix"
  echo
  echo "<!-- GENERATED FILE — do not edit."
  echo "     Source: k8s-lab/versions.env"
  echo "     Regenerate: k8s-lab/scripts/render-versions.sh"
  echo "     Edits here are overwritten and, worse, are invisible to every script,"
  echo "     because scripts read versions.env and never this file. -->"
  echo
  echo "Every version the lab pins, with what it was checked against. This file is"
  echo "generated from [\`versions.env\`](../versions.env), which is the authority."
  echo "\`make verify-versions\` asserts the two agree and that no moving reference"
  echo "exists outside a documented exception (SC-022)."
  echo
  echo "| Setting | Value | Compatibility basis |"
  echo "|---|---|---|"

  # A compatibility basis often runs across several comment lines. Continuation
  # lines are folded into one cell rather than truncated at the first, because a
  # half-sentence reason reads as complete and is worse than none.
  basis=""; exception=""; collecting=""
  while IFS= read -r line; do
    case "$line" in
      '# compatibility_basis:'*)
        basis="${line#*compatibility_basis: }"; collecting="basis" ;;
      '# exception:'*)
        exception="${line#*exception: }"; collecting="exception" ;;
      '#'*)
        stripped="${line#\#}"; stripped="${stripped# }"
        if [ -n "$collecting" ] && [ -n "$stripped" ]; then
          if [ "$collecting" = "basis" ]; then
            basis="${basis} ${stripped}"
          else
            exception="${exception} ${stripped}"
          fi
        else
          collecting=""
        fi ;;
      [A-Z_]*=*)
        key="${line%%=*}"; value="${line#*=}"
        note="${basis:-—}"
        [ -n "$exception" ] && note="${note} **(documented exception: ${exception})**"
        printf '| `%s` | `%s` | %s |\n' "$key" "$value" "$note"
        basis=""; exception=""; collecting="" ;;
      '')
        basis=""; exception=""; collecting="" ;;
    esac
  done < "$SRC"

  echo
  echo "## How to change a version"
  echo
  echo "1. Edit \`versions.env\` — the value **and** its \`# compatibility_basis:\` line."
  echo "2. Run \`k8s-lab/scripts/render-versions.sh\` to regenerate this file."
  echo "3. Run \`make verify-versions\`."
  echo "4. Run \`make validate-full\`. A version change that has not been executed"
  echo "   end to end has not been verified (FR-116)."
  echo
  echo "Never edit a script to change a version. If a script needs a value this"
  echo "matrix does not carry, the fix is a new matrix entry, not a literal."
} > "$OUT"

echo "rendered ${OUT} from ${SRC}"
