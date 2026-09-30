#!/usr/bin/env bash
# Proof that every OIDC role-session-name the plane builds fits AWS's limit.
#
# AWS rejects a session name over 64 characters. Built from the full unit id,
# "GitHubActions-PreApplyPlan-" + "prod-us-east-1-github-actions-oidc-platform"
# was 70, so infra-live's post-merge apply could not authenticate (2026-09-30).
# The matrix now carries `session`, the id capped at 37 characters, and every
# role-session-name must use it with a prefix of at most 27.
#
# Exit: 0 when every name fits and the producers emit a capped session, 1 otherwise.

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
SCRIPTS="$(pwd)/scripts"
MAX_SESSION=37
fail=0
problem() { echo "FAIL: $1"; fail=1; }

# --- every workflow uses the capped field, with a prefix that fits ----------
while IFS= read -r line; do
  case "$line" in
    *'matrix.unit.session }}"'*) ;;
    *) problem "not built from matrix.unit.session: $line"; continue ;;
  esac
  prefix=$(sed -nE 's/.*role-session-name: "([^$]*)\$\{\{.*/\1/p' <<<"$line")
  if [ $((${#prefix} + MAX_SESSION)) -gt 64 ]; then
    problem "prefix '${prefix}' (${#prefix}) + ${MAX_SESSION} exceeds 64: $line"
  fi
done < <(grep -rhE 'role-session-name:' .github/workflows/)

# --- the producers emit a capped session for a long unit path ---------------
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
long="prod/us-east-1/github-actions-oidc-platform"   # the unit that failed
longer="prod/us-east-1/a-unit-path-far-longer-than-any-session-name-allows"
git -C "$TMP" init -q
git -C "$TMP" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base
for p in "$long" "$longer"; do mkdir -p "$TMP/$p" && echo '# unit' > "$TMP/$p/terragrunt.hcl"; done
git -C "$TMP" add -A
git -C "$TMP" -c user.email=t@t -c user.name=t commit -q -m units

check_sessions() { # $1 = label, $2 = JSON matrix
  local n
  n=$(jq 'length' <<<"$2")
  [ "$n" -eq 2 ] || { problem "$1: expected 2 units, got $n"; return; }
  jq -r '.[] | "\(.session // "")\t\(.id)"' <<<"$2" | while IFS=$'\t' read -r s id; do
    [ -n "$s" ] || { echo "FAIL: $1: $id has no session"; exit 1; }
    [ "${#s}" -le "$MAX_SESSION" ] || { echo "FAIL: $1: session '$s' is ${#s} chars"; exit 1; }
    [[ "$s" =~ ^[A-Za-z0-9+=,.@_-]+$ ]] || { echo "FAIL: $1: session '$s' has invalid characters"; exit 1; }
    [[ "$id" == "$s"* ]] || { echo "FAIL: $1: session '$s' is not a prefix of id '$id'"; exit 1; }
  done || fail=1
}

check_sessions "find-all-units" "$(cd "$TMP" && ROOT_DIR="." bash "$SCRIPTS/find-all-units.sh")"
check_sessions "find-changed-units" "$(cd "$TMP" && SOURCE_REF=HEAD^ TARGET_REF=HEAD bash "$SCRIPTS/find-changed-units.sh")"

# The exact name that failed must now fit.
name="GitHubActions-PreApplyPlan-$(tr '/' '-' <<<"$long" | cut -c1-$MAX_SESSION)"
[ "${#name}" -le 64 ] || problem "PreApplyPlan name for $long is ${#name} chars"

if [ "$fail" -eq 0 ]; then
  echo "role-session-name-test: every session name fits AWS's 64-character limit."
fi
exit "$fail"
