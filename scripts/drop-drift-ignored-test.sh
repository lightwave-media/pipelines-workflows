#!/usr/bin/env bash
# Proof that the drift workflow's "Drop units opted out of drift" step drops
# exactly the units with a `.drift-ignore` marker, logs each with its reason,
# passes every other unit through unchanged, and fails on a marker with no
# reason. The block is read out of the workflow with yq, so the test runs the
# shipped code (scripts here run from the consumer's checkout, so the step is
# inline rather than a copied script).
#
# Exit: 0 when every case holds, 1 otherwise.

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
WORKFLOW=.github/workflows/pipelines-drift-detection.yml
fail=0
problem() { echo "FAIL: $1"; fail=1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
yq '.jobs[].steps[] | select(.id == "drop-ignored") | .run' "$WORKFLOW" > "$TMP/drop.sh"
[ -s "$TMP/drop.sh" ] || { echo "FAIL: no step with id drop-ignored in $WORKFLOW"; exit 1; }
grep -q '\${{' "$TMP/drop.sh" && problem "the drop-ignored block interpolates \${{ }}; inputs must come from env"
[ "$(yq '.jobs.discover-units.outputs.units' "$WORKFLOW")" = '${{ steps.drop-ignored.outputs.units }}' ] ||
  problem "discover-units must output the filtered list, not the raw discovery"

WD="$TMP/wd"
mkdir -p "$WD/a" "$WD/b" "$WD/ignored" "$WD/blank"
printf '# retired from infra-live\nrepo retired from infra-live per #133\n' > "$WD/ignored/.drift-ignore"
printf '# only a comment\n\n' > "$WD/blank/.drift-ignore"

# run <name> <units json> -> $TMP/<name>.out (GITHUB_OUTPUT) and .log; returns the step's exit
run() {
  : > "$TMP/$1.out"
  (cd "$WD" && env -i PATH="$PATH" HOME="$HOME" UNITS="$2" GITHUB_OUTPUT="$TMP/$1.out" \
    bash -e -o pipefail "$TMP/drop.sh") > "$TMP/$1.log" 2>&1
}
units() { sed -n 's/^units=//p' "$TMP/$1.out"; }

run mixed '[{"id":"a","session":"a","path":"a"},{"id":"ignored","session":"ignored","path":"ignored"},{"id":"b","session":"b","path":"b"}]' ||
  problem "mixed: step failed: $(cat "$TMP/mixed.log")"
[ "$(units mixed | jq -c '[.[].path]')" = '["a","b"]' ] || problem "mixed: expected [a,b], got $(units mixed)"
[ "$(units mixed | jq -c '.[0]')" = '{"id":"a","session":"a","path":"a"}' ] || problem "mixed: kept units must pass through unchanged"
grep -q '::notice::Drift not checked for ignored: repo retired from infra-live per #133' "$TMP/mixed.log" ||
  problem "mixed: the dropped unit and its reason must be logged: $(cat "$TMP/mixed.log")"

run none '[{"id":"a","session":"a","path":"a"}]' || problem "none: step failed"
[ "$(units none)" = '[{"id":"a","session":"a","path":"a"}]' ] || problem "none: no markers must leave the list unchanged"

run empty '[]' || problem "empty: step failed"
[ "$(units empty)" = '[]' ] || problem "empty: an empty list stays empty"

if run blank '[{"id":"blank","session":"blank","path":"blank"}]'; then
  problem "blank: a marker with no reason must fail the step"
fi

if [ "$fail" -ne 0 ]; then exit 1; fi
echo "drop-drift-ignored-test: opt-outs dropped with their reason, others kept, unexplained opt-outs refused."
