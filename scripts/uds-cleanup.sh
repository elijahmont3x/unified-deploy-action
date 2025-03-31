#!/bin/bash
#
# uds-cleanup.sh - Cleanup script for Unified Deployment System
#
# This script handles cleanup of deployed applications

set -eo pipefail

# Get script directory and load core module
UDS_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$UDS_SCRIPT_DIR/uds-core.sh"

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
    
    if [ -f "docker-compose.yml" ]; then
      $UDS_DOCKER_COMPOSE_CMD -f "docker-compose.yml" down --remove-orphans
    else
      # Fallback to direct container removal
      docker stop $(docker ps -a -q --filter "name=${APP_NAME}-") 2>/dev/null || true
      docker rm $(docker ps -a -q --filter "name=${APP_NAME}-") 2>/dev/null || true
    fi
  fi
  
  # Remove Nginx configuration
  if [ -f "${UDS_NGINX_DIR}/${APP_NAME}.conf" ]; then
    uds_log "Removing Nginx configuration for $APP_NAME" "info"
    rm -f "${UDS_NGINX_DIR}/${APP_NAME}.conf"
    
    # Reload Nginx
    uds_reload_nginx
  fi
  
  # Remove data directories if not keeping data
  if [ "${KEEP_DATA:-false}" != "true" ]; then
    if [ -d "${PERSISTENCE_DATA_DIR:-${UDS_BASE_DIR}/data}/${APP_NAME}" ]; then
      uds_log "Removing data directory for $APP_NAME" "info"
      rm -rf "${PERSISTENCE_DATA_DIR:-${UDS_BASE_DIR}/data}/${APP_NAME}"
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
  uds_load_config "$CONFIG_FILE"
  
  # Clean up the application
  uds_cleanup_application
  
  return $?
}

# Execute cleanup if being run directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  uds_do_cleanup "$@"
  exit $?
fi