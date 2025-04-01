# Unified Deployment System (UDS)

A comprehensive deployment system with SSL, dynamic routing, and plugin support.

## Overview

UDS is a flexible deployment system that allows you to easily deploy and manage applications on your servers. It supports:

- SSL certificate management with wildcard support
- Dynamic routing with path and subdomain options
- Advanced health checks with auto-detection
- Plugin system for extending functionality
- Multi-stage deployments with validation
- Version tracking and rollback capabilities
- Security hardening and secure credentials handling
- Intelligent port conflict resolution

## Installation

```bash
# Clone the repository
git clone https://github.com/elijahmont3x/unified-deployment-system.git
cd unified-deployment-system

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

### Key Configuration Options

| Option | Description |
|--------|-------------|
| `app_name` | The name of your application |
| `image` | Docker image to deploy (comma-separated for multiple containers) |
| `tag` | Docker image tag (default: latest) |
| `domain` | Primary domain for the application |
| `route_type` | Routing type: "path" or "subdomain" |
| `route` | Path or subdomain prefix |
| `port` | Container port(s) to expose (can use host:container format) |
| `ssl` | Enable SSL/TLS (true/false) |
| `ssl_email` | Email for Let's Encrypt registration |
| `ssl_wildcard` | Enable wildcard certificates (requires DNS validation) |
| `health_check` | Health check endpoint path |
| `health_check_type` | Health check type (auto, http, tcp, database, container, etc.) |
| `port_auto_assign` | Automatically resolve port conflicts |
| `plugins` | Comma-separated list of plugins to activate |

## Plugins

UDS supports a modular plugin system:

- **SSL Manager**: Manages SSL certificates, including wildcard certs
- **Route Manager**: Handles routing configuration and Nginx setup
- **Persistence Manager**: Manages persistent services like databases
- **Postgres Manager**: Handles PostgreSQL migrations and backups
- **Telegram Notifier**: Sends deployment notifications via Telegram
- **Security Manager**: Implements additional security measures

## Advanced Features

### Multi-Stage Deployment

Multi-stage deployment follows this process:
1. **Validation**: Checks dependencies and requirements
2. **Preparation**: Prepares configuration files and directories
3. **Deployment**: Deploys to a staging environment
4. **Cutover**: Swaps staging to production with minimal downtime
5. **Verification**: Performs health checks to verify deployment success

### Wildcard SSL Certificates

UDS supports wildcard SSL certificates:

```json
{
  "ssl": true,
  "ssl_email": "admin@example.com",
  "ssl_wildcard": true,
  "ssl_dns_provider": "cloudflare",
  "domain": "example.com"
}
```

This creates a certificate for `*.example.com` that works with all subdomains.

### Intelligent Port Management

UDS automatically handles port conflicts by:
1. Checking if configured ports are available
2. Finding alternative ports when conflicts occur
3. Supporting host:container port mapping format

## Monitoring Your Deployment

UDS provides deployment verification via advanced health checks, and you can integrate with:

- **Prometheus + Grafana**: For metrics collection and visualization
- **ELK Stack**: For aggregating and analyzing logs
- **Datadog/New Relic**: For APM and infrastructure monitoring

See our [monitoring integration guide](docs/monitoring.md) for detailed setup instructions.

## GitHub Actions Integration

UDS can be used in GitHub Actions workflows. See the `examples` directory for workflow examples.

## Documentation

- [Monitoring Integration Guide](docs/monitoring.md)
- [Plugin Development Guide](docs/plugin-development.md)
- [Configuration Reference](docs/configuration.md)
- [Security Best Practices](docs/security.md)

## License

MIT