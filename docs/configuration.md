# UDS Configuration Reference

This comprehensive guide details all available configuration options for the Unified Deployment System.

## Configuration Format

UDS uses JSON format for configuration files. The basic structure is:

```json
{
  "app_name": "my-application",
  "command": "deploy",
  "image": "nginx",
  "tag": "latest",
  "domain": "example.com",
  "route_type": "path",
  "route": "myapp",
  "port": "8080",
  "ssl": true,
  "ssl_email": "admin@example.com",
  "plugins": "ssl-manager,telegram-notifier"
}
```

## Core Configuration Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `app_name` | string | | **Required**. Name of your application. Used as an identifier in the registry and for container naming. |
| `command` | string | `deploy` | Command to execute (`deploy`, `setup`, `cleanup`, etc.). |
| `image` | string | | Docker image to deploy. Can be a comma-separated list for multi-container deployments. |
| `tag` | string | `latest` | Docker image tag. |
| `domain` | string | | **Required**. Primary domain for the application. |
| `route_type` | string | `path` | Routing type: `path` or `subdomain`. |
| `route` | string | | Path or subdomain prefix. For `path` type, this is appended to domain (e.g., `example.com/myapp`). For `subdomain` type, this is prepended (e.g., `myapp.example.com`). |
| `port` | string | `3000` | Container port(s) to expose. Can use `host:container` format for custom mapping. For multi-container setups, use comma-separated list. |
| `persistent` | boolean | `false` | Mark service as persistent. Persistent services maintain their data across deployments. |
| `compose_file` | string | | Path to custom docker-compose.yml file. If provided, UDS will use this instead of generating one. |

## SSL Configuration

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `ssl` | boolean | `true` | Enable SSL/TLS for the application. |
| `ssl_email` | string | | Email for Let's Encrypt certificate registration. Required for proper SSL setup. |
| `ssl_wildcard` | boolean | `false` | Enable wildcard certificate for subdomains. Requires DNS validation. |
| `ssl_dns_provider` | string | | DNS provider for wildcard certificate validation (e.g., `cloudflare`, `route53`). |
| `ssl_dns_credentials` | string | | Credentials for DNS provider. Format varies by provider. |
| `ssl_staging` | boolean | `false` | Use Let's Encrypt staging environment for testing. |
| `ssl_renewal_days` | number | `30` | Number of days before expiration to trigger certificate renewal. |
| `ssl_rsa_key_size` | number | `4096` | RSA key size for certificates. |

## Container & Environment Configuration

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `volumes` | string | | Volume mappings in `source:target` format. Use comma-separated list for multiple volumes. |
| `env_vars` | object | `{}` | Environment variables to pass to containers. |
| `use_profiles` | boolean | `true` | Use Docker Compose profiles for better organization. |
| `extra_hosts` | string | | Extra host entries to add to containers in `hostname:ip` format. |
| `working_dir` | string | `/opt/uds` | Working directory on the remote server. |
| `port_auto_assign` | boolean | `true` | Automatically assign ports if specified ports are in use. |

## Health Check Configuration

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `health_check` | string | `/health` | Health check endpoint path. Use `none` to disable. |
| `health_check_type` | string | `auto` | Health check type: `auto`, `http`, `tcp`, `database`, `container`, `command`, `rabbitmq`, `elasticsearch`, `kafka`. |
| `health_check_timeout` | number | `60` | Maximum time in seconds to wait for health check to pass. |
| `health_check_command` | string | | Custom command for health check when using command type. |

## Deployment Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `multi_stage` | boolean | `false` | Enable multi-stage deployment with validation and cutover. |
| `check_dependencies` | boolean | `false` | Check dependencies before deployment. |
| `version_tracking` | boolean | `true` | Enable version tracking for rollback capability. |

## Plugin-Specific Configuration

### SSL Manager Plugin

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `SSL_STAGING` | boolean | `false` | Use Let's Encrypt staging environment. |
| `SSL_RENEWAL_DAYS` | number | `30` | Days before expiration to renew certificates. |
| `SSL_RSA_KEY_SIZE` | number | `4096` | RSA key size for certificates. |
| `SSL_WILDCARD` | boolean | `false` | Enable wildcard certificates. |
| `SSL_DNS_PROVIDER` | string | | DNS provider for DNS challenge. |
| `SSL_DNS_CREDENTIALS` | string | | DNS provider credentials. |

### Persistence Manager Plugin

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `PERSISTENCE_PROFILE` | string | `persistence` | Docker Compose profile for persistent services. |
| `PERSISTENCE_DATA_DIR` | string | `${UDS_BASE_DIR}/data` | Directory for persistent data storage. |
| `PERSISTENCE_AUTO_SETUP` | boolean | `true` | Automatically detect and set up persistence for databases. |

### PostgreSQL Manager Plugin

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `PG_MIGRATION_ENABLED` | boolean | `false` | Enable PostgreSQL migrations. |
| `PG_CONNECTION_STRING` | string | | PostgreSQL connection string. |
| `PG_BACKUP_ENABLED` | boolean | `true` | Enable database backups before migrations. |
| `PG_BACKUP_DIR` | string | `${UDS_BASE_DIR}/backups` | Directory for database backups. |
| `PG_MIGRATION_SCRIPT` | string | | Custom migration script path. |
| `PG_MIGRATION_CONTAINER` | string | | Container to run migrations in. |

### Telegram Notifier Plugin

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `TELEGRAM_ENABLED` | boolean | `false` | Enable Telegram notifications. |
| `TELEGRAM_BOT_TOKEN` | string | | Telegram bot token. |
| `TELEGRAM_CHAT_ID` | string | | Telegram chat ID to send notifications to. |
| `TELEGRAM_NOTIFY_LEVEL` | string | `info` | Minimum level for notifications (`debug`, `info`, `warning`, `error`). |
| `TELEGRAM_INCLUDE_LOGS` | boolean | `true` | Include logs in failure notifications. |

### Security Manager Plugin

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `SECURITY_ENCRYPT_ENV` | boolean | `false` | Enable environment variable encryption. |
| `SECURITY_ENCRYPTION_KEY` | string | | Key for environment variable encryption. |
| `SECURITY_LOG_ROTATION` | boolean | `true` | Enable log rotation. |
| `SECURITY_LOG_MAX_SIZE` | string | `10M` | Maximum log file size. |
| `SECURITY_LOG_MAX_FILES` | number | `5` | Maximum number of log files to keep. |
| `SECURITY_AUDIT_LOGGING` | boolean | `false` | Enable audit logging. |
| `SECURITY_AUDIT_LOG` | string | `${UDS_LOGS_DIR}/audit.log` | Path to audit log file. |

### Route Manager Plugin

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `ROUTE_AUTO_UPDATE` | boolean | `true` | Automatically update Nginx configuration. |
| `NGINX_CONTAINER` | string | `nginx-proxy` | Name of the Nginx container. |
| `NGINX_CONFIG_DIR` | string | `/etc/nginx/conf.d` | Nginx configuration directory. |

## Environment Variables Configuration

The `env_vars` object allows you to pass environment variables to your containers:

```json
{
  "env_vars": {
    "NODE_ENV": "production",
    "DATABASE_URL": "postgresql://user:password@db:5432/mydb",
    "API_KEY": "your-api-key",
    "LOG_LEVEL": "info"
  }
}
```

## GitHub Actions Input Mapping

When using UDS as a GitHub Action, the inputs are mapped to configuration options as follows:

| GitHub Action Input | Configuration Option |
|---------------------|----------------------|
| `app-name` | `app_name` |
| `command` | `command` |
| `image` | `image` |
| `tag` | `tag` |
| `domain` | `domain` |
| `route-type` | `route_type` |
| `route` | `route` |
| `port` | `port` |
| `ssl` | `ssl` |
| `ssl-email` | `ssl_email` |
| `ssl-wildcard` | `ssl_wildcard` |
| `ssl-dns-provider` | `ssl_dns_provider` |
| `ssl-dns-credentials` | `ssl_dns_credentials` |
| `volumes` | `volumes` |
| `env-vars` | `env_vars` |
| `persistent` | `persistent` |
| `compose-file` | `compose_file` |
| `use-profiles` | `use_profiles` |
| `extra-hosts` | `extra_hosts` |
| `health-check` | `health_check` |
| `health-check-type` | `health_check_type` |
| `health-check-timeout` | `health_check_timeout` |
| `health-check-command` | `health_check_command` |
| `multi-stage` | `multi_stage` |
| `check-dependencies` | `check_dependencies` |
| `port-auto-assign` | `port_auto_assign` |
| `version-tracking` | `version_tracking` |
| `secure-mode` | `secure_mode` |
| `check-system` | `check_system` |
| `plugins` | `plugins` |

## Sample Configurations

### Basic Web Application

```json
{
  "app_name": "my-webapp",
  "image": "nginx",
  "tag": "latest",
  "domain": "example.com",
  "route_type": "path",
  "route": "app",
  "port": "80",
  "ssl": true,
  "ssl_email": "admin@example.com"
}
```

### Database with Persistence

```json
{
  "app_name": "my-database",
  "image": "postgres:13",
  "domain": "example.com",
  "port": "5432",
  "persistent": true,
  "volumes": "postgres-data:/var/lib/postgresql/data",
  "env_vars": {
    "POSTGRES_USER": "dbuser",
    "POSTGRES_PASSWORD": "secret",
    "POSTGRES_DB": "mydb"
  },
  "plugins": "persistence-manager"
}
```

### Multi-Container Application

```json
{
  "app_name": "my-fullstack-app",
  "image": "frontend,api,redis",
  "tag": "latest",
  "domain": "example.com",
  "route_type": "subdomain",
  "route": "app",
  "port": "80:80,3000:3000,6379:6379",
  "ssl": true,
  "ssl_email": "admin@example.com",
  "multi_stage": true,
  "health_check": "/health",
  "health_check_type": "http",
  "env_vars": {
    "NODE_ENV": "production",
    "REDIS_URL": "redis://redis:6379"
  }
}
```

### Advanced Configuration with Plugins

```json
{
  "app_name": "my-secure-app",
  "image": "myorg/app:v1.0",
  "domain": "secure-example.com",
  "route_type": "path",
  "route": "api",
  "port": "3000",
  "ssl": true,
  "ssl_email": "security@example.com",
  "ssl_wildcard": true,
  "ssl_dns_provider": "cloudflare",
  "multi_stage": true,
  "check_dependencies": true,
  "health_check": "/health",
  "health_check_timeout": 120,
  "health_check_type": "http",
  "env_vars": {
    "NODE_ENV": "production",
    "LOG_LEVEL": "info",
    "SECURITY_ENCRYPTION_KEY": "your-secure-key",
    "TELEGRAM_BOT_TOKEN": "your-bot-token",
    "TELEGRAM_CHAT_ID": "your-chat-id"
  },
  "plugins": "ssl-manager,security-manager,telegram-notifier"
}
```

## Configuration Inheritance

When using a custom `compose_file`, UDS will still apply the following configuration options:

- SSL setup based on `ssl` settings
- Routing based on `route_type` and `route`
- Health checking based on `health_check` settings
- Network connectivity for multi-container setups

Other options like `volumes` and `env_vars` will not override those in your custom compose file unless explicitly configured.
