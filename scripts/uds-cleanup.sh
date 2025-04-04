#!/bin/bash
#
# uds-cleanup.sh - Cleanup script for Unified Deployment System
#
# This script handles cleanup of deployed applications

set -eo pipefail

# Determine base directory and load required modules
UDS_BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load essential modules directly
source "${UDS_BASE_DIR}/uds-env.sh"
source "${UDS_BASE_DIR}/uds-logging.sh"
source "${UDS_BASE_DIR}/uds-security.sh"

# Log execution start
uds_log "Loading UDS cleanup modules..." "debug"

# Load additional required modules
uds_load_module "uds-docker.sh"      # For Docker operations
uds_load_module "uds-service.sh"     # For service registry
uds_load_module "uds-nginx.sh"       # For Nginx configuration
uds_load_module "uds-plugin.sh"      # For plugin functionality

# Display help information
uds_show_help() {
  cat << EOL
=================================================================
Unified Deployment System - Cleanup Script
=================================================================

USAGE:
  ./uds-cleanup.sh [OPTIONS]

REQUIRED OPTIONS:
  --config=FILE            Path to configuration JSON file

ADDITIONAL OPTIONS:
  --keep-data              Don't remove data directories
  --force                  Force removal even for persistent services
  --log-level=LEVEL        Set log level (debug, info, warning, error)
  --dry-run                Show what would be done without actually doing it
  --help                   Show this help message

EXAMPLES:
  # Clean up an application
  ./uds-cleanup.sh --config=my-app-config.json

  # Clean up but keep data
  ./uds-cleanup.sh --config=my-app-config.json --keep-data

=================================================================
EOL
}

# Parse command-line arguments
uds_parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --config=*)
        CONFIG_FILE="${1#*=}"
        shift
        ;;
      --keep-data)
        KEEP_DATA=true
        shift
        ;;
      --force)
        FORCE=true
        shift
        ;;
      --log-level=*)
        UDS_LOG_LEVEL="${1#*=}"
        shift
        ;;
      --dry-run)
        DRY_RUN=true
        shift
        ;;
      --help)
        uds_show_help
        exit 0
        ;;
      *)
        uds_log "Unknown option: $1" "error"
        uds_show_help
        exit 1
        ;;
    esac
  done

  # Validate required parameters
  if [ -z "${CONFIG_FILE:-}" ]; then
    uds_log "Missing required parameter: --config" "error"
    uds_show_help
    exit 1
  fi
}

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
  
  uds_log "Loading configuration from $config_file" "info"
  
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
  export PORT_AUTO_ASSIGN VERSION_TRACKING APP_DIR PLUGINS
  
  # Load and discover plugins
  uds_discover_plugins
  
  # Activate configured plugins
  if [ -n "$PLUGINS" ]; then
    uds_activate_plugins "$PLUGINS"
  fi
  
  # Execute hook after configuration is loaded
  uds_execute_hook "config_loaded" "$APP_NAME"
  
  return 0
}

# Clean up application
uds_cleanup_application() {
  uds_log "Cleaning up application: $APP_NAME" "info"
  
  if [ "${DRY_RUN:-false}" = "true" ]; then
    uds_log "DRY RUN: Would clean up $APP_NAME" "info"
    return 0
  fi
  
  # Check if this is a persistent service
  local service_data=$(uds_get_service "$APP_NAME")
  if [ -n "$service_data" ]; then
    local is_persistent=$(echo "$service_data" | jq -r '.is_persistent // false')
    if [ "$is_persistent" = "true" ] && [ "${FORCE:-false}" != "true" ]; then
      uds_log "$APP_NAME is a persistent service. Use --force to remove it." "warning"
      return 1
    fi
  fi
  
  # Execute pre-cleanup hooks
  uds_execute_hook "pre_cleanup" "$APP_NAME" "$APP_DIR"
  
  # Stop and remove containers
  if docker ps -a --filter "name=${APP_NAME}-" | grep -q "${APP_NAME}-"; then
    uds_log "Stopping containers for $APP_NAME" "info"
    cd "$APP_DIR"
    
    # Use docker-compose if available, else direct docker commands
    if [ -f "$APP_DIR/docker-compose.yml" ]; then
      $UDS_DOCKER_COMPOSE_CMD -f "$APP_DIR/docker-compose.yml" down --remove-orphans
    else
      # Fallback to direct container removal
      docker stop $(docker ps -a -q --filter "name=${APP_NAME}-") 2>/dev/null || true
      docker rm $(docker ps -a -q --filter "name=${APP_NAME}-") 2>/dev/null || true
    fi
  fi
  
  # Check for errors during container cleanup
  if [ $? -ne 0 ]; then
    uds_log "Warning: Some containers may not have been properly stopped or removed" "warning"
    # Continue anyway 
  fi
  
  # Remove Nginx configuration
  if [ -f "${UDS_NGINX_DIR}/${APP_NAME}.conf" ]; then
    uds_log "Removing Nginx configuration for $APP_NAME" "info"
    rm -f "${UDS_NGINX_DIR}/${APP_NAME}.conf"
    
    # Reload Nginx
    uds_reload_nginx || {
      uds_log "Warning: Failed to reload Nginx configuration" "warning"
      # Continue anyway
    }
  fi
  
  # Remove data directories if not keeping data
  if [ "${KEEP_DATA:-false}" != "true" ]; then
    local data_dir="${PERSISTENCE_DATA_DIR:-${UDS_BASE_DIR}/data}/${APP_NAME}"
    if [ -d "$data_dir" ]; then
      uds_log "Removing data directory for $APP_NAME" "info"
      rm -rf "$data_dir"
    fi
  else
    uds_log "Keeping data directory for $APP_NAME" "info"
  fi
  
  # Remove application directory
  if [ -d "$APP_DIR" ]; then
    uds_log "Removing application directory: $APP_DIR" "info"
    rm -rf "$APP_DIR"
  fi
  
  # Unregister service
  uds_unregister_service "$APP_NAME"
  
  # Execute post-cleanup hooks
  uds_execute_hook "post_cleanup" "$APP_NAME"
  
  uds_log "Cleanup of $APP_NAME completed successfully" "success"
  return 0
}

# Main cleanup function
uds_do_cleanup() {
  # Parse command-line arguments
  uds_parse_args "$@"
  
  # Load configuration
  uds_load_config "$CONFIG_FILE" || {
    uds_log "Failed to load configuration" "error"
    return 1
  }
  
  # Clean up the application
  uds_cleanup_application || {
    uds_log "Cleanup failed" "error"
    return 1
  }
  
  return 0
}

# Execute cleanup if being run directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  uds_do_cleanup "$@"
  exit $?
fi