#!/usr/bin/env bash
# Proof that the drift classifier in pipelines-drift-detection.yml reaches the
# right verdict on real-shaped plans, by running the shipped step block itself.
#
# Until v1.4.4 the step counted with `grep -c … || echo 0`. grep -c prints 0
# AND exits 1 when nothing matches, so the fallback appended a second 0 and
# TOTAL=$((ADD + …)) died with "syntax error in expression (error token is
# 0)". Any drifted unit missing one of the four change kinds failed the step,
# so the scheduled drift run was red from 2026-07-27 whether or not anything
# had drifted (lightwave-infrastructure-live#145, hiding #93).
#
# The block is read out of the workflow with yq, so the test cannot pass on a
# copy that has drifted from what consumers run. Its inputs come from env
# (PLAN_EXIT, PLAN_FILE, UNIT_PATH) and its verdict goes to $GITHUB_OUTPUT.
#
# Exit: 0 when every fixture classifies as expected, 1 otherwise.

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
WORKFLOW=.github/workflows/pipelines-drift-detection.yml
fail=0
problem() { echo "FAIL: $1"; fail=1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
yq '.jobs[].steps[] | select(.id == "classify") | .run' "$WORKFLOW" > "$TMP/classify.sh"
[ -s "$TMP/classify.sh" ] || { echo "FAIL: no step with id classify in $WORKFLOW"; exit 1; }
if grep -q '\${{' "$TMP/classify.sh"; then
  problem "the classify block still interpolates \${{ }}; inputs must come from env so this test runs the shipped code"
fi

# A plan line the way terragrunt prints it in CI: timestamp, level, tofu
# prefix, ANSI colour around the resource header.
line() { printf '\033[0;90m06:12:01.123\033[0m INFO   \033[0;36mtofu: \033[0m%s\n' "$1"; }

# classify <name> <plan_exit> <fixture_file> -> fills $TMP/<name>.out
classify() {
  : > "$TMP/$1.out"
  if ! env -i PATH="$PATH" HOME="$HOME" PLAN_EXIT="$2" PLAN_FILE="$3" UNIT_PATH="prod/test/$1" \
      GITHUB_OUTPUT="$TMP/$1.out" bash -e -o pipefail "$TMP/classify.sh" > "$TMP/$1.log" 2>&1; then
    problem "$1: classify step failed: $(cat "$TMP/$1.log")"
  fi
  if grep -q 'syntax error' "$TMP/$1.log"; then problem "$1: arithmetic error: $(cat "$TMP/$1.log")"; fi
}

# expect <name> <key> <value>
expect() {
  local got
  got=$(sed -n "s/^$2=//p" "$TMP/$1.out" | tail -1)
  [ "$got" = "$3" ] || problem "$1: expected $2=$3, got '${got}'"
}

# (a) Known-good: no changes. The plan step reports exit 0.
{ line "No changes. Your infrastructure matches the configuration."; } > "$TMP/none.txt"
classify none 0 "$TMP/none.txt"
expect none drifted false
expect none severity none

# (b) Known-bad: one in-place update and nothing else. Fails on v1.4.3.
{
  line "  # cloudflare_dns_record.records[\"www\"] will be updated in-place"
  line "  ~ resource \"cloudflare_dns_record\" \"records\" {"
  line "      + include_shadow_metadata = false"
  line "    }"
  line "Plan: 0 to add, 1 to change, 0 to destroy."
} > "$TMP/one-update.txt"
classify one-update 2 "$TMP/one-update.txt"
expect one-update drifted true
expect one-update total_changes 1
expect one-update resources_change 1
expect one-update resources_add 0
expect one-update severity acceptable

# (c) A security resource in the change set classifies critical, even as an
#     in-place update with nothing destroyed.
{
  line "  # aws_iam_role.github_actions will be updated in-place"
  line "  ~ resource \"aws_iam_role\" \"github_actions\" {"
  line "Plan: 0 to add, 1 to change, 0 to destroy."
} > "$TMP/iam.txt"
classify iam 2 "$TMP/iam.txt"
expect iam drifted true
expect iam severity critical

# (d) A destroy of a non-security resource is high, and an IAM name appearing
#     only in plan text (not as a changed resource) does not make it critical.
{
  line "  # cloudflare_dns_record.apex will be destroyed"
  line "  - resource \"cloudflare_dns_record\" \"apex\" {"
  line "      - comment = \"trusts aws_iam_role.github_actions\""
  line "  # cloudflare_ruleset.redirect must be replaced"
  line "Plan: 1 to add, 0 to change, 2 to destroy."
} > "$TMP/destroy.txt"
classify destroy 2 "$TMP/destroy.txt"
expect destroy severity high
expect destroy resources_destroy 1
expect destroy resources_replace 1
expect destroy total_changes 2

# (e) A failed plan is an error, not drift.
classify errored 1 "$TMP/none.txt"
expect errored drifted false
expect errored severity error

if [ "$fail" -ne 0 ]; then exit 1; fi
echo "classify-drift-test: no-drift, single update, security, destroy and error plans all classify correctly."
