# GitHub Actions Integration with UDS

This guide explains how to use the UDS Docker-based GitHub Action for deployments.

## Overview

UDS provides a Docker-based GitHub Action that handles:
1. Processing configuration locally in an isolated container
2. Deploying applications securely via SSH
3. Managing SSL, routing, and container lifecycles

## Basic Usage

```yaml
name: Deploy with UDS

on:
  push:
    branches: [master]

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - name: Deploy application
        uses: elijahmont3x/unified-deploy-action@master
        with:
          command: deploy
          app-name: my-application
          image: nginx
          tag: latest
          domain: example.com
          route-type: path
          route: /my-app
          port: 80
          host: ${{ secrets.DEPLOY_HOST }}
          username: ${{ secrets.DEPLOY_USER }}
          ssh-key: ${{ secrets.DEPLOY_SSH_KEY }}
```

## Authentication

The action requires an SSH key for connecting to your deployment server:

```yaml
with:
  host: ${{ secrets.DEPLOY_HOST }}
  username: ${{ secrets.DEPLOY_USER }}
  ssh-key: ${{ secrets.DEPLOY_SSH_KEY }}
```

These secrets should be set in your GitHub repository settings.

## Commands

UDS supports the following commands:

- **deploy**: Deploy an application (default)
- **setup**: Set up the deployment environment
- **cleanup**: Remove deployed applications

## Workflow Patterns

UDS supports several workflow patterns to meet different deployment needs. Our [examples directory](../examples/) contains ready-to-use templates:

### [Basic Workflow](../examples/basic-workflow.yml)
Simple deployment flow for a single service.

### [Advanced Workflow](../examples/advanced-workflow.yml)
Multi-stage deployment with staging and production environments.

### [Monorepo Workflow](../examples/monorepo-workflow.yml)
Selective deployment of components in a monorepo structure.

### [Robust Workflow](../examples/robust-workflow.yml)
Production-grade deployment with dependencies, persistence, and extensive health checking.

For detailed explanations of these patterns, see the [Workflow Patterns Guide](workflow-patterns.md).

## Common Scenarios

### Using Plugins

```yaml
- name: Deploy with SSL and Telegram notifications
  uses: elijahmont3x/unified-deploy-action@master
  with:
    command: deploy
    app-name: my-app
    image: my-app-image
    domain: example.com
    plugins: ssl-manager,telegram-notifier
    telegram-enabled: 'true'
    telegram-bot-token: ${{ secrets.TELEGRAM_BOT_TOKEN }}
    telegram-chat-id: ${{ secrets.TELEGRAM_CHAT_ID }}
    host: ${{ secrets.DEPLOY_HOST }}
    username: ${{ secrets.DEPLOY_USER }}
    ssh-key: ${{ secrets.DEPLOY_SSH_KEY }}
```

### Deploying with Persistent Storage

```yaml
- name: Deploy database with persistence
  uses: elijahmont3x/unified-deploy-action@master
  with:
    command: deploy
    app-name: my-database
    image: postgres:13
    tag: latest
    domain: example.com
    port: 5432
    persistent: 'true'
    volumes: postgres-data:/var/lib/postgresql/data
    plugins: persistence-manager
    host: ${{ secrets.DEPLOY_HOST }}
    username: ${{ secrets.DEPLOY_USER }}
    ssh-key: ${{ secrets.DEPLOY_SSH_KEY }}
    env-vars: >
      {
        "POSTGRES_USER": "${{ secrets.DB_USER }}",
        "POSTGRES_PASSWORD": "${{ secrets.DB_PASSWORD }}",
        "POSTGRES_DB": "${{ secrets.DB_NAME }}"
      }
```

### Multi-Stage Deployment with Verification

```yaml
- name: Deploy with multi-stage and verification
  uses: elijahmont3x/unified-deploy-action@master
  with:
    command: deploy
    app-name: my-app
    image: my-app-image:${{ github.sha }}
    domain: example.com
    multi-stage: 'true'
    health-check: '/health'
    health-check-timeout: 120
    host: ${{ secrets.DEPLOY_HOST }}
    username: ${{ secrets.DEPLOY_USER }}
    ssh-key: ${{ secrets.DEPLOY_SSH_KEY }}
```

## Implementation Details

The UDS GitHub Action is implemented as a Docker-based action that:

- Runs in an isolated Docker container
- Processes configuration locally before sending to remote servers
- Uses SSH for secure communication with deployment targets
- Maintains all functionality in a single, consistent environment

This design ensures reliability, security, and consistency across different environments.

## Configuration Options

UDS supports a wide range of configuration options. See the [Configuration Reference](configuration.md) for details.

## Troubleshooting

### Common Issues

1. **SSH Connection Failed**
   - Verify that your SSH key is correct
   - Ensure your server allows SSH connections
   - Check that the user has appropriate permissions

2. **Deployment Failed**
   - Check logs using `--log-level=debug`
   - Ensure Docker is installed on your deployment server
   - Verify image exists and is accessible

3. **SSL Certificate Issues**
   - Provide a valid email with `ssl-email`
   - Make sure your domain is correctly configured
   - Check DNS settings for your domain

For more detailed troubleshooting, see the [Troubleshooting Guide](troubleshooting.md).
