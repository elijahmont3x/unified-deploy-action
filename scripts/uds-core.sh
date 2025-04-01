#!/bin/bash
#
# uds-core.sh - Core functionality for Unified Deployment System
#
# This script provides common functions for deployment, configuration, and plugin management

set -eo pipefail

# Define base directories and paths consistently
UDS_BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UDS_VERSION="1.0.0"
UDS_PLUGINS_DIR="${UDS_BASE_DIR}/plugins"
UDS_CONFIGS_DIR="${UDS_BASE_DIR}/configs"
UDS_LOGS_DIR="${UDS_BASE_DIR}/logs"
UDS_CERTS_DIR="${UDS_BASE_DIR}/certs"
UDS_NGINX_DIR="${UDS_BASE_DIR}/nginx"
UDS_REGISTRY_FILE="${UDS_BASE_DIR}/service-registry.json"

# Core environmental variables
UDS_TIME_ZONE="${TZ:-UTC}"
UDS_DATE_FORMAT="+%Y-%m-%d %H:%M:%S"
UDS_DOCKER_COMPOSE_CMD=$(command -v docker-compose || echo "docker compose")

# Log levels
declare -A UDS_LOG_LEVELS=(
  ["debug"]=0
  ["info"]=1
  ["warning"]=2
  ["error"]=3
  ["critical"]=4
)

# Current log level
UDS_LOG_LEVEL="${UDS_LOG_LEVEL:-info}"

# Color definitions for logs
declare -A UDS_LOG_COLORS=(
  ["debug"]="\033[0;37m"    # Light gray
  ["info"]="\033[0;34m"     # Blue
  ["warning"]="\033[0;33m"  # Yellow
  ["error"]="\033[0;31m"    # Red
  ["critical"]="\033[1;31m" # Bold red
  ["success"]="\033[0;32m"  # Green
)

# Reset color
UDS_COLOR_RESET="\033[0m"

# Plugin registry
declare -A UDS_PLUGIN_REGISTRY=()
declare -A UDS_PLUGIN_ARGS=()
declare -A UDS_PLUGIN_HOOKS=()

# ============================================================
# INITIALIZATION FUNCTIONS
# ============================================================

# Initialize the UDS environment
uds_init() {
  # Create required directories with secure permissions
  mkdir -p "${UDS_CONFIGS_DIR}" "${UDS_LOGS_DIR}" "${UDS_CERTS_DIR}" "${UDS_NGINX_DIR}"
  
  # Set secure permissions on sensitive directories
  chmod 700 "${UDS_CONFIGS_DIR}"
  chmod 700 "${UDS_LOGS_DIR}"
  chmod 700 "${UDS_CERTS_DIR}"
  
  # Initialize service registry if it doesn't exist
  if [ ! -f "${UDS_REGISTRY_FILE}" ]; then
    echo '{"services":{}}' > "${UDS_REGISTRY_FILE}"
    chmod 600 "${UDS_REGISTRY_FILE}"
  fi

  # Load modules
  uds_load_modules

  # Discover and register plugins
  uds_discover_plugins

  # Ensure required tools are available
  uds_check_requirements
}

# Load all required modules
uds_load_modules() {
  # Load health check module
  if [ -f "${UDS_BASE_DIR}/uds-health.sh" ]; then
    source "${UDS_BASE_DIR}/uds-health.sh"
    # Export the health check functions
    if type uds_check_health &>/dev/null; then
      export -f uds_check_health uds_detect_health_check_type
    fi
  fi
}

# Check for required tools and install missing ones if possible
uds_check_requirements() {
  # Check for essential commands
  local REQUIRED_COMMANDS=("docker" "curl" "jq" "openssl")
  local MISSING_COMMANDS=()

  for cmd in "${REQUIRED_COMMANDS[@]}"; do
    if ! command -v "$cmd" &> /dev/null; then
      MISSING_COMMANDS+=("$cmd")
    fi
  done

  if [ ${#MISSING_COMMANDS[@]} -gt 0 ]; then
    uds_log "Missing required commands: ${MISSING_COMMANDS[*]}" "warning"
    
    # Try to install missing dependencies
    if [ "${AUTO_INSTALL_DEPS:-true}" = "true" ]; then
      uds_log "Attempting to install missing dependencies..." "info"
      
      # Check for package manager
      if command -v apt-get &> /dev/null; then
        apt-get update && apt-get install -y ${MISSING_COMMANDS[@]}
      elif command -v yum &> /dev/null; then
        yum install -y ${MISSING_COMMANDS[@]}
      elif command -v dnf &> /dev/null; then
        dnf install -y ${MISSING_COMMANDS[@]}
      elif command -v apk &> /dev/null; then
        apk add --no-cache ${MISSING_COMMANDS[@]}
      else
        uds_log "Couldn't detect package manager. Please install dependencies manually:" "error"
        uds_log "${MISSING_COMMANDS[*]}" "error"
        return 1
      fi
      
      # Verify installation
      local STILL_MISSING=()
      for cmd in "${MISSING_COMMANDS[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
          STILL_MISSING+=("$cmd")
        fi
      done
      
      if [ ${#STILL_MISSING[@]} -gt 0 ]; then
        uds_log "Failed to install: ${STILL_MISSING[*]}" "error"
        return 1
      else
        uds_log "Successfully installed missing dependencies" "success"
      fi
    else
      uds_log "Please install these tools before continuing." "error"
      return 1
    fi
  fi

  # Check Docker is running
  if ! docker info &> /dev/null; then
    uds_log "Docker is not running or current user doesn't have permission." "error"
    return 1
  fi

  # Check Docker Compose is available
  if ! $UDS_DOCKER_COMPOSE_CMD version &> /dev/null; then
    uds_log "Docker Compose is not available. Attempting to install..." "warning"
    
    if command -v apt-get &> /dev/null; then
      apt-get update && apt-get install -y docker-compose
    else
      # Use Docker's official installation script
      curl -L "https://github.com/docker/compose/releases/download/v2.12.2/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
      chmod +x /usr/local/bin/docker-compose
    fi
    
    # Update the Docker Compose command
    UDS_DOCKER_COMPOSE_CMD=$(command -v docker-compose || echo "docker compose")
    
    if ! $UDS_DOCKER_COMPOSE_CMD version &> /dev/null; then
      uds_log "Failed to install Docker Compose" "error"
      return 1
    fi
  fi

  return 0
}

# ============================================================
# LOGGING FUNCTIONS
# ============================================================

# Log a message
uds_log() {
  local message="$1"
  local level="${2:-info}"
  local timestamp=$(date "${UDS_DATE_FORMAT}")
  local color="${UDS_LOG_COLORS[$level]:-${UDS_LOG_COLORS[info]}}"

  # Sanitize the message to protect sensitive data
  local sanitized_message=$(uds_sanitize_env_vars "$message")

  # Only log if the level is equal or higher than the current log level
  if [ "${UDS_LOG_LEVELS[$level]:-1}" -ge "${UDS_LOG_LEVELS[$UDS_LOG_LEVEL]:-1}" ]; then
    # Format and print log message
    echo -e "${timestamp} ${color}[${level^^}]${UDS_COLOR_RESET} ${sanitized_message}"

    # Write to log file
    echo "${timestamp} [${level^^}] ${sanitized_message}" >> "${UDS_LOGS_DIR}/uds.log"
  fi
}

# ============================================================
# SECURITY FUNCTIONS
# ============================================================

# Apply secure permissions to files or directories
uds_secure_permissions() {
  local target="$1"
  local perms="${2:-600}"
  
  if [ ! -e "$target" ]; then
    uds_log "Target does not exist: $target" "error"
    return 1
  fi
  
  uds_log "Setting permissions $perms on $target" "debug"
  chmod "$perms" "$target"
  
  # Set owner if running as root
  if [ "$(id -u)" -eq 0 ]; then
    chown root:root "$target"
  fi
  
  return 0
}

# Securely delete sensitive files
uds_secure_delete() {
  local target="$1"
  
  if [ ! -e "$target" ]; then
    uds_log "Target does not exist: $target" "debug"
    return 0
  fi
  
  uds_log "Securely deleting: $target" "debug"
  
  # Check for secure deletion tools
  if command -v shred &> /dev/null; then
    shred -u -z "$target"
  elif command -v srm &> /dev/null; then
    srm -z "$target"
  else
    # Fallback: overwrite with zeros before deleting
    dd if=/dev/zero of="$target" bs=1k count=1 conv=notrunc &> /dev/null
    rm -f "$target"
  fi
  
  return 0
}

# ============================================================
# CONFIGURATION FUNCTIONS
# ============================================================

# Load configuration from a JSON file
uds_load_config() {
  local config_file="$1"

  if [ ! -f "$config_file" ]; then
    uds_log "Configuration file not found: $config_file" "error"
    return 1
  fi

  # Apply secure permissions to config file
  uds_secure_permissions "$config_file" 600
  
  # Read configuration into variables
  local config_json=$(cat "$config_file")

  APP_NAME=$(echo "$config_json" | jq -r '.app_name // empty')
  COMMAND=$(echo "$config_json" | jq -r '.command // "deploy"')
  IMAGE=$(echo "$config_json" | jq -r '.image // empty')
  TAG=$(echo "$config_json" | jq -r '.tag // "latest"')
  DOMAIN=$(echo "$config_json" | jq -r '.domain // empty')
  ROUTE_TYPE=$(echo "$config_json" | jq -r '.route_type // "path"')
  ROUTE=$(echo "$config_json" | jq -r '.route // ""')
  PORT=$(echo "$config_json" | jq -r '.port // "3000"')
  SSL=$(echo "$config_json" | jq -r '.ssl // true')
  SSL_EMAIL=$(echo "$config_json" | jq -r '.ssl_email // empty')
  VOLUMES=$(echo "$config_json" | jq -r '.volumes // empty')
  ENV_VARS=$(echo "$config_json" | jq -r '.env_vars // "{}"')
  PERSISTENT=$(echo "$config_json" | jq -r '.persistent // false')
  COMPOSE_FILE=$(echo "$config_json" | jq -r '.compose_file // empty')
  USE_PROFILES=$(echo "$config_json" | jq -r '.use_profiles // true')
  EXTRA_HOSTS=$(echo "$config_json" | jq -r '.extra_hosts // empty')
  HEALTH_CHECK=$(echo "$config_json" | jq -r '.health_check // "/health"')
  HEALTH_CHECK_TIMEOUT=$(echo "$config_json" | jq -r '.health_check_timeout // "60"')
  HEALTH_CHECK_TYPE=$(echo "$config_json" | jq -r '.health_check_type // "auto"')
  HEALTH_CHECK_COMMAND=$(echo "$config_json" | jq -r '.health_check_command // empty')
  PORT_AUTO_ASSIGN=$(echo "$config_json" | jq -r '.port_auto_assign // true')
  VERSION_TRACKING=$(echo "$config_json" | jq -r '.version_tracking // true')
  MAX_LOG_LINES=$(echo "$config_json" | jq -r '.max_log_lines // "100"')
  PLUGINS=$(echo "$config_json" | jq -r '.plugins // empty')

  # Set the app directory
  APP_DIR="${UDS_BASE_DIR}/${APP_NAME}"

  # Validate required configuration
  if [ -z "$APP_NAME" ]; then
    uds_log "app_name is required in configuration" "error"
    return 1
  fi

  if [ -z "$DOMAIN" ]; then
    uds_log "domain is required in configuration" "error"
    return 1
  fi

  # Create app directory if it doesn't exist
  mkdir -p "$APP_DIR"

  # Activate specified plugins
  if [ -n "$PLUGINS" ]; then
    uds_activate_plugins "$PLUGINS"
  fi

  # Export configuration for plugins
  export APP_NAME COMMAND IMAGE TAG DOMAIN ROUTE_TYPE ROUTE PORT SSL SSL_EMAIL
  export VOLUMES ENV_VARS PERSISTENT COMPOSE_FILE USE_PROFILES EXTRA_HOSTS
  export HEALTH_CHECK HEALTH_CHECK_TIMEOUT HEALTH_CHECK_TYPE HEALTH_CHECK_COMMAND
  export PORT_AUTO_ASSIGN VERSION_TRACKING MAX_LOG_LINES APP_DIR

  return 0
}

# ============================================================
# PLUGIN SYSTEM
# ============================================================

# Discover and register available plugins
uds_discover_plugins() {
  if [ ! -d "$UDS_PLUGINS_DIR" ]; then
    uds_log "Plugins directory not found: $UDS_PLUGINS_DIR" "warning"
    mkdir -p "$UDS_PLUGINS_DIR"
    return 0
  fi

  uds_log "Discovering plugins..." "debug"

  # Find all plugin files
  local plugin_files=()
  while IFS= read -r file; do
    plugin_files+=("$file")
  done < <(find "$UDS_PLUGINS_DIR" -name "*.sh" -type f)

  if [ ${#plugin_files[@]} -eq 0 ]; then
    uds_log "No plugins found" "debug"
    return 0
  fi

  # Load each plugin
  for plugin_file in "${plugin_files[@]}"; do
    local plugin_name=$(basename "$plugin_file" .sh)
    
    # Source the plugin file
    source "$plugin_file"
    
    # Check if the plugin has a register function
    if type "plugin_register_${plugin_name}" &>/dev/null; then
      uds_log "Registering plugin: $plugin_name" "debug"
      UDS_PLUGIN_REGISTRY["$plugin_name"]=1
      
      # Call the plugin's register function
      "plugin_register_${plugin_name}"
    else
      uds_log "Plugin $plugin_name has no register function, skipping" "warning"
    fi
  done

  uds_log "Registered ${#UDS_PLUGIN_REGISTRY[@]} plugins" "debug"
}

# Activate specific plugins
uds_activate_plugins() {
  local plugins_list="$1"
  
  # Skip if no plugins specified
  if [ -z "$plugins_list" ]; then
    return 0
  fi
  
  # Split comma-separated list
  IFS=',' read -ra PLUGINS_ARRAY <<< "$plugins_list"
  
  for plugin in "${PLUGINS_ARRAY[@]}"; do
    if [ -n "${UDS_PLUGIN_REGISTRY[$plugin]:-}" ]; then
      uds_log "Activating plugin: $plugin" "debug"
      
      # Call the plugin's activate function if it exists
      if type "plugin_activate_${plugin}" &>/dev/null; then
        "plugin_activate_${plugin}"
      fi
    else
      uds_log "Plugin not found: $plugin" "warning"
    fi
  done
}

# Register a plugin argument
uds_register_plugin_arg() {
  local plugin="$1"
  local arg_name="$2"
  local default_value="$3"
  
  UDS_PLUGIN_ARGS["${plugin}:${arg_name}"]="$default_value"
  
  # Create global variable if it doesn't exist
  if [ -z "${!arg_name:-}" ]; then
    eval "$arg_name=\"$default_value\""
    export "$arg_name"
  fi
}

# Register a plugin hook
uds_register_plugin_hook() {
  local plugin="$1"
  local hook_name="$2"
  local hook_function="$3"
  
  local hook_key="${hook_name}"
  
  # Initialize the hook array if it doesn't exist
  if [ -z "${UDS_PLUGIN_HOOKS[$hook_key]:-}" ]; then
    UDS_PLUGIN_HOOKS["$hook_key"]=""
  fi
  
  # Add the function to the hook
  if [ -n "${UDS_PLUGIN_HOOKS[$hook_key]}" ]; then
    UDS_PLUGIN_HOOKS["$hook_key"]="${UDS_PLUGIN_HOOKS[$hook_key]},${hook_function}"
  else
    UDS_PLUGIN_HOOKS["$hook_key"]="$hook_function"
  fi
}

# Execute plugin hooks
uds_execute_hook() {
  local hook_name="$1"
  shift
  
  local hook_key="${hook_name}"
  
  if [ -n "${UDS_PLUGIN_HOOKS[$hook_key]:-}" ]; then
    # Split comma-separated list of functions
    IFS=',' read -ra HOOK_FUNCTIONS <<< "${UDS_PLUGIN_HOOKS[$hook_key]}"
    
    # Execute each hook function
    for hook_function in "${HOOK_FUNCTIONS[@]}"; do
      if type "$hook_function" &>/dev/null; then
        uds_log "Executing hook: $hook_function ($hook_name)" "debug"
        "$hook_function" "$@"
      else
        uds_log "Hook function not found: $hook_function" "warning"
      fi
    done
  fi
}

# ============================================================
# PORT MANAGEMENT
# ============================================================

# Check if a port is available
uds_is_port_available() {
  local port="$1"
  local host="${2:-localhost}"
  
  # More comprehensive port availability check
  # First try direct socket approach
  if (echo > /dev/tcp/$host/$port) 2>/dev/null; then
    # Connection succeeded, port is in use
    return 1
  fi
  
  # Try alternative checks with different tools
  if command -v netstat &>/dev/null; then
    if netstat -tuln | grep -q ":$port "; then
      # Port is in use
      return 1
    fi
  elif command -v ss &>/dev/null; then
    if ss -tuln | grep -q ":$port "; then
      # Port is in use
      return 1
    fi
  elif command -v lsof &>/dev/null; then
    if lsof -i ":$port" &>/dev/null; then
      # Port is in use
      return 1
    fi
  elif command -v nmap &>/dev/null; then
    # Use nmap as a last resort as it's slower
    if nmap -p "$port" "$host" 2>/dev/null | grep -q "open"; then
      # Port is in use
      return 1
    fi
  fi
  
  # Port is available
  return 0
}

# Find an available port starting from a base port
uds_find_available_port() {
  local base_port="$1"
  local max_port="${2:-65535}"
  local increment="${3:-1}"
  local host="${4:-localhost}"
  
  local current_port=$base_port
  while [ $current_port -le $max_port ]; do
    if uds_is_port_available "$current_port" "$host"; then
      # Found an available port
      echo "$current_port"
      return 0
    fi
    
    # Try the next port
    current_port=$((current_port + increment))
  done
  
  # No available port found
  uds_log "No available port found in range $base_port-$max_port" "error"
  return 1
}

# Resolve port conflicts automatically
uds_resolve_port_conflicts() {
  local port="$1"
  local app_name="$2"
  local host_port=""
  local container_port=""
  
  # If port auto-assign is disabled, just return the original port
  if [ "${PORT_AUTO_ASSIGN:-true}" != "true" ]; then
    echo "$port"
    return 0
  fi
  
  # Check if port contains mapping (host:container)
  if [[ "$port" == *":"* ]]; then
    host_port=$(echo "$port" | cut -d: -f1)
    container_port=$(echo "$port" | cut -d: -f2)
    uds_log "Checking if host port $host_port is available for $app_name" "info"
    
    if uds_is_port_available "$host_port"; then
      uds_log "Host port $host_port is available" "debug"
      echo "$port"  # Return original mapping
      return 0
    else
      uds_log "Host port $host_port is already in use, finding an alternative" "warning"
      
      # Find an available host port
      local new_host_port=$(uds_find_available_port $((host_port + 1)))
      if [ -n "$new_host_port" ]; then
        uds_log "Assigned alternative host port $new_host_port for $app_name" "info"
        echo "${new_host_port}:${container_port}"
        return 0
      else
        uds_log "Failed to find an available host port for $app_name" "error"
        return 1
      fi
    fi
  else
    # Standard single port
    uds_log "Checking if port $port is available for $app_name" "info"
    
    if uds_is_port_available "$port"; then
      uds_log "Port $port is available" "debug"
      echo "$port"
      return 0
    else
      uds_log "Port $port is already in use, finding an alternative" "warning"
      
      # Try to find an available port
      local new_port=$(uds_find_available_port $((port + 1)))
      if [ -n "$new_port" ]; then
        uds_log "Assigned alternative port $new_port for $app_name" "info"
        echo "$new_port"
        return 0
      else
        uds_log "Failed to find an available port for $app_name" "error"
        return 1
      fi
    fi
  fi
}

# ============================================================
# DOCKER FUNCTIONS
# ============================================================

# Generate a docker-compose.yml file
uds_generate_compose_file() {
  local app_name="$1"
  local image="$2"
  local tag="$3"
  local port="$4"
  local output_file="$5"
  local env_vars="${6:-{}}"
  local volumes="${7:-}"
  local use_profiles="${8:-true}"
  local extra_hosts="${9:-}"

  uds_log "Generating docker-compose.yml for $app_name" "debug"

  # Apply secure permissions to the output file directory
  mkdir -p "$(dirname "$output_file")"
  uds_secure_permissions "$(dirname "$output_file")" 700

  # Start the compose file
  cat > "$output_file" << EOL
# Generated by Unified Deployment System
version: '3.8'

services:
EOL

  # For multiple images, create multiple services
  if [[ "$image" == *","* ]]; then
    # Split comma-separated list
    IFS=',' read -ra IMAGES <<< "$image"
    IFS=',' read -ra PORTS <<< "$port"
    
    for i in "${!IMAGES[@]}"; do
      local service_name=$(echo "${IMAGES[$i]}" | sed 's/.*\///' | sed 's/:.*//')
      local service_port=${PORTS[$i]:-3000}
      
      # Add the service configuration
      cat >> "$output_file" << EOL
  ${service_name}:
    image: ${IMAGES[$i]}:${tag}
    container_name: ${app_name}-${service_name}
EOL
      if [ "$use_profiles" = "true" ]; then
        cat >> "$output_file" << EOL
    profiles:
      - app
EOL
      fi
      
      cat >> "$output_file" << EOL
    restart: unless-stopped
    ports:
EOL
      
      # Handle port mapping format (host:container)
      if [[ "$service_port" == *":"* ]]; then
        local host_port=$(echo "$service_port" | cut -d: -f1)
        local container_port=$(echo "$service_port" | cut -d: -f2)
        echo "      - \"${host_port}:${container_port}\"" >> "$output_file"
      else
        echo "      - \"${service_port}:${service_port}\"" >> "$output_file"
      fi
      
      # Add environment variables
      if [ "$env_vars" != "{}" ]; then
        echo "    environment:" >> "$output_file"
        echo "$env_vars" | jq -r 'to_entries[] | "      - " + .key + "=" + .value' >> "$output_file"
      fi
      
      # Add volumes
      if [ -n "$volumes" ]; then
        echo "    volumes:" >> "$output_file"
        IFS=',' read -ra VOLUME_MAPPINGS <<< "$volumes"
        for volume in "${VOLUME_MAPPINGS[@]}"; do
          echo "      - $volume" >> "$output_file"
        done
      fi
      
      # Add extra hosts
      if [ -n "$extra_hosts" ]; then
        echo "    extra_hosts:" >> "$output_file"
        IFS=',' read -ra HOST_ENTRIES <<< "$extra_hosts"
        for host in "${HOST_ENTRIES[@]}"; do
          echo "      - $host" >> "$output_file"
        done
      fi
      
      # Add networks
      echo "    networks:" >> "$output_file"
      echo "      - ${app_name}-network" >> "$output_file"
    done
  else
    # Single service
    cat >> "$output_file" << EOL
  app:
    image: ${image}:${tag}
    container_name: ${app_name}-app
EOL
    if [ "$use_profiles" = "true" ]; then
      cat >> "$output_file" << EOL
    profiles:
      - app
EOL
    fi
    
    cat >> "$output_file" << EOL
    restart: unless-stopped
    ports:
EOL
    
    # Handle port mapping format (host:container)
    if [[ "$port" == *":"* ]]; then
      local host_port=$(echo "$port" | cut -d: -f1)
      local container_port=$(echo "$port" | cut -d: -f2)
      echo "      - \"${host_port}:${container_port}\"" >> "$output_file"
    else
      echo "      - \"${port}:${port}\"" >> "$output_file"
    fi
    
    # Add environment variables
    if [ "$env_vars" != "{}" ]; then
      echo "    environment:" >> "$output_file"
      echo "$env_vars" | jq -r 'to_entries[] | "      - " + .key + "=" + .value' >> "$output_file"
    fi
    
    # Add volumes
    if [ -n "$volumes" ]; then
      echo "    volumes:" >> "$output_file"
      IFS=',' read -ra VOLUME_MAPPINGS <<< "$volumes"
      for volume in "${VOLUME_MAPPINGS[@]}"; do
        echo "      - $volume" >> "$output_file"
      done
    fi
    
    # Add extra hosts
    if [ -n "$extra_hosts" ]; then
      echo "    extra_hosts:" >> "$output_file"
      IFS=',' read -ra HOST_ENTRIES <<< "$extra_hosts"
      for host in "${HOST_ENTRIES[@]}"; do
        echo "      - $host" >> "$output_file"
      done
    fi
    
    # Add networks
    echo "    networks:" >> "$output_file"
    echo "      - ${app_name}-network" >> "$output_file"
  fi

  # Add network configuration
  cat >> "$output_file" << EOL

networks:
  ${app_name}-network:
    name: ${app_name}-network
EOL

  # Secure the compose file
  uds_secure_permissions "$output_file" 600
  
  uds_log "Generated docker-compose.yml at $output_file" "debug"
}

# ============================================================
# NGINX FUNCTIONS
# ============================================================

# Create an Nginx configuration
uds_create_nginx_config() {
  local app_name="$1"
  local domain="$2"
  local route_type="$3"
  local route="$4"
  local port="$5"
  local use_ssl="${6:-true}"
  
  local config_file="${UDS_NGINX_DIR}/${app_name}.conf"
  local server_name="${domain}"
  
  # Determine server_name and location based on route type
  if [ "$route_type" = "subdomain" ]; then
    if [ -n "$route" ]; then
      server_name="${route}.${domain}"
    fi
    location="/"
  else
    # Path-based routing
    if [ -n "$route" ]; then
      location="/${route}"
      # Ensure location starts with / and doesn't have trailing /
      location=$(echo "$location" | sed 's#//*#/#' | sed 's#/$##')
    else
      location="/"
    fi
  fi
  
  # Create the Nginx configuration file
  cat > "$config_file" << EOL
# Generated by Unified Deployment System
# App: ${app_name}
# Domain: ${server_name}
# Route: ${location}

server {
    listen 80;
    listen [::]:80;
    server_name ${server_name};
EOL

  # Add SSL configuration if enabled
  if [ "$use_ssl" = "true" ]; then
    cat >> "$config_file" << EOL
    
    # Redirect HTTP to HTTPS
    location / {
        return 301 https://$host$request_uri;
    }
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name ${server_name};
    
    # SSL configuration
    ssl_certificate ${UDS_CERTS_DIR}/${server_name}/fullchain.pem;
    ssl_certificate_key ${UDS_CERTS_DIR}/${server_name}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;
    ssl_ciphers EECDH+AESGCM:EDH+AESGCM;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;
    
    # Security headers
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    add_header X-Content-Type-Options nosniff;
    add_header X-Frame-Options SAMEORIGIN;
    add_header X-XSS-Protection "1; mode=block";
EOL
  fi

  # Add location configuration
  cat >> "$config_file" << EOL
    
    location ${location} {
EOL

  # Strip prefix if path-based routing
  if [ "$route_type" = "path" ] && [ "$location" != "/" ]; then
    cat >> "$config_file" << EOL
        # Strip path prefix
        rewrite ^${location}(/.*)?$ $1 break;
EOL
  fi

  # Add proxy configuration
  cat >> "$config_file" << EOL
        proxy_pass http://localhost:${port};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_cache_bypass \$http_upgrade;
    }
EOL

  # Close the server block
  if [ "$use_ssl" != "true" ]; then
    echo "}" >> "$config_file"
  fi

  uds_log "Created Nginx configuration: ${config_file}" "info"
  
  # Return the filename for reference
  echo "$config_file"
}

# Reload Nginx configuration
uds_reload_nginx() {
  uds_log "Reloading Nginx configuration" "info"
  
  # Check if running in Docker
  if docker ps -q --filter "name=nginx-proxy" | grep -q .; then
    # Reload Nginx in the container
    docker exec nginx-proxy nginx -s reload
  else
    # Reload Nginx on the host
    nginx -s reload
  fi
  
  # Check if reload was successful
  if [ $? -eq 0 ]; then
    uds_log "Nginx configuration reloaded successfully" "success"
    return 0
  else
    uds_log "Failed to reload Nginx configuration" "error"
    return 1
  fi
}

# ============================================================
# SERVICE REGISTRY FUNCTIONS
# ============================================================

# Sanitize sensitive environment variables for logging
uds_sanitize_env_vars() {
  local input="$1"
  local sanitized="$input"
  
  # Patterns to sanitize - expanded to cover more sensitive data patterns
  local patterns=(
    "password=[^\"'& ]*"
    "passwd=[^\"'& ]*"
    "pass=[^\"'& ]*"
    "pwd=[^\"'& ]*"
    "secret=[^\"'& ]*"
    "key=[^\"'& ]*"
    "apikey=[^\"'& ]*"
    "api_key=[^\"'& ]*"
    "api-key=[^\"'& ]*"
    "access_key=[^\"'& ]*"
    "access-key=[^\"'& ]*"
    "token=[^\"'& ]*"
    "auth=[^\"'& ]*"
    "access_token=[^\"'& ]*"
    "refresh_token=[^\"'& ]*"
    "CLIENT_SECRET=[^\"'& ]*"
    "IDENTITY_KEY=[^\"'& ]*"
    "SIGNING_KEY=[^\"'& ]*"
    "ENCRYPTION_KEY=[^\"'& ]*"
    "LICENSE_KEY=[^\"'& ]*"
    "ACCOUNT_KEY=[^\"'& ]*"
    "MASTER_KEY=[^\"'& ]*"
    "ADMIN_KEY=[^\"'& ]*"
    "AWS_ACCESS_KEY=[^\"'& ]*"
    "AWS_SECRET_KEY=[^\"'& ]*"
    "AZURE_KEY=[^\"'& ]*"
    "GOOGLE_API_KEY=[^\"'& ]*"
    "SALESFORCE_TOKEN=[^\"'& ]*"
    "STRIPE_KEY=[^\"'& ]*"
    "STRIPE_SECRET=[^\"'& ]*"
    "PAYPAL_CLIENT_ID=[^\"'& ]*"
    "PAYPAL_SECRET=[^\"'& ]*"
    "TWILIO_AUTH_TOKEN=[^\"'& ]*"
    "MAILCHIMP_API_KEY=[^\"'& ]*"
    "OAUTH_CLIENT_SECRET=[^\"'& ]*"
    "SENDGRID_API_KEY=[^\"'& ]*"
    "API_SECRET=[^\"'& ]*"
  )
  
  # Apply sanitization to each pattern
  for pattern in "${patterns[@]}"; do
    sanitized=$(echo "$sanitized" | sed -E "s/($pattern)/\1=******/g")
  done
  
  # Sanitize JSON patterns in env vars - expanded to cover more keys
  sanitized=$(echo "$sanitized" | sed -E 's/"(password|secret|token|key|apikey|api_key|access_token|auth|cert|private_key|ssh_key)": *"[^"]*"/"\\1": "******"/g')
  
  # Sanitize connection strings with various formats
  sanitized=$(echo "$sanitized" | sed -E 's|([a-zA-Z]+://[^:]+:)[^@]+(@)|\\1******\\2|g')
  
  # Sanitize potential Base64 encoded secrets or JWTs (common pattern: long string with periods)
  sanitized=$(echo "$sanitized" | sed -E 's/eyJ[a-zA-Z0-9_-]{20,}\.[a-zA-Z0-9_-]{20,}\.[a-zA-Z0-9_-]{20,}/********/g')
  
  # Sanitize credit card numbers
  sanitized=$(echo "$sanitized" | sed -E 's/[0-9]{13,19}/XXXX-XXXX-XXXX-XXXX/g')
  
  # Sanitize auth headers in HTTP requests (Bearer tokens)
  sanitized=$(echo "$sanitized" | sed -E 's/(Authorization: Bearer) [a-zA-Z0-9._-]+/\1 ********/g')
  
  echo "$sanitized"
}

# Register a service in the registry
uds_register_service() {
  local app_name="$1"
  local domain="$2"
  local route_type="$3"
  local route="$4"
  local port="$5"
  local image="$6"
  local tag="$7"
  local is_persistent="${8:-false}"
  
  uds_log "Registering service: $app_name" "info"
  
  # Read the registry file
  local registry_data=$(cat "$UDS_REGISTRY_FILE")
  
  # Build the service entry
  local service_entry=$(cat << EOF
{
  "name": "${app_name}",
  "domain": "${domain}",
  "route_type": "${route_type}",
  "route": "${route}",
  "port": "${port}",
  "image": "${image}",
  "tag": "${tag}",
  "is_persistent": ${is_persistent},
  "registered_at": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
}
EOF
)

  # Get the current date and time for version tracking
  local deployment_time=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  
  # Check if service already exists to handle version history
  if echo "$registry_data" | jq -e --arg name "$app_name" '.services[$name]' > /dev/null; then
    # Get existing service data
    local existing_service=$(echo "$registry_data" | jq --arg name "$app_name" '.services[$name]')
    
    # Extract version history or create new array
    local version_history=$(echo "$existing_service" | jq -r '.version_history // []')
    
    # Add current version to history if different
    local current_version=$(echo "$existing_service" | jq -r '.tag // "unknown"')
    
    if [ "$current_version" != "$tag" ]; then
      # Create history entry
      local history_entry=$(cat << EOF
{
  "tag": "${current_version}",
  "deployed_at": $(echo "$existing_service" | jq '.registered_at // "unknown"'),
  "image": $(echo "$existing_service" | jq '.image // "unknown"')
}
EOF
)
      
      # Add to version history
      if [ "$version_history" = "[]" ]; then
        version_history="[$history_entry]"
      else
        version_history=$(echo "$version_history" | jq --argjson entry "$history_entry" '. + [$entry]')
      fi
      
      # Update service entry with version history
      service_entry=$(echo "$service_entry" | jq --argjson history "$version_history" '. + {"version_history": $history, "deployed_at": "'"$deployment_time"'"}')
    else
      # Same version, just update deployment time
      service_entry=$(echo "$service_entry" | jq --argjson history "$version_history" '. + {"version_history": $history, "deployed_at": "'"$deployment_time"'"}')
    fi
  else
    # New service, initialize version history
    service_entry=$(echo "$service_entry" | jq '. + {"version_history": [], "deployed_at": "'"$deployment_time"'"}')
  fi

  # Update the registry file
  local updated_registry=$(echo "$registry_data" | jq --arg name "$app_name" --argjson service "$service_entry" '.services[$name] = $service')
  echo "$updated_registry" > "$UDS_REGISTRY_FILE"
  
  uds_log "Service registered successfully: $app_name" "success"
  return 0
}

# Unregister a service from the registry
uds_unregister_service() {
  local app_name="$1"
  
  uds_log "Unregistering service: $app_name" "info"
  
  # Read the registry file
  local registry_data=$(cat "$UDS_REGISTRY_FILE")
  
  # Check if the service exists
  if ! echo "$registry_data" | jq -e --arg name "$app_name" '.services[$name]' > /dev/null; then
    uds_log "Service not found in registry: $app_name" "warning"
    return 1
  fi
  
  # Remove the service from the registry
  local updated_registry=$(echo "$registry_data" | jq --arg name "$app_name" 'del(.services[$name])')
  echo "$updated_registry" > "$UDS_REGISTRY_FILE"
  
  uds_log "Service unregistered successfully: $app_name" "success"
  return 0
}

# Get service information from the registry
uds_get_service() {
  local app_name="$1"
  
  # Read the registry file
  local registry_data=$(cat "$UDS_REGISTRY_FILE")
  
  # Get the service data
  local service_data=$(echo "$registry_data" | jq -e --arg name "$app_name" '.services[$name]')
  
  # Check if the service exists
  if [ $? -ne 0 ]; then
    return 1
  fi
  
  echo "$service_data"
  return 0
}

# List all registered services
uds_list_services() {
  # Read the registry file
  local registry_data=$(cat "$UDS_REGISTRY_FILE")
  
  # Get all service names
  local services=$(echo "$registry_data" | jq -r '.services | keys[]')
  
  echo "$services"
  return 0
}

# Initialize the UDS system
uds_init

# Export functions for use in other scripts
export -f uds_log uds_load_config uds_register_plugin_arg uds_register_plugin_hook
export -f uds_execute_hook uds_generate_compose_file
export -f uds_create_nginx_config uds_reload_nginx 
export -f uds_register_service uds_unregister_service uds_get_service uds_list_services
export -f uds_is_port_available uds_find_available_port uds_resolve_port_conflicts
export -f uds_secure_permissions uds_secure_delete