# UDS API Reference

This document provides a comprehensive reference for the UDS API functions available for scripting and plugin development.

## Core Functions

These functions form the foundation of the UDS system and are available for use in plugins and custom scripts.

### Logging

```bash
uds_log(message, level)
```

Logs a message with the specified level.

**Parameters:**
- `message`: The message to log
- `level`: Log level (`debug`, `info`, `warning`, `error`, `critical`, `success`)

**Example:**
```bash
uds_log "Starting deployment process" "info"
uds_log "Operation failed: $error_message" "error"
```

### Configuration

```bash
uds_load_config(config_file)
```

Loads configuration from a JSON file.

**Parameters:**
- `config_file`: Path to the configuration file

**Returns:**
- `0` on success, `1` on failure

**Example:**
```bash
if ! uds_load_config "$CONFIG_FILE"; then
  uds_log "Failed to load configuration" "error"
  return 1
fi
```

### Plugin System

```bash
uds_register_plugin_arg(plugin, arg_name, default_value)
```

Registers a plugin argument with a default value.

**Parameters:**
- `plugin`: Plugin name
- `arg_name`: Argument name
- `default_value`: Default value for the argument

**Example:**
```bash
uds_register_plugin_arg "my_plugin" "MY_SETTING" "default"
```

```bash
uds_register_plugin_hook(plugin, hook_name, hook_function)
```

Registers a plugin hook function.

**Parameters:**
- `plugin`: Plugin name
- `hook_name`: Hook name
- `hook_function`: Function to execute when the hook is triggered

**Example:**
```bash
uds_register_plugin_hook "my_plugin" "pre_deploy" "my_plugin_pre_deploy"
```

```bash
uds_execute_hook(hook_name, ...)
```

Executes all functions registered for a hook.

**Parameters:**
- `hook_name`: Hook name
- `...`: Additional parameters to pass to hook functions

**Example:**
```bash
uds_execute_hook "pre_deploy" "$APP_NAME" "$APP_DIR"
```

### Service Registry

```bash
uds_register_service(app_name, domain, route_type, route, port, image, tag, is_persistent)
```

Registers a service in the registry.

**Parameters:**
- `app_name`: Application name
- `domain`: Domain name
- `route_type`: Route type (`path` or `subdomain`)
- `route`: Route path or subdomain
- `port`: Container port
- `image`: Docker image
- `tag`: Docker image tag
- `is_persistent`: Whether the service is persistent (`true` or `false`)

**Example:**
```bash
uds_register_service "my-app" "example.com" "path" "app" "3000" "nginx" "latest" "false"
```

```bash
uds_unregister_service(app_name)
```

Unregisters a service from the registry.

**Parameters:**
- `app_name`: Application name

**Example:**
```bash
uds_unregister_service "my-app"
```

```bash
uds_get_service(app_name)
```

Gets service information from the registry.

**Parameters:**
- `app_name`: Application name

**Returns:**
- JSON service data on success, empty string on failure

**Example:**
```bash
local service_data=$(uds_get_service "my-app")
if [ -n "$service_data" ]; then
  local is_persistent=$(echo "$service_data" | jq -r '.is_persistent // false')
fi
```

```bash
uds_list_services()
```

Lists all registered services.

**Returns:**
- Newline-separated list of service names

**Example:**
```bash
local services=$(uds_list_services)
for service in $services; do
  echo "Service: $service"
done
```

### Port Management

```bash
uds_is_port_available(port, host)
```

Checks if a port is available.

**Parameters:**
- `port`: Port number
- `host`: Host to check (default: `localhost`)

**Returns:**
- `0` if available, `1` if in use

**Example:**
```bash
if uds_is_port_available 8080; then
  echo "Port 8080 is available"
fi
```

```bash
uds_find_available_port(base_port, max_port, increment, host)
```

Finds an available port starting from a base port.

**Parameters:**
- `base_port`: Port to start from
- `max_port`: Maximum port to check (default: `65535`)
- `increment`: Port increment (default: `1`)
- `host`: Host to check (default: `localhost`)

**Returns:**
- Available port number or empty string if none found

**Example:**
```bash
local port=$(uds_find_available_port 3000)
if [ -n "$port"]; then
  echo "Found available port: $port"
fi
```

```bash
uds_resolve_port_conflicts(port, app_name)
```

Resolves port conflicts by finding an alternative if needed.

**Parameters:**
- `port`: Desired port
- `app_name`: Application name

**Returns:**
- Original port if available, alternative port if conflict, empty string on failure

**Example:**
```bash
local resolved_port=$(uds_resolve_port_conflicts "$PORT" "$APP_NAME")
if [ -n "$resolved_port" ]; then
  PORT="$resolved_port"
fi
```

### Docker Functions

```bash
uds_generate_compose_file(app_name, image, tag, port, output_file, env_vars, volumes, use_profiles, extra_hosts)
```

Generates a Docker Compose file.

**Parameters:**
- `app_name`: Application name
- `image`: Docker image (can be comma-separated)
- `tag`: Docker image tag
- `port`: Container port (can be comma-separated)
- `output_file`: Path to output file
- `env_vars`: Environment variables as JSON (default: `{}`)
- `volumes`: Volume mappings (default: empty)
- `use_profiles`: Whether to use profiles (default: `true`)
- `extra_hosts`: Extra hosts to add (default: empty)

**Example:**
```bash
uds_generate_compose_file "$APP_NAME" "$IMAGE" "$TAG" "$PORT" "$APP_DIR/docker-compose.yml" "$ENV_VARS" "$VOLUMES" "$USE_PROFILES" "$EXTRA_HOSTS"
```

### Nginx Functions

```bash
uds_create_nginx_config(app_name, domain, route_type, route, port, use_ssl)
```

Creates an Nginx configuration file.

**Parameters:**
- `app_name`: Application name
- `domain`: Domain name
- `route_type`: Route type (`path` or `subdomain`)
- `route`: Route path or subdomain
- `port`: Container port
- `use_ssl`: Whether to use SSL (default: `true`)

**Returns:**
- Path to the created configuration file

**Example:**
```bash
local nginx_conf=$(uds_create_nginx_config "$APP_NAME" "$DOMAIN" "$ROUTE_TYPE" "$ROUTE" "$PORT" "$SSL")
```

```bash
uds_reload_nginx()
```

Reloads Nginx configuration.

**Returns:**
- `0` on success, `1` on failure

**Example:**
```bash
if ! uds_reload_nginx; then
  uds_log "Failed to reload Nginx" "warning"
fi
```

### Security Functions

```bash
uds_secure_permissions(target, perms)
```

Sets secure permissions on a file or directory.

**Parameters:**
- `target`: File or directory path
- `perms`: Permissions in chmod format (default: `600`)

**Returns:**
- `0` on success, `1` on failure

**Example:**
```bash
uds_secure_permissions "$CONFIG_FILE" 600
```

```bash
uds_secure_delete(target)
```

Securely deletes a file.

**Parameters:**
- `target`: File path

**Returns:**
- `0` on success, `1` on failure

**Example:**
```bash
uds_secure_delete "$TEMP_FILE"
```

## Health Check Functions

These functions are available in the consolidated health check module (`uds-health.sh`):

```bash
uds_detect_health_check_type(app_name, image, health_endpoint)
```

Detects the appropriate health check type for an application.

**Parameters:**
- `app_name`: Application name
- `image`: Docker image
- `health_endpoint`: Health check endpoint (default: `/health`)

**Returns:**
- Detected health check type (`http`, `tcp`, `database`, etc.)

**Example:**
```bash
local health_type=$(uds_detect_health_check_type "$APP_NAME" "$IMAGE" "$HEALTH_CHECK")
```

```bash
uds_health_check_with_retry(app_name, port, health_endpoint, max_attempts, timeout, health_type, container_name, health_command)
```

Enhanced health check with exponential backoff and retry logic.

**Parameters:**
- `app_name`: Application name
- `port`: Container port
- `health_endpoint`: Health check endpoint (default: `/health`)
- `max_attempts`: Maximum number of attempts (default: `5`)
- `timeout`: Maximum time to wait per attempt (default: `60`)
- `health_type`: Health check type (default: `auto`)
- `container_name`: Container name (optional)
- `health_command`: Custom health check command (optional)

**Returns:**
- `0` if healthy, `1` if unhealthy

**Example:**
```bash
if uds_health_check_with_retry "$APP_NAME" "$PORT" "$HEALTH_CHECK" "5" "$HEALTH_CHECK_TIMEOUT" "$HEALTH_CHECK_TYPE"; then
  uds_log "Application is healthy" "success"
else
  uds_log "Application health check failed" "error"
fi
```

## Environment Variables

These variables are available in the UDS environment and can be used in plugins and custom scripts.

| Variable | Description |
|----------|-------------|
| `UDS_BASE_DIR` | Base directory of UDS installation |
| `UDS_VERSION` | UDS version |
| `UDS_PLUGINS_DIR` | Plugins directory |
| `UDS_CONFIGS_DIR` | Configurations directory |
| `UDS_LOGS_DIR` | Logs directory |
| `UDS_CERTS_DIR` | Certificates directory |
| `UDS_NGINX_DIR` | Nginx configurations directory |
| `UDS_REGISTRY_FILE` | Path to service registry file |
| `UDS_LOG_LEVEL` | Current log level |
| `UDS_DOCKER_COMPOSE_CMD` | Docker Compose command |
| `APP_NAME` | Current application name |
| `APP_DIR` | Application directory |
| `COMMAND` | Current command (`deploy`, `setup`, etc.) |
| `IMAGE` | Docker image |
| `TAG` | Docker image tag |
| `DOMAIN` | Domain name |
| `ROUTE_TYPE` | Route type |
| `ROUTE` | Route path or subdomain |
| `PORT` | Container port |
| `SSL` | Whether SSL is enabled |
| `SSL_EMAIL` | Email for SSL certificate |
| `ENV_VARS` | Environment variables JSON |
| `VOLUMES` | Volume mappings |
| `PERSISTENT` | Whether the service is persistent |
| `MULTI_STAGE` | Whether multi-stage deployment is enabled |
| `HEALTH_CHECK` | Health check endpoint |
| `HEALTH_CHECK_TYPE` | Health check type |
| `HEALTH_CHECK_TIMEOUT` | Health check timeout |

## Plugin Development Pattern

When developing plugins, follow this pattern:

1. Registration function:
```bash
plugin_register_<plugin_name>() {
  uds_register_plugin_arg "<plugin_name>" "ARG_NAME" "default_value"
  uds_register_plugin_hook "<plugin_name>" "hook_name" "plugin_function"
}
```

2. Activation function:
```bash
plugin_activate_<plugin_name>() {
  # Initialization code
}
```

3. Hook functions:
```bash
plugin_<plugin_name>_<hook_function>() {
  local app_name="$1"
  local app_dir="$2"
  # Hook implementation
}
```

## Return Code Conventions

UDS functions follow these return code conventions:

- `0`: Success
- `1`: General failure
- `2`: Configuration error
- `3`: Dependency error
- `4`: Permission error
- `5`: Network error

Scripts should propagate these return codes appropriately.

## Thread Safety and Concurrency

UDS scripts are not designed to be thread-safe. Running multiple UDS operations simultaneously on the same application may lead to unpredictable results. Each deployment should be handled sequentially to ensure consistency.

## Error Handling Pattern

When using UDS functions, follow this error handling pattern:

```bash
if ! uds_function arg1 arg2; then
  uds_log "Function failed: uds_function" "error"
  return 1
fi
```

Or using subshell capture with validation:

```bash
local result=$(uds_function arg1 arg2)
if [ $? -ne 0 ]; then
  uds_log "Function failed: uds_function" "error"
  return 1
fi
```

By following these API conventions, you can effectively extend and customize UDS for your specific deployment needs.
