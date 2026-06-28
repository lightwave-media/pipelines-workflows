#!/usr/bin/env bash
# find-changed-units.sh
#
# Emits a JSON array of Terragrunt units affected by the current change.
# Each element: {"id": "non-prod-us-east-1-vpc", "path": "non-prod/us-east-1/vpc"}
#
# Env inputs:
#   SOURCE_REF  — base ref to diff from (defaults: HEAD^ on main, origin/main on PR)
#   TARGET_REF  — head ref to diff to   (defaults: HEAD)
#   ROOT_DIR    — repo root (default: ".")
#
# Logic: git diff → each changed file → walk up to nearest dir with terragrunt.hcl
# (skipping .terragrunt-cache) → deduplicate → emit JSON matrix.

set -euo pipefail

ROOT_DIR="${ROOT_DIR:-.}"
TARGET_REF="${TARGET_REF:-HEAD}"

# Determine SOURCE_REF automatically if not set
if [[ -z "${SOURCE_REF:-}" ]]; then
  if [[ "${GITHUB_REF##*/}" == "main" ]]; then
    SOURCE_REF="HEAD^"
  else
    SOURCE_REF="origin/main"
  fi
fi

find_unit_for_file() {
  local file="$1"
  local dir
  dir="$(dirname "$file")"

  while [[ "$dir" != "." && "$dir" != "/" ]]; do
    # Skip terragrunt cache directories
    if [[ "$dir" == *".terragrunt-cache"* ]]; then
      return
    fi
    if [[ -f "${ROOT_DIR}/${dir}/terragrunt.hcl" ]]; then
      echo "$dir"
      return
    fi
    dir="$(dirname "$dir")"
  done
}

# Get changed files, find their owning unit, deduplicate, emit JSON.
# --relative makes git emit paths relative to the CURRENT directory (and limits
# the diff to it). Callers cd into working_directory before invoking this with
# ROOT_DIR="."; without --relative the repo-root-relative paths never resolve
# against cwd and no units are ever found.
git diff --relative --name-only "${SOURCE_REF}" "${TARGET_REF}" 2>/dev/null | \
  while IFS= read -r file; do
    find_unit_for_file "$file"
  done | \
  sort -u | \
  jq -R -s '
    split("\n")
    | map(select(. != ""))
    | map({
        id: (gsub("/"; "-")),
        path: .
      })
  '
