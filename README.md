# Lightwave Pipelines Workflows

Reusable GitHub Actions workflows for Terragrunt CI/CD — no Gruntwork subscription required.

This library replaces Gruntwork Pipelines (which requires `pipelines-credentials`, a private
`pipelines-actions` repo, and the commercial `pipelines` CLI) with open-source equivalents:
`mise` for tooling, AWS OIDC for auth, and shell scripts for change detection.

## Workflows

### `pipelines.yml` — PR Plan

Called on every pull request. Detects which Terragrunt units changed, fans out one parallel
plan job per unit, and posts a sticky PR comment per unit with the plan output.

```yaml
# In your infra repo .github/workflows/terragrunt-plan.yml
jobs:
  plan:
    uses: lightwave-media/pipelines-workflows/.github/workflows/pipelines.yml@main
    with:
      working_directory: non-prod/us-east-1
    secrets:
      INFRASTRUCTURE_CATALOG_TOKEN: ${{ secrets.INFRASTRUCTURE_CATALOG_TOKEN }}
      AWS_GITHUB_ACTIONS_ROLE_ARN: ${{ secrets.AWS_GITHUB_ACTIONS_ROLE_ARN }}
```

### `pipelines-root.yml` — Push-to-Main Apply

Called on push to `main`. Plans each changed unit, waits for GitHub Environment approval
(configurable — use for prod gates), then applies in parallel.

```yaml
# In your infra repo .github/workflows/terragrunt-apply.yml
jobs:
  apply:
    uses: lightwave-media/pipelines-workflows/.github/workflows/pipelines-root.yml@main
    with:
      working_directory: prod/us-east-1
      environment: production   # GitHub Environment with required reviewers — omit for auto-apply
    secrets:
      INFRASTRUCTURE_CATALOG_TOKEN: ${{ secrets.INFRASTRUCTURE_CATALOG_TOKEN }}
      AWS_GITHUB_ACTIONS_ROLE_ARN: ${{ secrets.AWS_GITHUB_ACTIONS_ROLE_ARN }}
```

### `pipelines-drift-detection.yml` — Scheduled Drift Detection

Runs `terragrunt plan --detailed-exitcode` on every unit. Exit code 2 = drift.
Opens a GitHub issue listing drifted units (set `create_issue_on_drift: false` to disable).

```yaml
# In your infra repo .github/workflows/drift-detection.yml
on:
  schedule:
    - cron: '0 8 * * 1-5'   # weekdays at 8 AM UTC

jobs:
  drift:
    uses: lightwave-media/pipelines-workflows/.github/workflows/pipelines-drift-detection.yml@main
    with:
      working_directory: prod/us-east-1
    secrets:
      INFRASTRUCTURE_CATALOG_TOKEN: ${{ secrets.INFRASTRUCTURE_CATALOG_TOKEN }}
      AWS_GITHUB_ACTIONS_ROLE_ARN: ${{ secrets.AWS_GITHUB_ACTIONS_ROLE_ARN }}
```

### `pipelines-unlock.yml` — Force-Unlock State

Manual `workflow_dispatch` escape hatch. Unlocks a specific unit (provide `unit_path` +
`lock_id`) or every unit in the working directory.

```yaml
# In your infra repo .github/workflows/unlock.yml
on:
  workflow_dispatch:
    inputs:
      unit_path:
        description: "Unit to unlock (e.g. vpc). Leave empty for all units."
      lock_id:
        description: "Lock ID. Leave empty to auto-detect."

jobs:
  unlock:
    uses: lightwave-media/pipelines-workflows/.github/workflows/pipelines-unlock.yml@main
    with:
      working_directory: prod/us-east-1
      unit_path: ${{ inputs.unit_path }}
      lock_id: ${{ inputs.lock_id }}
    secrets:
      INFRASTRUCTURE_CATALOG_TOKEN: ${{ secrets.INFRASTRUCTURE_CATALOG_TOKEN }}
      AWS_GITHUB_ACTIONS_ROLE_ARN: ${{ secrets.AWS_GITHUB_ACTIONS_ROLE_ARN }}
```

## Inputs reference

All workflows share these common inputs:

| Input | Default | Description |
|---|---|---|
| `runner` | `"ubuntu-latest"` | JSON-encoded runner label |
| `working_directory` | _(required)_ | Repo-relative path to the Terragrunt env dir |
| `aws_region` | `us-east-1` | AWS region |
| `tg_bucket_prefix` | `lightwave-` | Prefix for Terragrunt S3 state buckets |
| `cloudflare_ssm_param` | `/lightwave/prod/CLOUDFLARE_API_TOKEN` | SSM path for Cloudflare token |

`pipelines-root.yml` adds:

| Input | Default | Description |
|---|---|---|
| `environment` | _(empty)_ | GitHub Environment name for approval gate; empty = auto-apply |

`pipelines-drift-detection.yml` adds:

| Input | Default | Description |
|---|---|---|
| `create_issue_on_drift` | `true` | Open a GitHub issue when drift is detected |

`pipelines-unlock.yml` adds:

| Input | Default | Description |
|---|---|---|
| `unit_path` | _(empty)_ | Single unit to unlock; empty = all units |
| `lock_id` | _(empty)_ | Lock ID to release; empty = auto-detect |

## Required secrets

| Secret | Description |
|---|---|
| `INFRASTRUCTURE_CATALOG_TOKEN` | GitHub PAT with read access to `lightwave-infrastructure-catalog` |
| `AWS_GITHUB_ACTIONS_ROLE_ARN` | ARN of the IAM role GitHub Actions assumes via OIDC |

## How it works

**Change detection** (`scripts/find-changed-units.sh`): `git diff` → for each changed file,
walk up directory tree until a `terragrunt.hcl` is found → deduplicate → emit JSON matrix
`[{id, path}]`. On `main` branch diffs `HEAD^..HEAD`; on PRs diffs `origin/main..HEAD`.

**Toolchain**: `jdx/mise-action` reads `mise.toml` from your infra repo root, which pins
`opentofu` and `terragrunt` versions.

**Auth**: `aws-actions/configure-aws-credentials` with OIDC (`id-token: write`). Cloudflare
API token is fetched from AWS SSM at runtime and masked immediately.

**Private modules**: `scripts/git-code-auth.sh` configures git URL rewrites so Terragrunt
can fetch modules from `lightwave-infrastructure-catalog` using the catalog PAT.
