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
# shellcheck disable=SC2034
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

  # Add support for cleanup-specific parameters
  CLEANUP_IMAGES="$(get_input "CLEANUP_IMAGES" "false")"
  CLEANUP_IMAGES_AGE="$(get_input "CLEANUP_IMAGES_AGE" "168h")"
  CLEANUP_VOLUMES="$(get_input "CLEANUP_VOLUMES" "false")"
  CLEANUP_NETWORKS="$(get_input "CLEANUP_NETWORKS" "false")"
  PRESERVE_DATA="$(get_input "PRESERVE_DATA" "")"
  
  # Export variables for use in other functions
  export CLEANUP_IMAGES CLEANUP_IMAGES_AGE CLEANUP_VOLUMES CLEANUP_NETWORKS PRESERVE_DATA

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
  
  # Use centralized config loading utility
  if ! uds_init_config "$config_file"; then
    uds_log "Failed to load configuration from $config_file" "error"
    return 1
  fi
  
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
      docker stop "$(docker ps -a -q --filter "name=${APP_NAME}-")" 2>/dev/null || true
      docker rm "$(docker ps -a -q --filter "name=${APP_NAME}-")" 2>/dev/null || true
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

# Clean up Docker resources based on parameters
uds_cleanup_docker_resources() {
  uds_log "Cleaning up Docker resources" "info"
  
  if [ "${DRY_RUN}" = "true" ]; then
    uds_log "DRY RUN: Would clean up Docker resources" "info"
    return 0
  fi

  # Remove old images if enabled
  if [ "${CLEANUP_IMAGES}" = "true" ]; then
    uds_log "Removing old Docker images (older than ${CLEANUP_IMAGES_AGE})" "info"
    docker image prune -af --filter "until=${CLEANUP_IMAGES_AGE}" || {
      uds_log "Failed to prune Docker images" "warning"
    }
  fi
  
  # Clean up unused volumes if enabled
  if [ "${CLEANUP_VOLUMES}" = "true" ]; then
    uds_log "Cleaning up unused Docker volumes" "info"
    
    # Handle preserved volumes
    if [ -n "${PRESERVE_DATA}" ]; then
      uds_log "Preserving volumes: ${PRESERVE_DATA}" "info"
      # Create grep exclusion pattern for preserved volumes
      local preserve_pattern=$(echo "${PRESERVE_DATA}" | tr ',' '|')
      # List dangling volumes and exclude preserved ones
      docker volume ls -qf dangling=true | grep -Ev "${preserve_pattern}" | xargs -r docker volume rm || {
        uds_log "Failed to prune Docker volumes" "warning"
      }
    else
      # No volumes to preserve, remove all dangling volumes
      docker volume prune -f || {
        uds_log "Failed to prune Docker volumes" "warning"
      }
    fi
  fi
  
  # Clean up unused networks if enabled
  if [ "${CLEANUP_NETWORKS}" = "true" ]; then
    uds_log "Cleaning up unused Docker networks" "info"
    docker network prune -f || {
      uds_log "Failed to prune Docker networks" "warning"
    }
  fi
  
  uds_log "Docker resource cleanup completed" "success"
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
  
  # Add call to docker resource cleanup function
  uds_cleanup_docker_resources
  
  return 0
}

# Execute cleanup if being run directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  uds_do_cleanup "$@"
  exit $?
fi