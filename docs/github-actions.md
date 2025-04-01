# GitHub Actions Integration with UDS

This guide explains how to use the UDS Docker-based GitHub Action for deployments.

## Overview

UDS now provides a Docker-based GitHub Action that handles:
1. Processing configuration locally in an isolated container
2. Deploying applications securely via SSH
3. Managing SSL, routing, and container lifecycles

## Basic Usage

```yaml
name: Deploy with UDS

on:
  push:
    branches: [main]

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

## Example Workflows

### Multi-Stage Deployment

```yaml
- name: Deploy to staging
  uses: elijahmont3x/unified-deploy-action@master
  with:
    command: deploy
    app-name: my-app-staging
    image: ghcr.io/myorg/myapp
    tag: ${{ github.sha }}
    domain: staging.example.com
    host: ${{ secrets.DEPLOY_HOST }}
    username: ${{ secrets.DEPLOY_USER }}
    ssh-key: ${{ secrets.DEPLOY_SSH_KEY }}

- name: Test staging
  run: |
    curl -f https://staging.example.com/health || exit 1

- name: Deploy to production
  uses: elijahmont3x/unified-deploy-action@master
  with:
    command: deploy
    app-name: my-app
    image: ghcr.io/myorg/myapp
    tag: ${{ github.sha }}
    domain: example.com
    host: ${{ secrets.DEPLOY_HOST }}
    username: ${{ secrets.DEPLOY_USER }}
    ssh-key: ${{ secrets.DEPLOY_SSH_KEY }}
```

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

## Implementation Details

The UDS GitHub Action is implemented as a Docker-based action that:

- Runs in an isolated Docker container
- Processes configuration locally before sending to remote servers
- Uses SSH for secure communication with deployment targets
- Maintains all functionality in a single, consistent environment

This design ensures reliability, security, and consistency across different environments.

## Configuration Options

UDS supports a wide range of configuration options. See the [configuration reference](configuration.md) for details.

## Troubleshooting

### Common Issues

1. **SSH Connection Failed**
   - Verify that your SSH key is correct
   - Ensure your server allows SSH connections

2. **Deployment Failed**
   - Check logs using `--log-level=debug`
   - Ensure Docker is installed on your deployment server

3. **SSL Certificate Issues**
   - Provide a valid email with `ssl-email`
   - Make sure your domain is correctly configured
