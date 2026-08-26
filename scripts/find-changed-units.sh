#!/usr/bin/env bash
# find-changed-units.sh
#
# Emits a JSON array of Terragrunt units affected by the current change.
# Each element: {"id": "non-prod-us-east-1-vpc", "path": "non-prod/us-east-1/vpc"}
#
# Env inputs:
#   SOURCE_REF  — base ref to diff from (defaults: HEAD^ on main, origin/main on PR)
#   TARGET_REF  — head ref to diff to   (defaults: HEAD)
#
# Run from the working_directory you want to scan; only units under the cwd
# subtree are reported, with repo-root-relative paths.
#
# Note: there is intentionally no ROOT_DIR override — the unit root is resolved
# from `git rev-parse --show-toplevel` so probes work from any cwd. Don't re-add
# ROOT_DIR; it would reintroduce the cwd/path-mismatch bug this script fixes.
#
# Logic: git diff → each changed file → walk up to nearest dir with terragrunt.hcl
# (skipping .terragrunt-cache) → deduplicate → emit JSON matrix.

set -euo pipefail

TARGET_REF="${TARGET_REF:-HEAD}"

# Determine SOURCE_REF automatically if not set
if [[ -z "${SOURCE_REF:-}" ]]; then
  if [[ "${GITHUB_REF##*/}" == "main" ]]; then
    SOURCE_REF="HEAD^"
  else
    SOURCE_REF="origin/main"
  fi
fi

# Probe against the repo toplevel so it resolves no matter the cwd. git diff
# emits repo-root-relative paths, and the matrix `path` must stay repo-root-
# relative because the plan/apply step uses it directly as a working-directory.
REPO_ROOT="$(git rev-parse --show-toplevel)"

find_unit_for_file() {
  local file="$1"
  local dir
  dir="$(dirname "$file")"

  while [[ "$dir" != "." && "$dir" != "/" ]]; do
    # Skip terragrunt cache directories
    if [[ "$dir" == *".terragrunt-cache"* ]]; then
      return
    fi
    if [[ -f "${REPO_ROOT}/${dir}/terragrunt.hcl" ]]; then
      echo "$dir"
      return
    fi
    dir="$(dirname "$dir")"
  done
}

# Root-level HCL (root.hcl, any top-level *.hcl) is include()'d by every
# unit, so a change there affects all of them while living under none of
# them — the working_directory-scoped diff below cannot see it at all.
# Detect it with an UNSCOPED diff; on a hit, report every unit under the
# cwd subtree instead of the (empty) mapped set. Recovered from
# lightwave-infrastructure-live's retired detect-changes fix (7cd725f),
# re-implemented here because change detection now lives in the plane.
if git diff --name-only "${SOURCE_REF}" "${TARGET_REF}" 2>/dev/null | grep -qE '^[^/]+\.hcl$'; then
  echo "root-level HCL changed — reporting every unit under $(pwd)" >&2
  REL_PREFIX="$(git rev-parse --show-prefix)"
  find . -name "terragrunt.hcl" \
    -not -path "*/.terragrunt-cache/*" \
    -not -path "*/boilerplate/*" \
    -exec dirname {} \; | \
    sed -e "s|^\./||" -e "s|^|${REL_PREFIX}|" | \
    sort -u | \
    jq -c -R -s '
      split("\n")
      | map(select(. != ""))
      | map({
          id: (gsub("/"; "-")),
          path: .
        })
    '
  exit 0
fi

# Get changed files, find their owning unit, deduplicate, emit JSON.
# Callers cd into working_directory before invoking this; `-- .` limits the diff
# to that subtree (so plan-prod only sees prod/us-east-1, etc.) while git still
# prints repo-root-relative paths — exactly what the matrix needs. jq -c keeps
# the array on one line so `units=$UNITS` fits GITHUB_OUTPUT.
git diff --name-only "${SOURCE_REF}" "${TARGET_REF}" -- . 2>/dev/null | \
  while IFS= read -r file; do
    find_unit_for_file "$file"
  done | \
  sort -u | \
  jq -c -R -s '
    split("\n")
    | map(select(. != ""))
    | map({
        id: (gsub("/"; "-")),
        path: .
      })
  '
