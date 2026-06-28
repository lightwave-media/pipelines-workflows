#!/usr/bin/env bash
# find-all-units.sh
#
# Emits a JSON array of ALL Terragrunt units found under ROOT_DIR.
# Used by drift-detection to plan every unit regardless of git changes.
#
# Env inputs:
#   ROOT_DIR — where to search (default: ".")

set -euo pipefail

ROOT_DIR="${ROOT_DIR:-.}"

find "${ROOT_DIR}" -name "terragrunt.hcl" \
  -not -path "*/.terragrunt-cache/*" \
  -not -path "*/boilerplate/*" | \
  xargs -I{} dirname {} | \
  sed "s|^${ROOT_DIR}/||" | \
  sort -u | \
  jq -c -R -s '
    split("\n")
    | map(select(. != ""))
    | map({
        id: (gsub("/"; "-")),
        path: .
      })
  '
