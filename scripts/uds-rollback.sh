#!/bin/bash
#
# uds-rollback.sh - Automated rollback script for Unified Deployment System
#
# This script handles rollback to a previous version in case of deployment failure

set -eo pipefail

# Get script directory and load core module
UDS_BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$UDS_BASE_DIR/uds-core.sh"

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

# Roll back to a previous version
uds_do_rollback() {
  # Parse command-line arguments
  uds_parse_args "$@"
  
  # Load configuration
  uds_load_config "$CONFIG_FILE"
  
  # Execute hook after configuration is loaded
  uds_execute_hook "config_loaded" "$APP_NAME"
  
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
