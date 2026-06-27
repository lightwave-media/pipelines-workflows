#!/usr/bin/env bash
# git-code-auth.sh
#
# Configures git URL rewrites so Terragrunt can fetch private modules from
# lightwave-media/lightwave-infrastructure-catalog without SSH keys.
#
# Env inputs:
#   INFRASTRUCTURE_CATALOG_TOKEN — GitHub PAT with read access to the catalog repo

set -euo pipefail

if [[ -z "${INFRASTRUCTURE_CATALOG_TOKEN:-}" ]]; then
  echo "::error::INFRASTRUCTURE_CATALOG_TOKEN is not set"
  exit 1
fi

TOKEN="${INFRASTRUCTURE_CATALOG_TOKEN}"

git config --global \
  url."https://oauth2:${TOKEN}@github.com/".insteadOf \
  "https://github.com/"

git config --global --add \
  url."https://oauth2:${TOKEN}@github.com/".insteadOf \
  "git@github.com:"

# go-getter normalizes scp-style to ssh:// before git runs
git config --global --add \
  url."https://oauth2:${TOKEN}@github.com/".insteadOf \
  "ssh://git@github.com/"

echo "✅ git URL rewrites configured for catalog module access"
