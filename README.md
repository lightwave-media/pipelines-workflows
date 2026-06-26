# Lightwave Pipelines Workflows

These two workflows contain the encapsulated logic for the lightwave Pipelines CI/CD system.

They are designed to integrate with the [lightwave media CLI](https://github.com/lightwave-media/lightwave-cli).

## Workflows

### [pipelines-root.yml](./.github/workflows/pipelines-root.yml)

This workflow handles the CI/CD for deploying updates to infrastructure managed by the v_devops `lightwave-infrastructure-live` repository.

### [pipelines-delegated.yml](./.github/workflows/pipelines-delegated.yml)

This workflow handles the CI/CD for deploying updates to infrastructure managed by all the other repositories vended as part of DevOps Foundations.

## Customization

Ask gateed approvel from v_infra-engineer.
