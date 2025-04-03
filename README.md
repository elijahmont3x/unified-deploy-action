# Unified Deployment System (UDS)

A comprehensive deployment system with SSL, dynamic routing, and plugin support.

## Overview

UDS is a flexible deployment system that allows you to easily deploy and manage applications on your servers. It supports:

- SSL certificate management with wildcard support
- Dynamic routing with path and subdomain options
- Advanced health checks with auto-detection and intelligent retry logic
- Plugin system for extending functionality
- Multi-stage deployments with validation
- Version tracking and rollback capabilities
- Security hardening and secure credentials handling
- Intelligent port conflict resolution

## Installation

```bash
# Clone the repository
git clone https://github.com/elijahmont3x/unified-deploy-action.git
cd unified-deploy-action

# Make scripts executable
chmod +x scripts/*.sh

# Initial setup with dependencies
./scripts/uds-setup.sh --config=examples/setup-config.json --install-deps --check-system
```

## Usage

### Basic Deployment

```bash
./scripts/uds-deploy.sh --config=path/to/config.json
```

### Multi-Stage Deployment

Multi-stage deployment provides additional safety by validating dependencies, creating a staging environment, and performing health checks before cutover:

```bash
./scripts/uds-deploy.sh --config=path/to/config.json --multi-stage --check-dependencies
```

### Enhanced Security

Enable enhanced security mode for additional protection:

```bash
./scripts/uds-setup.sh --config=path/to/config.json --secure-mode
```

### Cleanup

```bash
./scripts/uds-cleanup.sh --config=path/to/config.json
```

To preserve data when cleaning up:

```bash
./scripts/uds-cleanup.sh --config=path/to/config.json --keep-data
```

## Configuration

Create a configuration file like this:

```json
{
  "app_name": "my-app",
  "image": "nginx",
  "tag": "latest",
  "domain": "example.com",
  "route_type": "path",
  "route": "myapp",
  "port": "8080",
  "ssl": true,
  "ssl_email": "admin@example.com",
  "ssl_wildcard": false,
  "health_check": "/health",
  "health_check_type": "auto",
  "port_auto_assign": true,
  "env_vars": {
    "NODE_ENV": "production"
  },
  "plugins": "ssl-manager,telegram-notifier"
}
```

For a complete reference of all configuration options, see the [Configuration Reference](docs/configuration.md).

## Documentation

### Core Documentation
- [Architecture Guide](docs/architecture.md) - How UDS works and its design principles
- [Configuration Reference](docs/configuration.md) - Complete reference for all config options
- [API Reference](docs/api-reference.md) - Function reference for scripting and development
- [Plugin Development Guide](docs/plugin-development.md) - Creating custom plugins

### Usage Guides
- [GitHub Actions Guide](docs/github-actions.md) - Using UDS with GitHub Actions
- [Workflow Patterns](docs/workflow-patterns.md) - Common deployment patterns
- [Monitoring Integration Guide](docs/monitoring.md) - Integrating with monitoring tools
- [Security Best Practices](docs/security.md) - Security recommendations
- [Troubleshooting Guide](docs/troubleshooting.md) - Solving common issues

### Examples
Our [examples directory](examples/) contains ready-to-use workflow templates for:
- Basic single-service deployment
- Monorepo multi-service deployment
- Advanced staging-to-production pipeline
- Robust production deployment with dependencies

## Plugins

UDS supports a modular plugin system:

- **SSL Manager**: Manages SSL certificates, including wildcard certs
- **Route Manager**: Handles routing configuration and Nginx setup
- **Persistence Manager**: Manages persistent services like databases
- **Postgres Manager**: Handles PostgreSQL migrations and backups
- **Telegram Notifier**: Sends deployment notifications via Telegram
- **Security Manager**: Implements additional security measures

## GitHub Actions Integration

UDS provides a Docker-based GitHub Action for seamless integration with CI/CD pipelines. The action runs in its own container, ensuring consistency and isolation.

Example usage:
```yaml
- name: Deploy with UDS
  uses: elijahmont3x/unified-deploy-action@master
  with:
    command: deploy
    app-name: my-app
    image: nginx
    tag: latest
    domain: example.com
    host: ${{ secrets.DEPLOY_HOST }}
    username: ${{ secrets.DEPLOY_USER }}
    ssh-key: ${{ secrets.DEPLOY_SSH_KEY }}
```

For detailed GitHub Actions usage, see our [GitHub Actions Guide](docs/github-actions.md) and [example workflows](examples/).

## License

MIT