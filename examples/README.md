# UDS GitHub Actions Workflow Examples

This directory contains example GitHub Actions workflows for different deployment scenarios using the Unified Deployment System.

## Available Examples

### 1. Basic Workflow (`basic-workflow.yml`)
A simple workflow for deploying a single application. Ideal for:
- Small projects
- Getting started with UDS
- Single container deployments

### 2. Monorepo Workflow (`monorepo-workflow.yml`) 
A workflow for deploying multiple applications from a monorepo structure. Best for:
- Projects with multiple components
- Selective deployments based on changed files
- Microservice architectures

### 3. Advanced Workflow (`advanced-workflow.yml`)
A complete CI/CD pipeline with staging and production environments. Includes:
- Security scanning with Trivy
- Multi-stage deployment
- Integration testing
- Automated release tagging
- Comprehensive notification system

### 4. Robust Workflow (`robust-workflow.yml`)
A production-ready workflow with additional reliability features:
- Database deployment with migrations
- Health checks with exponential backoff
- Dependency sequencing
- Intelligent service orchestration

## How to Use These Examples

1. Copy the appropriate example to your `.github/workflows/` directory
2. Customize the workflow for your specific needs (see [Customization](#customization) below)
3. Configure the required secrets in your GitHub repository settings

## Customization

These workflows are starting points - customize them based on your specific needs.
For detailed configuration options, see our [Configuration Reference](../docs/configuration.md).

```yaml
# Example customization
steps:
  - name: Deploy application
    uses: elijahmont3x/unified-deploy-action@master
    with:
      # Add your custom parameters here
      command: deploy
      app-name: my-custom-app
      # Add other settings specific to your needs
```

## Related Documentation

For more information on using UDS with GitHub Actions, see:

- [GitHub Actions Integration Guide](../docs/github-actions.md) - Detailed guide on using UDS with GitHub Actions
- [Configuration Reference](../docs/configuration.md) - Complete reference of all configuration options
- [Troubleshooting Guide](../docs/troubleshooting.md) - Solutions to common issues
- [UDS Architecture](../docs/architecture.md) - Understanding how UDS works
