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

## Choosing the Right Workflow

- **Start Simple**: For new projects, begin with the basic workflow
- **Multiple Components**: Use the monorepo workflow when you have distinct applications in the same repository
- **Production Pipeline**: Use the advanced workflow when you need a full CI/CD pipeline with proper staging and testing

## Customization

These workflows are starting points - customize them based on your specific needs:

```yaml
# Example customization
steps:
  - name: Deploy application
    uses: your-org/unified-deployment-action@v1
    with:
      # Add your custom parameters here
      command: deploy
      app-name: my-custom-app
      # Add other settings specific to your needs
```
