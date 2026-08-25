# Lightwave Pipelines — the deterministic plane

The ONE repo of shared GitHub Actions workflows for every lightwave-media
repo: **releases**, **CI**, and **Terragrunt infrastructure**. If a repo runs
a shared workflow, it comes from here, pinned by SHA — there is no second
place to look. Contract: `policy/governance/release_pipeline.yaml` in
lightwave-core (the stamp; this repo is the print).

**Guarantees**

- Same tag in → same artifacts out. Consumers pin workflows by **full commit
  SHA** with a `# vX.Y.Z` comment; floating refs (`@main`, `@v1`) are
  forbidden.
- The tag IS the version. No release PRs, no version-bump commits, no
  committed changelogs — GitHub Releases (git-cliff, one org-wide config
  inlined in `release-core.yml`) are the canonical changelog.
- **CI parity**: `ci-mise.yml` runs the repo's own `mise run ci` — the exact
  command an agent runs locally, toolchains pinned by the repo's mise.toml.
  Local green means remote green.
- Failure is a red run on the tag, never silence. `release-core` refuses tags
  whose commit is not on the default branch.
- This repo releases itself through its own `release-only` path (dogfood) and
  gates itself with its own `ci-mise.yml`.

## Release workflows

Every repo owns exactly one `.github/workflows/release.yml`: a thin caller
(scaffold: `lw scaffold repo-release`) triggered by its tag grammar
(`v<semver>`, monorepos `<module>/v<semver>`), calling one of:

| Workflow | Artifact | Used by |
|---|---|---|
| `release-only.yml` | GitHub Release + notes only | lightwave-core, infra-catalog, lightwave-ai modules, lightwave-sys (Phase A), this repo |
| `release-node-package.yml` | npm → GitHub Packages | lightwave-ui |
| `release-go-binary.yml` | GoReleaser (+ homebrew-tap App token) | lightwave-cli |
| `release-container.yml` | ECR push + repo `mise run <deploy_task>` | lightwave-platform |
| `release-static-site.yml` | mise build → Cloudflare Pages | joelschaeffer-site |
| `release-tauri-app.yml` | Tauri bundles attached to the Release | createOS |

All six share `release-core.yml` (tag validation → git-cliff notes → GitHub
Release, keep-existing so artifact jobs attach). Every type supports
`dry_run` (everything but publish) and an optional `environment` input that
binds an approval-gate job to a GitHub Environment with required reviewers.

Releasing is one command:

```bash
git tag vX.Y.Z && git push origin vX.Y.Z   # or `lw release tag` once shipped
```

## CI workflows

| Workflow | What it does |
|---|---|
| `ci-mise.yml` | **The parity workflow**: checkout → mise (repo's mise.toml) → `mise run ci`. The target state for every repo. |
| `ci-node.yml` | Transitional — moved verbatim from the org `.github` repo. Consumers re-point here, then migrate steps into mise tasks and switch to `ci-mise.yml`. |

## Terragrunt workflows (unchanged)

Open-source replacements for Gruntwork Pipelines — `mise` for tooling, AWS
OIDC for auth, shell scripts for change detection. Consumed by
lightwave-infrastructure-live.

| Workflow | Trigger | What it does |
|---|---|---|
| `pipelines.yml` | PR | plan changed units in parallel, sticky comment per unit |
| `pipelines-root.yml` | push to main | plan → (Environment approval) → apply |
| `pipelines-drift-detection.yml` | schedule | plan every unit; open an issue on drift |
| `pipelines-unlock.yml` | manual | force-unlock state locks |

```yaml
# Consumption shape (all workflows):
jobs:
  plan:
    uses: lightwave-media/pipelines-workflows/.github/workflows/pipelines.yml@<full-SHA> # vX.Y.Z
    with:
      working_directory: non-prod/us-east-1
    secrets:
      INFRASTRUCTURE_CATALOG_TOKEN: ${{ secrets.INFRASTRUCTURE_CATALOG_TOKEN }}
      AWS_GITHUB_ACTIONS_ROLE_ARN: ${{ secrets.AWS_GITHUB_ACTIONS_ROLE_ARN }}
```

## Working on this repo

- Local gate = `mise run ci` (actionlint + shellcheck) — the same bytes the
  CI run executes, via this repo's own `ci-mise.yml`.
- Release a new plane version: `git tag vX.Y.Z && git push origin vX.Y.Z`,
  then bump consumers' SHA pins (`# vX.Y.Z` comment alongside).
- History: this repo began as the open-source rewrite of Gruntwork Pipelines
  (PR #1) and was commissioned as the org-wide release plane 2026-08-25
  (release-please retired org-wide; see release_pipeline.yaml for why).
