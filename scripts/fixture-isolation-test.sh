#!/usr/bin/env bash
# Proof that the release-notes suite never writes into the git repo running it.
#
# git exports GIT_DIR and GIT_INDEX_FILE to its hooks, and neither `git -C
# <dir>` nor a child cwd outranks them, so a suite run under a hook (or from any
# shell that inherited them) builds its fixture in the repo that set them.
# `git config` also honours GIT_CONFIG, which git never exports but anything
# else can. Without the guard in scripts/test-release-notes.py the fixture
# wrote `Release Test <release-test@example.com>` into such a repo's config and
# committed and tagged onto its branch. The same class of leak left a fixture
# identity in lightwave-ai's shared .git/config for three months.
#
# So: seed a scratch "real" repo, run the suite with GIT_DIR, GIT_INDEX_FILE
# and GIT_CONFIG aimed at it, and assert its config, refs, worktrees and status
# come out exactly as they went in, and that the suite passed: a run that
# crashed before building anything would also leave it untouched.
#
# Mirrors lightwave-ai#168 (scripts/fixture-isolation-test.sh) and
# lightwave-plugin#66 (fixtureGitEnv in lib/testing/host.ts).
#
# Exit: 0 when the scratch repo is untouched and the suite passed, 1 otherwise.

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

# This script's own git calls must not follow an inherited repo selector either.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_PREFIX GIT_COMMON_DIR \
  GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_CONFIG

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
REAL="$TMP/real"

# Everything a leaked fixture has been seen to change: config, refs, index.
snapshot() {
  cat "$REAL/.git/config"
  git -C "$REAL" for-each-ref --format='%(refname) %(objectname)'
  git -C "$REAL" worktree list --porcelain
  git -C "$REAL" status --porcelain 2>&1 || true
}

git init -q -b main "$REAL"
echo seed >"$REAL/seed.txt"
git -C "$REAL" add seed.txt
GIT_AUTHOR_NAME=seed GIT_AUTHOR_EMAIL=seed@lightwave.invalid \
  GIT_COMMITTER_NAME=seed GIT_COMMITTER_EMAIL=seed@lightwave.invalid \
  git -C "$REAL" -c commit.gpgsign=false commit -qm seed
snapshot >"$TMP/before"

failed=0
echo "▶ scripts/test-release-notes.py (hostile git env)"
if ! GIT_DIR="$REAL/.git" GIT_INDEX_FILE="$REAL/.git/index" GIT_CONFIG="$REAL/.git/config" \
  python3 scripts/test-release-notes.py </dev/null >"$TMP/run.log" 2>&1; then
  echo "  FAIL: the suite did not pass under the hostile env"
  tail -40 "$TMP/run.log"
  failed=1
fi

snapshot >"$TMP/after"
if ! diff -u "$TMP/before" "$TMP/after"; then
  echo "FAIL: the suite wrote into the repo running it (diff above: before -> after)"
  failed=1
fi

if [[ "$failed" -eq 0 ]]; then
  echo "✓ fixture isolation holds: the release-notes suite left the repo running it untouched"
fi
exit "$failed"
