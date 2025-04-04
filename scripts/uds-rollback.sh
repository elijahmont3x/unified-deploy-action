#!/bin/bash
#
# uds-rollback.sh - Automated rollback script for Unified Deployment System
#
# This script handles rollback to a previous version in case of deployment failure

set -eo pipefail

# Determine base directory and load required modules
UDS_BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load essential modules directly
source "${UDS_BASE_DIR}/uds-env.sh"
source "${UDS_BASE_DIR}/uds-logging.sh"
source "${UDS_BASE_DIR}/uds-security.sh"

# Log execution start
uds_log "Loading UDS rollback modules..." "debug"

# Load additional required modules
uds_load_module "uds-docker.sh"       # For Docker operations
uds_load_module "uds-service.sh"      # For service registry
uds_load_module "uds-nginx.sh"        # For Nginx configuration
uds_load_module "uds-plugin.sh"       # For plugin functionality

# Display help information
uds_show_help() {
  cat << EOL
=================================================================
Unified Deployment System - Rollback Script
=================================================================

USAGE:
  ./uds-rollback.sh [OPTIONS]

REQUIRED OPTIONS:
  --config=FILE            Path to configuration JSON file

ADDITIONAL OPTIONS:
  --version=TAG            Specific version to rollback to (default: previous)
  --log-level=LEVEL        Set log level (debug, info, warning, error)
  --help                   Show this help message

EXAMPLES:
  # Rollback to the previous version
  ./uds-rollback.sh --config=my-app-config.json

  # Rollback to a specific version
  ./uds-rollback.sh --config=my-app-config.json --version=v1.2.3
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
      --version=*)
        TARGET_VERSION="${1#*=}"
        shift
        ;;
      --log-level=*)
        UDS_LOG_LEVEL="${1#*=}"
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

# Get previous version information from registry
uds_get_previous_version() {
  local app_name="$1"
  
  # Get service information from registry
  local service_data=$(uds_get_service "$app_name")
  if [ -z "$service_data" ]; then
    uds_log "No registry entry found for $app_name" "error"
    return 1
  fi
  
  # Extract version history
  local version_history=$(echo "$service_data" | jq -r '.version_history // []')
  if [ "$version_history" = "[]" ]; then
    uds_log "No version history found for $app_name" "error"
    return 1
  fi
  
  # Get the most recent previous version
  local prev_version=$(echo "$version_history" | jq -r 'if length > 0 then .[length-1] else null end')
  if [ -z "$prev_version" ] || [ "$prev_version" = "null" ]; then
    uds_log "No previous version found for $app_name" "error"
    return 1
  fi
  
  # Extract image and tag
  local prev_image=$(echo "$prev_version" | jq -r '.image')
  local prev_tag=$(echo "$prev_version" | jq -r '.tag')
  
  if [ -z "$prev_image" ] || [ -z "$prev_tag" ]; then
    uds_log "Invalid previous version data for $app_name" "error"
    return 1
  fi
  
  # Return the data
  echo "$prev_image" "$prev_tag"
  return 0
}

# Prepare the deployment environment
uds_prepare_deployment() {
  uds_log "Preparing deployment for $APP_NAME" "info"
  
  # Create app directory if it doesn't exist
  mkdir -p "$APP_DIR" || {
    uds_log "Failed to create app directory: $APP_DIR" "error"
    return 1
  }
  
  # Execute pre-deploy hooks
  uds_execute_hook "pre_deploy" "$APP_NAME" "$APP_DIR"
  
  # Check if we need to generate a Docker Compose file
  if [ -z "$COMPOSE_FILE" ] || [ ! -f "$COMPOSE_FILE" ]; then
    uds_log "Generating Docker Compose file" "info"
    
    local compose_file="${APP_DIR}/docker-compose.yml"
    uds_generate_compose_file "$APP_NAME" "$IMAGE" "$TAG" "$PORT" "$compose_file" "$ENV_VARS" "$VOLUMES" "$USE_PROFILES" "$EXTRA_HOSTS"
  else
    # Copy the provided compose file
    uds_log "Using provided Docker Compose file: $COMPOSE_FILE" "info"
    cp "$COMPOSE_FILE" "${APP_DIR}/docker-compose.yml" || {
      uds_log "Failed to copy compose file from $COMPOSE_FILE" "error"
      return 1
    }
  fi
  
  # Set up Nginx configuration if domain is provided
  if [ -n "$DOMAIN" ]; then
    uds_log "Setting up Nginx configuration" "info"
    uds_create_nginx_config "$APP_NAME" "$DOMAIN" "$ROUTE_TYPE" "$ROUTE" "$PORT" "$SSL"
    
    # Set up SSL if enabled
    if [ "$SSL" = "true" ] && [ -n "$DOMAIN" ]; then
      uds_log "Setting up SSL" "info"
      
      # Check if SSL plugin is available
      if type plugin_ssl_check &>/dev/null; then
        plugin_ssl_check "$APP_NAME"
      fi
    fi
  fi
  
  uds_log "Deployment preparation completed successfully" "success"
  return 0
}

# Deploy the application
uds_deploy_application() {
  uds_log "Deploying $APP_NAME" "info"
  
  # Change to application directory
  cd "$APP_DIR" || {
    uds_log "Failed to change to app directory: $APP_DIR" "error"
    return 1
  }
  
  # Deploy with Docker Compose
  uds_log "Starting application containers" "info"
  
  local deploy_cmd="$UDS_DOCKER_COMPOSE_CMD -f docker-compose.yml up -d"
  
  # Add profile if using profiles
  if [ "${USE_PROFILES:-true}" = "true" ]; then
    deploy_cmd="$deploy_cmd --profile app"
  fi
  
  # Execute deployment command
  eval "$deploy_cmd" || {
    uds_log "Failed to start application containers" "error"
    
    # Get container logs if available
    if docker ps -a -q --filter "name=${APP_NAME}-" | grep -q .; then
      uds_log "Container logs (last ${MAX_LOG_LINES:-20} lines):" "info"
      uds_get_container_logs "${APP_NAME}-app" "${MAX_LOG_LINES:-20}" || true
    fi
    
    return 1
  }
  
  # Register the service in the registry
  if [ "${VERSION_TRACKING:-true}" = "true" ]; then
    uds_log "Registering service in registry" "info"
    uds_register_service "$APP_NAME" "$DOMAIN" "$ROUTE_TYPE" "$ROUTE" "$PORT" "$IMAGE" "$TAG" "$PERSISTENT"
  fi
  
  # Reload Nginx if needed
  if [ -n "$DOMAIN" ]; then
    uds_log "Reloading Nginx configuration" "info"
    uds_reload_nginx || {
      uds_log "Failed to reload Nginx configuration, but deployment continues" "warning"
    }
  fi
  
  # Execute post-deploy hooks
  uds_execute_hook "post_deploy" "$APP_NAME" "$APP_DIR"
  
  uds_log "Deployment completed successfully" "success"
  return 0
}

# Roll back to a previous version
uds_do_rollback() {
  # Parse command-line arguments
  uds_parse_args "$@"
  
  # Load configuration
  uds_load_config "$CONFIG_FILE"
  
  uds_log "Starting rollback for $APP_NAME" "info"
  
  local rollback_image=""
  local rollback_tag=""
  
  # If a specific version was requested, use it
  if [ -n "${TARGET_VERSION:-}" ]; then
    rollback_tag="$TARGET_VERSION"
    rollback_image="$IMAGE"
    uds_log "Rolling back to specified version: $rollback_tag" "info"
  else
    # Get previous version from registry
    local prev_version_data=$(uds_get_previous_version "$APP_NAME")
    if [ $? -ne 0 ]; then
      uds_log "Failed to get previous version information" "error"
      return 1
    fi
    
    # Split the result into image and tag
    rollback_image=$(echo "$prev_version_data" | cut -d' ' -f1)
    rollback_tag=$(echo "$prev_version_data" | cut -d' ' -f2)
    
    uds_log "Rolling back to previous version: $rollback_image:$rollback_tag" "info"
  fi
  
  # Set the image and tag to the rollback version
  IMAGE="$rollback_image"
  TAG="$rollback_tag"
  
  # Execute pre-rollback hooks
  uds_execute_hook "pre_rollback" "$APP_NAME" "$APP_DIR"
  
  # Use the deployment function to deploy the previous version
  uds_log "Deploying previous version..." "info"
  
  # Prepare deployment first
  uds_prepare_deployment || {
    uds_log "Rollback preparation failed" "error"
    return 1
  }
  
  # Deploy the previous version
  uds_deploy_application || {
    uds_log "Rollback deployment failed" "error"
    return 1
  }
  
  # Execute post-rollback hooks
  uds_execute_hook "post_rollback" "$APP_NAME" "$APP_DIR"
  
  uds_log "Rollback completed successfully" "success"
  return 0
}

# Execute rollback if being run directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  uds_do_rollback "$@"
  exit $?
fi