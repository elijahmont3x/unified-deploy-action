# Unified Deployment System (UDS)

A comprehensive deployment system for GitHub Actions that simplifies deploying applications with SSL, dynamic routing, and persistent services. UDS offers an agnostic approach that makes zero assumptions about your projects while providing automated infrastructure management behind the scenes.

## Features

- **Zero-Config Deployments**: Deploy any application with minimal configuration
- **SSL Management**: Automatic certificate generation and renewal with Let's Encrypt
- **Dynamic Routing**: Support for both path-based and subdomain-based routing
- **Persistent Services**: Special handling for databases and other stateful services
- **Plugin System**: Extensible architecture with automatic hook detection
- **Monorepo Support**: Deploy multiple applications from a single repository
- **Zero Assumptions**: Works with any application, regardless of technology stack
- **GitHub Actions Integration**: Simple GitHub Actions workflow for CI/CD

## Getting Started

### Prerequisites

- A server with SSH access
- Docker and Docker Compose installed on the server
- GitHub repository with your application code

### Basic Usage

1. Add the UDS GitHub Action to your workflow:

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
        uses: your-org/unified-deployment-action@v1
        with:
          command: deploy
          app-name: my-app
          image: my-docker-image
          tag: latest
          domain: example.com
          route-type: path
          route: /my-app
          port: 3000
          ssl: true
          ssl-email: me@example.com
          host: ${{ secrets.DEPLOY_HOST }}
          username: ${{ secrets.DEPLOY_USER }}
          ssh-key: ${{ secrets.DEPLOY_KEY }}
```

2. Set up the required secrets in your GitHub repository:
   - `DEPLOY_HOST`: Your server hostname or IP
   - `DEPLOY_USER`: SSH username
   - `DEPLOY_KEY`: SSH private key

3. Push to your main branch to trigger the deployment.

### Configuration Options

| Option | Description | Default |
|--------|-------------|---------|
| `command` | Command to run (deploy, setup, cleanup) | `deploy` |
| `app-name` | Application name (required) | - |
| `image` | Docker image name | - |
| `tag` | Docker image tag | `latest` |
| `domain` | Domain name for deployment (required) | - |
| `route-type` | Type of route (path or subdomain) | `path` |
| `route` | Route path or subdomain prefix | - |
| `port` | Internal container port to expose | `3000` |
| `port-auto-assign` | Automatically assign ports if the specified port is in use | `true` |
| `ssl` | Enable SSL | `true` |
| `ssl-email` | Email for SSL certificate registration | - |
| `volumes` | Volume mappings (comma-separated) | - |
| `env-vars` | Environment variables (JSON string) | `{}` |
| `persistent` | Mark services as persistent | `false` |
| `compose-file` | Path to custom docker-compose.yml | - |
| `use-profiles` | Use Docker Compose profiles | `true` |
| `extra-hosts` | Extra hosts to add to containers | - |
| `health-check` | Health check endpoint | `/health` |
| `health-check-timeout` | Health check timeout in seconds | `60` |
| `health-check-type` | Health check type (http, tcp, container, command) | `auto` |
| `health-check-command` | Custom command for health check | - |
| `version-tracking` | Enable version tracking | `true` |
| `max-log-lines` | Maximum number of log lines to collect on error | `100` |
| `pg-migration-enabled` | Enable PostgreSQL migrations | `false` |
| `pg-connection-string` | PostgreSQL connection string | - |
| `pg-backup-enabled` | Enable PostgreSQL backups | `true` |
| `pg-migration-script` | Custom PostgreSQL migration script | - |
| `telegram-enabled` | Enable Telegram notifications | `false` |
| `telegram-bot-token` | Telegram bot token | - |
| `telegram-chat-id` | Telegram chat ID | - |
| `telegram-notify-level` | Minimum notification level | `info` |
| `telegram-include-logs` | Include logs in notifications | `true` |
| `host` | Remote host (required) | - |
| `username` | Remote username (required) | - |
| `ssh-key` | SSH private key (required) | - |
| `working-dir` | Working directory on the remote server | `/opt/uds` |
| `cleanup-previous` | Cleanup previous deployment | `true` |
| `plugins` | Enable specific plugins (comma-separated) | - |

## Advanced Usage

### Monorepo Deployments

UDS is designed to work seamlessly with monorepos, allowing you to deploy multiple applications from a single repository. Here's an example workflow for a monorepo containing a frontend, API, and database:

```yaml
name: Monorepo Deploy with UDS

on:
  push:
    branches: [main]

jobs:
  # First job to detect which parts of the monorepo have changed
  detect-changes:
    # ... (path filtering logic)
    
  # Build and deploy each component independently
  build-frontend:
    # ... (build frontend)
    
  build-api:
    # ... (build API)
    
  deploy-database:
    # ... (deploy database with persistent flag)
    
  deploy-api:
    # ... (deploy API with subdomain routing)
    
  deploy-frontend:
    # ... (deploy frontend with path routing)
```

See the full example in the `examples/monorepo-workflow.yml` file.

### Persistent Services

For stateful services like databases, set the `persistent` flag to `true`:

```yaml
- name: Deploy database
  uses: your-org/unified-deployment-action@v1
  with:
    command: deploy
    app-name: database
    image: postgres
    tag: latest
    domain: example.com
    persistent: true
    port: 5432
    # ... other options
```

This ensures the service's data persists across deployments and is not cleaned up during updates.

### Custom Docker Compose Files

To use your own Docker Compose file instead of the auto-generated one:

```yaml
- name: Deploy with custom compose
  uses: your-org/unified-deployment-action@v1
  with:
    command: deploy
    app-name: my-app
    domain: example.com
    compose-file: ./my-docker-compose.yml
    # ... other options
```

### Health Checks

UDS automatically checks your application's health after deployment. By default, it looks for a `/health` endpoint:

```yaml
- name: Deploy with custom health check
  uses: your-org/unified-deployment-action@v1
  with:
    command: deploy
    app-name: my-app
    image: my-image
    domain: example.com
    health-check: /api/healthz
    health-check-timeout: 120
    # ... other options
```

For applications without a health endpoint, set `health-check: none`.

## Health Checks

UDS automatically checks your application's health after deployment. By default, it looks for a `/health` endpoint:

```yaml
- name: Deploy with custom health check
  uses: your-org/unified-deployment-action@v1
  with:
    command: deploy
    app-name: my-app
    image: my-image
    domain: example.com
    health-check: /api/healthz
    health-check-timeout: 120
    # ... other options
```

For applications without a health endpoint, set `health-check: none`.

### Advanced Health Checks

UDS supports multiple health check types:

1. **HTTP** - Checks an HTTP endpoint (default)
2. **TCP** - Checks if a port is open (good for databases, Redis, etc.)
3. **Container** - Checks if the container is running and healthy
4. **Command** - Runs a custom command to check health

```yaml
- name: Deploy Redis with TCP health check
  uses: your-org/unified-deployment-action@v1
  with:
    command: deploy
    app-name: redis
    image: redis
    domain: example.com
    health-check-type: tcp
    port: 6379
    # ... other options
```

For custom command health checks:

```yaml
- name: Deploy with custom health check command
  uses: your-org/unified-deployment-action@v1
  with:
    command: deploy
    app-name: my-app
    image: my-image
    domain: example.com
    health-check-type: command
    health-check-command: "curl -s http://localhost:8080/status | grep -q OK"
    # ... other options
```

## Port Management

UDS automatically handles port conflicts, finding available ports when the requested port is in use:

```yaml
- name: Deploy with automatic port assignment
  uses: your-org/unified-deployment-action@v1
  with:
    command: deploy
    app-name: my-app
    image: my-image
    domain: example.com
    port: 3000  # Will use an alternative if 3000 is in use
    port-auto-assign: true
    # ... other options
```

## PostgreSQL Migrations

For applications using PostgreSQL, UDS can handle database migrations:

```yaml
- name: Deploy with PostgreSQL migrations
  uses: your-org/unified-deployment-action@v1
  with:
    command: deploy
    app-name: my-app
    image: my-image
    domain: example.com
    pg-migration-enabled: true
    pg-connection-string: postgresql://user:password@host:5432/database
    pg-backup-enabled: true
    # ... other options
```

### Custom Migration Scripts

For more control over migrations:

```yaml
- name: Deploy with custom migration script
  uses: your-org/unified-deployment-action@v1
  with:
    command: deploy
    app-name: my-app
    image: my-image
    domain: example.com
    pg-migration-enabled: true
    pg-connection-string: postgresql://user:password@host:5432/database
    pg-migration-script: "npm run migrate:production"
    # ... other options
```

## Telegram Notifications

UDS can send deployment notifications to Telegram:

```yaml
- name: Deploy with Telegram notifications
  uses: your-org/unified-deployment-action@v1
  with:
    command: deploy
    app-name: my-app
    image: my-image
    domain: example.com
    telegram-enabled: true
    telegram-bot-token: ${{ secrets.TELEGRAM_BOT_TOKEN }}
    telegram-chat-id: ${{ secrets.TELEGRAM_CHAT_ID }}
    telegram-notify-level: info  # debug, info, warning, error
    telegram-include-logs: true
    # ... other options
```

### Notification Events

The system sends notifications for:
- Deployment start
- Deployment success
- Health check failures
- Cutover completion
- Cleanup completion

## Version Tracking

UDS tracks deployment versions, maintaining a history of previous deployments:

```yaml
- name: Deploy with version tracking
  uses: your-org/unified-deployment-action@v1
  with:
    command: deploy
    app-name: my-app
    image: my-image
    tag: v1.2.3  # This version will be tracked
    domain: example.com
    version-tracking: true
    # ... other options
```

The system maintains a history of deployments in the service registry, including:
- Version tag
- Deployment timestamp
- Previous versions

## Server Setup

Before using UDS, you need to set up your server. The easiest way is to use the setup command:

```yaml
- name: Setup UDS
  uses: your-org/unified-deployment-action@v1
  with:
    command: setup
    app-name: setup
    domain: example.com
    host: ${{ secrets.DEPLOY_HOST }}
    username: ${{ secrets.DEPLOY_USER }}
    ssh-key: ${{ secrets.DEPLOY_KEY }}
```

This sets up the necessary directories and installs the Nginx proxy container.

## Architecture

UDS consists of several components:

1. **GitHub Action**: Provides a simple interface for CI/CD workflows
2. **Core Scripts**: Handle deployment orchestration, configuration, and plugin management
3. **Plugins**: Extend functionality with specific features like SSL and routing
4. **Nginx Proxy**: Routes traffic to the appropriate containers
5. **Service Registry**: Keeps track of deployed services and their configurations

The system is designed to be:

- **Agnostic**: Works with any application regardless of its technology stack
- **Flexible**: Supports both path-based and subdomain-based routing
- **Secure**: Automatic SSL certificate generation and renewal
- **Persistent**: Special handling for stateful services
- **Self-Contained**: All dependencies are installed automatically

## Troubleshooting

### Common Issues

#### Deployment fails with "Health check failed"

- Check if your application exposes a health endpoint at the configured path
- Increase the `health-check-timeout` value
- Set `health-check: none` to disable health checks
- Check the application logs using `docker logs <container-name>`

#### SSL certificate generation fails

- Ensure your domain is properly pointed to your server
- Check if port 80 is open for Let's Encrypt verification
- Verify the provided email address is valid
- Try without SSL first (`ssl: false`) then enable it later

#### Nginx configuration not working

- SSH into your server and check the Nginx container logs:
  ```bash
  docker logs nginx-proxy
  ```
- Check the generated configuration file in `/opt/uds/nginx/<app-name>.conf`

### Logs

UDS stores logs in the `/opt/uds/logs` directory on your server. To view them:

```bash
ssh user@server "cat /opt/uds/logs/uds.log"
```

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## License

This project is licensed under the MIT License - see the LICENSE file for details.