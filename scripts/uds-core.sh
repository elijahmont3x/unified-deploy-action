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
  ["success"]=5
)

# Current log level
UDS_LOG_LEVEL="${UDS_LOG_LEVEL:-info}"

# Color definitions for logs
declare -A UDS_LOG_COLORS=(
  ["debug"]="\033[0;37m"    # Gray
  ["info"]="\033[0;34m"     # Blue
  ["warning"]="\033[0;33m"  # Yellow
  ["error"]="\033[0;31m"    # Red
  ["critical"]="\033[1;31m" # Bold Red
  ["success"]="\033[0;32m"  # Green
)

# Reset color
UDS_COLOR_RESET="\033[0m"

# Enhanced plugin registry with dependencies
declare -A UDS_PLUGIN_REGISTRY=()
declare -A UDS_PLUGIN_ARGS=()
declare -A UDS_PLUGIN_HOOKS=()
declare -A UDS_PLUGIN_DEPENDENCIES=()
declare -a UDS_PLUGIN_EXECUTION_ORDER=()

# ============================================================
# INITIALIZATION FUNCTIONS
# ============================================================

# Initialize the UDS environment
uds_init() {
  # Create required directories
  mkdir -p "${UDS_CONFIGS_DIR}" "${UDS_LOGS_DIR}" "${UDS_CERTS_DIR}" "${UDS_NGINX_DIR}"
  
  # Ensure registry file exists
  if [ ! -f "${UDS_REGISTRY_FILE}" ]; then
    echo '{"services":{}}' > "${UDS_REGISTRY_FILE}"
    chmod 600 "${UDS_REGISTRY_FILE}"
  fi
  
  # Check for required tools
  uds_check_requirements
  
  # Load health check module if available
  if [ -f "${UDS_BASE_DIR}/uds-health.sh" ]; then
    source "${UDS_BASE_DIR}/uds-health.sh"
    export -f uds_check_health uds_detect_health_check_type
  fi
}

# Check for required tools and install missing ones if possible
uds_check_requirements() {
  local missing_tools=()
  
  # Check for Docker
  if ! command -v docker &>/dev/null; then
    missing_tools+=("docker")
  fi
  
  # Check for Docker Compose
  if ! $UDS_DOCKER_COMPOSE_CMD version &>/dev/null; then
    missing_tools+=("docker-compose")
  fi
  
  # Check for jq
  if ! command -v jq &>/dev/null; then
    missing_tools+=("jq")
  fi
  
  # Report missing tools
  if [ ${#missing_tools[@]} -gt 0 ]; then
    uds_log "Missing required tools: ${missing_tools[*]}" "warning"
    uds_log "Please install these tools before using UDS" "warning"
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
  local timestamp
  timestamp=$(date "${UDS_DATE_FORMAT}")
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
  
  chmod "$perms" "$target" || {
    uds_log "Failed to set permissions on $target" "error"
    return 1
  }
  
  return 0
}

# Securely delete sensitive files
uds_secure_delete() {
  local target="$1"
  
  if [ ! -e "$target" ]; then
    return 0
  fi
  
  # Try shred if available (most secure)
  if command -v shred &>/dev/null; then
    shred -u -z "$target"
  # Try srm if available
  elif command -v srm &>/dev/null; then
    srm -z "$target"
  # Fallback to simple overwrite and remove
  else
    dd if=/dev/zero of="$target" bs=1k count=1 conv=notrunc &>/dev/null || true
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
  
  # Validate JSON syntax
  if ! jq empty "$config_file" 2>/dev/null; then
    uds_log "Invalid JSON in configuration file" "error"
    return 1
  fi
  
  # Load configuration values
  APP_NAME=$(jq -r '.app_name // ""' "$config_file")
  COMMAND=$(jq -r '.command // "deploy"' "$config_file")
  IMAGE=$(jq -r '.image // ""' "$config_file")
  TAG=$(jq -r '.tag // "latest"' "$config_file")
  DOMAIN=$(jq -r '.domain // ""' "$config_file")
  ROUTE_TYPE=$(jq -r '.route_type // "path"' "$config_file")
  ROUTE=$(jq -r '.route // ""' "$config_file")
  PORT=$(jq -r '.port // "3000"' "$config_file")
  SSL=$(jq -r '.ssl // true' "$config_file")
  SSL_EMAIL=$(jq -r '.ssl_email // ""' "$config_file")
  ENV_VARS=$(jq -r '.env_vars // {}' "$config_file")
  VOLUMES=$(jq -r '.volumes // ""' "$config_file")
  PERSISTENT=$(jq -r '.persistent // false' "$config_file")
  COMPOSE_FILE=$(jq -r '.compose_file // ""' "$config_file")
  USE_PROFILES=$(jq -r '.use_profiles // true' "$config_file")
  MULTI_STAGE=$(jq -r '.multi_stage // false' "$config_file")
  CHECK_DEPENDENCIES=$(jq -r '.check_dependencies // false' "$config_file")
  HEALTH_CHECK=$(jq -r '.health_check // "/health"' "$config_file")
  HEALTH_CHECK_TYPE=$(jq -r '.health_check_type // "auto"' "$config_file")
  HEALTH_CHECK_TIMEOUT=$(jq -r '.health_check_timeout // 60' "$config_file")
  HEALTH_CHECK_COMMAND=$(jq -r '.health_check_command // ""' "$config_file")
  PORT_AUTO_ASSIGN=$(jq -r '.port_auto_assign // true' "$config_file")
  VERSION_TRACKING=$(jq -r '.version_tracking // true' "$config_file")
  PLUGINS=$(jq -r '.plugins // ""' "$config_file")
  
  # Set APP_DIR based on APP_NAME
  APP_DIR="${UDS_BASE_DIR}/${APP_NAME}"
  
  # Export variables
  export APP_NAME COMMAND IMAGE TAG DOMAIN ROUTE_TYPE ROUTE PORT SSL SSL_EMAIL 
  export VOLUMES PERSISTENT COMPOSE_FILE USE_PROFILES MULTI_STAGE CHECK_DEPENDENCIES
  export HEALTH_CHECK HEALTH_CHECK_TYPE HEALTH_CHECK_TIMEOUT HEALTH_CHECK_COMMAND 
  export PORT_AUTO_ASSIGN VERSION_TRACKING MAX_LOG_LINES APP_DIR PLUGINS
  
  # Load and discover plugins
  uds_discover_plugins
  
  # Activate configured plugins
  if [ -n "$PLUGINS" ]; then
    uds_activate_plugins "$PLUGINS"
  fi
  
  return 0
}

# ============================================================
# PLUGIN SYSTEM
# ============================================================

# Discover and register available plugins
uds_discover_plugins() {
  local plugin_dir="${UDS_PLUGINS_DIR}"
  
  if [ ! -d "$plugin_dir" ]; then
    uds_log "Plugin directory not found: $plugin_dir" "warning"
    return 0
  fi
  
  # Clear existing plugin registry
  UDS_PLUGIN_REGISTRY=()
  
  # Find and source plugin files
  for plugin_file in "$plugin_dir"/*.sh; do
    if [ -f "$plugin_file" ]; then
      uds_log "Loading plugin: $(basename "$plugin_file")" "debug"
      
      # Source the plugin file
      source "$plugin_file"
      
      # Extract plugin name from filename
      local plugin_name=$(basename "$plugin_file" .sh)
      local register_func="plugin_register_${plugin_name//-/_}"
      
      # Check if registration function exists and call it
      if declare -f "$register_func" > /dev/null; then
        uds_log "Registering plugin: $plugin_name" "debug"
        "$register_func"
        UDS_PLUGIN_REGISTRY["$plugin_name"]=1
      else
        uds_log "Plugin registration function not found: $register_func" "warning"
      fi
    fi
  done
  
  uds_log "Registered ${#UDS_PLUGIN_REGISTRY[@]} plugins" "debug"
}

# Activate specific plugins
uds_activate_plugins() {
  local plugins_to_activate="$1"
  
  if [ -z "$plugins_to_activate" ]; then
    return 0
  fi
  
  IFS=',' read -ra PLUGIN_ARRAY <<< "$plugins_to_activate"
  
  for plugin in "${PLUGIN_ARRAY[@]}"; do
    plugin=$(echo "$plugin" | tr -d ' ')
    
    if [ -n "${UDS_PLUGIN_REGISTRY[$plugin]:-}" ]; then
      local activate_func="plugin_activate_${plugin//-/_}"
      
      if declare -f "$activate_func" > /dev/null; then
        uds_log "Activating plugin: $plugin" "debug"
        "$activate_func"
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
  
  UDS_PLUGIN_ARGS["${plugin}_${arg_name}"]="$default_value"
  
  # If the value isn't already set, set it to the default
  if [ -z "${!arg_name+x}" ]; then
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
  
  # Initialize hook registry if needed
  if [ -z "${UDS_PLUGIN_HOOKS[$hook_key]:-}" ]; then
    UDS_PLUGIN_HOOKS["$hook_key"]="$hook_function"
  else
    UDS_PLUGIN_HOOKS["$hook_key"]="${UDS_PLUGIN_HOOKS[$hook_key]},$hook_function"
  fi
}

# Register a plugin dependency
uds_register_plugin_dependency() {
  local plugin="$1"
  local depends_on="$2"
  
  # Initialize dependency array if it doesn't exist
  if [ -z "${UDS_PLUGIN_DEPENDENCIES[$plugin]:-}" ]; then
    UDS_PLUGIN_DEPENDENCIES["$plugin"]=""
  fi
  
  # Add the dependency
  if [ -n "${UDS_PLUGIN_DEPENDENCIES[$plugin]}" ]; then
    UDS_PLUGIN_DEPENDENCIES["$plugin"]="${UDS_PLUGIN_DEPENDENCIES[$plugin]},${depends_on}"
  else
    UDS_PLUGIN_DEPENDENCIES["$plugin"]="$depends_on"
  fi
  
  uds_log "Registered dependency: $plugin depends on $depends_on" "debug"
}

# Sort plugins in dependency order using topological sort
uds_sort_plugins() {
  local plugin_list="$1"
  
  # Skip if no plugins specified
  if [ -z "$plugin_list" ]; then
    return 0
  fi
  
  # Split comma-separated list
  IFS=',' read -ra PLUGINS_ARRAY <<< "$plugin_list"
  
  # Build dependency graph
  declare -A graph=()
  declare -A visited=()
  declare -A temp_mark=()
  
  for plugin in "${PLUGINS_ARRAY[@]}"; do
    if [ -n "${UDS_PLUGIN_DEPENDENCIES[$plugin]:-}" ]; then
      IFS=',' read -ra DEPS <<< "${UDS_PLUGIN_DEPENDENCIES[$plugin]}"
      graph["$plugin"]="${UDS_PLUGIN_DEPENDENCIES[$plugin]}"
    else
      graph["$plugin"]=""
    fi
    visited["$plugin"]=0
  done
  
  # Reset execution order
  UDS_PLUGIN_EXECUTION_ORDER=()
  
  # Topological sort
  for plugin in "${!graph[@]}"; do
    if [ "${visited[$plugin]:-0}" -eq 0 ]; then
      _uds_visit_plugin "$plugin" graph visited temp_mark
    fi
  done
  
  # Return sorted list
  local sorted_plugins=$(IFS=,; echo "${UDS_PLUGIN_EXECUTION_ORDER[*]}")
  echo "$sorted_plugins"
}

# Helper function for topological sort
_uds_visit_plugin() {
  local plugin="$1"
  local -n _graph="$2"
  local -n _visited="$3"
  local -n _temp="$4"
  
  # Check for circular dependency
  if [ "${_temp[$plugin]:-0}" -eq 1 ]; then
    uds_log "Circular dependency detected involving plugin: $plugin" "error"
    return 1
  fi
  
  # Skip if already visited
  if [ "${_visited[$plugin]:-0}" -eq 1 ]; then
    return 0
  fi
  
  # Mark temporarily
  _temp["$plugin"]=1
  
  # Visit dependencies
  if [ -n "${_graph[$plugin]:-}" ]; then
    IFS=',' read -ra DEPS <<< "${_graph[$plugin]}"
    for dep in "${DEPS[@]}"; do
      if [ -n "$dep" ]; then
        _uds_visit_plugin "$dep" _graph _visited _temp
      fi
    done
  fi
  
  # Mark as visited
  _visited["$plugin"]=1
  _temp["$plugin"]=0
  
  # Add to sorted list (reverse order)
  UDS_PLUGIN_EXECUTION_ORDER=("$plugin" "${UDS_PLUGIN_EXECUTION_ORDER[@]}")
}

# Updated execute hook function with dependency-ordered execution
uds_execute_hook() {
  local hook_name="$1"
  shift
  
  local hook_key="${hook_name}"
  
  if [ -n "${UDS_PLUGIN_HOOKS[$hook_key]:-}" ]; then
    # Sort plugins by dependency order and then execute hooks
    local sorted_plugins=$(uds_sort_plugins "$PLUGINS")
    
    if [ -n "$sorted_plugins" ]; then
      uds_log "Executing hook $hook_name in dependency order: $sorted_plugins" "debug"
      
      # First, collect all hook functions
      local all_hook_functions=()
      IFS=',' read -ra HOOK_FUNCTIONS <<< "${UDS_PLUGIN_HOOKS[$hook_key]}"
      
      # Map hook functions to their plugins
      declare -A hook_plugin_map=()
      for hook_function in "${HOOK_FUNCTIONS[@]}"; do
        # Extract plugin name from function name (assuming format plugin_*_function)
        local plugin_name=$(echo "$hook_function" | sed -n 's/plugin_\([^_]*\)_.*/\1/p')
        hook_plugin_map["$hook_function"]="$plugin_name"
      done
      
      # Execute hooks in dependency order
      IFS=',' read -ra SORTED_PLUGINS <<< "$sorted_plugins"
      for plugin in "${SORTED_PLUGINS[@]}"; do
        for hook_function in "${HOOK_FUNCTIONS[@]}"; do
          if [ "${hook_plugin_map[$hook_function]}" = "$plugin" ]; then
            uds_log "Executing hook: $hook_function for $hook_name" "debug"
            if ! "$hook_function" "$@"; then
              uds_log "Hook execution failed: $hook_function" "warning"
            fi
          fi
        done
      done
    else
      # Fallback to unsorted execution if sorting fails
      uds_log "Executing hook $hook_name (unsorted)" "debug"
      IFS=',' read -ra HOOK_FUNCTIONS <<< "${UDS_PLUGIN_HOOKS[$hook_key]}"
      for hook_function in "${HOOK_FUNCTIONS[@]}"; do
        uds_log "Executing hook: $hook_function for $hook_name" "debug"
        if ! "$hook_function" "$@"; then
          uds_log "Hook execution failed: $hook_function" "warning"
        fi
      done
    fi
  fi
}

# Export the new functions
export -f uds_register_plugin_dependency uds_sort_plugins

# ============================================================
# PORT MANAGEMENT
# ============================================================

# Check if a port is available
uds_is_port_available() {
  local port="$1"
  local host="${2:-localhost}"
  
  # Try netstat if available
  if command -v netstat &>/dev/null; then
    if netstat -tuln | grep -q ":$port "; then
      return 1
    fi
  # Try ss if available
  elif command -v ss &>/dev/null; then
    if ss -tuln | grep -q ":$port "; then
      return 1
    fi
  # Fallback to direct check
  else
    if ! (echo >/dev/tcp/$host/$port) 2>/dev/null; then
      return 0
    else
      return 1
    fi
  fi
  
  return 0
}

# Find an available port starting from a base port
uds_find_available_port() {
  local base_port="$1"
  local max_port="${2:-65535}"
  local increment="${3:-1}"
  local host="${4:-localhost}"
  
  local current_port="$base_port"
  
  while [ "$current_port" -le "$max_port" ]; do
    if uds_is_port_available "$current_port" "$host"; then
      echo "$current_port"
      return 0
    fi
    
    current_port=$((current_port + increment))
  done
  
  return 1
}

# Resolve port conflicts automatically
uds_resolve_port_conflicts() {
  local port="$1"
  local app_name="$2"
  
  if uds_is_port_available "$port"; then
    echo "$port"
    return 0
  fi
  
  if [ "${PORT_AUTO_ASSIGN:-true}" = "true" ]; then
    uds_log "Port $port is already in use, finding an alternative" "warning"
    
    local available_port=$(uds_find_available_port "$port")
    
    if [ -n "$available_port" ]; then
      uds_log "Using alternative port: $available_port" "warning"
      echo "$available_port"
      return 0
    else
      uds_log "Failed to find an available port" "error"
      return 1
    fi
  else
    uds_log "Port $port is already in use and auto-assign is disabled" "error"
    return 1
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

# Sanitize sensitive environment variables for logging
uds_sanitize_env_vars() {
  local input="$1"
  local sanitized="$input"
  
  # Enhanced patterns to sanitize - expanded to cover more sensitive data patterns
  local patterns=(
    "[A-Za-z0-9_-]+_PASSWORD"
    "[A-Za-z0-9_-]+_PASS"
    "[A-Za-z0-9_-]+_SECRET"
    "[A-Za-z0-9_-]+_KEY"
    "[A-Za-z0-9_-]+_TOKEN"
    "[A-Za-z0-9_-]+_CREDENTIALS"
    "PASSWORD[A-Za-z0-9_-]*"
    "ACCESS_TOKEN[A-Za-z0-9_-]*"
    "SECRET[A-Za-z0-9_-]*"
    "APIKEY[A-Za-z0-9_-]*"
    "API_KEY[A-Za-z0-9_-]*"
    "PRIVATE_KEY[A-Za-z0-9_-]*"
    "AUTH[A-Za-z0-9_-]*_TOKEN"
    "TOKEN[A-Za-z0-9_-]*"
  )
  
  # Apply sanitization to each pattern
  for pattern in "${patterns[@]}"; do
    sanitized=$(echo "$sanitized" | sed -E "s/($pattern)=([^[:space:]]+)/\1=******/g")
    sanitized=$(echo "$sanitized" | sed -E "s/($pattern): *([^[:space:]]+)/\1: ******/g")
  done
  
  # Enhanced JSON pattern sanitization - covers more keys and formats
  sanitized=$(echo "$sanitized" | sed -E 's/"(password|passwd|pass|secret|token|apitoken|key|apikey|api_key|access_token|auth|credentials|cert|private_key|ssh_key|encryption_key)"\s*:\s*"[^"]*"/"\\1": "******"/g')
  
  echo "$sanitized"
}

# Export functions for use in other scripts
export -f uds_log uds_load_config uds_register_plugin_arg uds_register_plugin_hook
export -f uds_execute_hook uds_generate_compose_file
export -f uds_create_nginx_config uds_reload_nginx 
export -f uds_register_service uds_unregister_service uds_get_service uds_list_services
export -f uds_is_port_available uds_find_available_port uds_resolve_port_conflicts
export -f uds_secure_permissions uds_secure_delete

# Initialize on load
uds_init