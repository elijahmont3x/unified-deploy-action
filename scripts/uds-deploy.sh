#!/bin/bash
#
# uds-deploy.sh - Main deployment script for Unified Deployment System
#
# This script handles the deployment workflow for applications

set -eo pipefail

# Get script directory and load core module
UDS_BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$UDS_BASE_DIR/uds-core.sh"

# Display help information
uds_show_help() {
  cat << EOL
=================================================================
Unified Deployment System - Deploy Script
=================================================================

USAGE:
  ./uds-deploy.sh [OPTIONS]

REQUIRED OPTIONS:
  --config=FILE            Path to configuration JSON file

ADDITIONAL OPTIONS:
  --log-level=LEVEL        Set log level (debug, info, warning, error)
  --dry-run                Show what would be done without actually doing it
  --multi-stage            Use multi-stage deployment with validation
  --check-dependencies     Check if all required dependencies are satisfied
  --auto-rollback          Enable automatic rollback on failure
  --help                   Show this help message

EXAMPLES:
  # Deploy using a configuration file
  ./uds-deploy.sh --config=my-app-config.json

  # Deploy with debug logging
  ./uds-deploy.sh --config=my-app-config.json --log-level=debug

  # Deploy with multi-stage deployment
  ./uds-deploy.sh --config=my-app-config.json --multi-stage
=================================================================
EOL
}

# Parse command-line arguments
uds_parse_args() {
  # Initialize variables with defaults
  DRY_RUN=false
  MULTI_STAGE=false
  CHECK_DEPENDENCIES=false
  AUTO_ROLLBACK=true
  CONFIG_FILE=""
  
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --config=*)
        CONFIG_FILE="${1#*=}"
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
      --multi-stage)
        MULTI_STAGE=true
        shift
        ;;
      --check-dependencies)
        CHECK_DEPENDENCIES=true
        shift
        ;;
      --auto-rollback)
        AUTO_ROLLBACK=true
        shift
        ;;
      --no-rollback)
        AUTO_ROLLBACK=false
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
  if [ -z "${CONFIG_FILE}" ]; then
    uds_log "Missing required parameter: --config" "error"
    uds_show_help
    exit 1
  fi
  
  # Validate config file exists
  if [ ! -f "${CONFIG_FILE}" ]; then
    uds_log "Configuration file not found: ${CONFIG_FILE}" "error"
    exit 1
  fi
  
  # Export variables for use in other functions
  export DRY_RUN MULTI_STAGE CHECK_DEPENDENCIES AUTO_ROLLBACK
}

# Enhanced check_deploy_dependencies with improved error handling
uds_check_deploy_dependencies() {
  local app_name="$1"
  local image="$2"
  local tag="$3"
  
  uds_log "Checking dependencies for $app_name" "info"
  
  # System check - ensure Docker is running
  if ! docker info &>/dev/null; then
    uds_log "Docker is not running or not accessible" "error"
    return 1
  fi
  
  # Check disk space pre-emptively
  local required_space=1000 # 1GB for safety
  local available_space=$(df -m "$APP_DIR" | awk 'NR==2 {print $4}')
  
  if [ "$available_space" -lt "$required_space" ]; then
    uds_log "Insufficient disk space: ${available_space}MB available, ${required_space}MB required" "error"
    return 1
  fi
  
  # Skip Docker image check if doing a dry run
  if [ "${DRY_RUN}" != "true" ]; then
    # Check if images exist or can be pulled
    local failed_images=()
    
    # Handle multiple images if specified
    if [[ "$image" == *","* ]]; then
      IFS=',' read -ra IMAGES <<< "$image"
      
      for img in "${IMAGES[@]}"; do
        local img_clean=$(echo "$img" | tr -d ' ')
        uds_log "Checking if image $img_clean:$tag is available" "debug"
        
        if ! docker image inspect "$img_clean:$tag" &>/dev/null; then
          uds_log "Image $img_clean:$tag not found locally, attempting to pull" "info"
          if ! docker pull "$img_clean:$tag"; then
            failed_images+=("$img_clean:$tag")
          fi
        fi
      done
    else
      # Single image
      uds_log "Checking if image $image:$tag is available" "debug"
      
      if ! docker image inspect "$image:$tag" &>/dev/null; then
        uds_log "Image $image:$tag not found locally, attempting to pull" "info"
        if ! docker pull "$image:$tag"; then
          failed_images+=("$image:$tag")
        fi
      fi
    fi
    
    # Report failed images if any
    if [ ${#failed_images[@]} -gt 0 ]; then
      uds_log "Failed to pull the following images: ${failed_images[*]}" "error"
      return 1
    fi
  fi
  
  # Network connectivity check for multi-container setups
  if [[ "$image" == *","* ]]; then
    uds_log "Checking multi-container network connectivity" "info"
    if ! docker network ls | grep -q "${app_name}-network"; then
      uds_log "Network for $app_name doesn't exist yet, will be created during deployment" "info"
    fi
  fi
  
  # Check if ports are available with better error reporting
  local resolved_port=$(uds_resolve_port_conflicts "$PORT" "$APP_NAME")
  if [ -z "$resolved_port" ]; then
    uds_log "Failed to find available port for $app_name" "error"
    uds_log "Currently used ports:" "info"
    netstat -tuln 2>/dev/null || ss -tuln 2>/dev/null || echo "Port checking utilities not available"
    return 1
  elif [ "$resolved_port" != "$PORT" ]; then
    uds_log "Port $PORT is in use, using port $resolved_port instead" "warning"
    PORT="$resolved_port"
    export PORT
  fi
  
  # Check if required directories exist and can be written to
  if [ ! -d "$APP_DIR" ] && ! mkdir -p "$APP_DIR"; then
    uds_log "Failed to create directory $APP_DIR" "error"
    return 1
  fi
  
  # Check permissions
  if [ ! -w "$APP_DIR" ]; then
    uds_log "No write permission to $APP_DIR" "error"
    return 1
  fi
  
  uds_log "All dependencies satisfied for $app_name" "success"
  return 0
}

# Add automatic rollback for failed deployments
uds_deploy_with_rollback() {
  # Deploy with normal flow
  if uds_deploy_application; then
    uds_log "Deployment completed successfully" "success"
    return 0
  else
    uds_log "Deployment failed, initiating rollback..." "error"
    
    # Check if rollback is enabled
    if [ "${AUTO_ROLLBACK}" != "true" ]; then
      uds_log "Automatic rollback disabled, deployment remains in failed state" "warning"
      return 1
    fi
    
    # Check if we have rollback capability (version history)
    local service_data=$(uds_get_service "$APP_NAME")
    if [ -z "$service_data" ]; then
      uds_log "No previous version found, cannot rollback" "error"
      return 1
    fi
    
    # Extract version history
    local version_history=$(echo "$service_data" | jq -r '.version_history // []')
    if [ "$version_history" = "[]" ]; then
      uds_log "No version history found, cannot rollback" "error"
      return 1
    fi
    
    # Execute rollback
    uds_log "Rolling back to previous version" "warning"
    
    # Source rollback script if it exists
    if [ -f "$UDS_BASE_DIR/uds-rollback.sh" ]; then
      source "$UDS_BASE_DIR/uds-rollback.sh"
      if uds_do_rollback --config="$CONFIG_FILE"; then
        uds_log "Rollback successful" "warning"
        return 0
      else
        uds_log "Rollback failed" "critical"
        return 1
      fi
    else
      # Implement inline rollback if rollback script is not available
      uds_log "Rollback script not found, attempting direct rollback" "warning"
      
      # Get previous version info
      local prev_version=$(echo "$version_history" | jq -r 'if length > 0 then .[length-1] else null end')
      local prev_image=$(echo "$prev_version" | jq -r '.image')
      local prev_tag=$(echo "$prev_version" | jq -r '.tag')
      
      # Set up rollback with previous version
      IMAGE="$prev_image"
      TAG="$prev_tag"
      export IMAGE TAG
      
      # Execute pre-rollback hooks
      uds_execute_hook "pre_rollback" "$APP_NAME" "$APP_DIR"
      
      # Redeploy with previous version
      uds_log "Redeploying previous version: $prev_image:$prev_tag" "info"
      
      # Prepare and deploy
      if uds_prepare_deployment && uds_deploy_application; then
        uds_log "Rollback deployment successful" "success"
        
        # Execute post-rollback hooks
        uds_execute_hook "post_rollback" "$APP_NAME" "$APP_DIR"
        
        return 0
      else
        uds_log "Rollback deployment failed" "critical"
        return 1
      fi
    fi
  fi
}

# Update multi-stage deployment to use the new rollback functionality
uds_multi_stage_deployment() {
  local app_name="$1"
  
  uds_log "Starting multi-stage deployment for $app_name" "info"
  
  # Stage 1: Validation with enhanced checks
  uds_log "Stage 1: Validation" "info"
  
  # Check dependencies if flag is set
  if [ "${CHECK_DEPENDENCIES}" = "true" ] || [ "${MULTI_STAGE}" = "true" ]; then
    if ! uds_check_deploy_dependencies "$APP_NAME" "$IMAGE" "$TAG"; then
      uds_log "Dependency validation failed" "error"
      return 1
    fi
  fi
  
  # Stage 2: Preparation
  uds_log "Stage 2: Preparation" "info"
  
  # Create staging directory with unique timestamp to prevent collisions
  local timestamp=$(date +%s)
  local staging_dir="${APP_DIR}_staging_${timestamp}"
  
  # Remove any existing staging directory with the same name
  rm -rf "$staging_dir" 2>/dev/null || true
  
  # Create the staging directory
  if ! mkdir -p "$staging_dir"; then
    uds_log "Failed to create staging directory: $staging_dir" "error"
    return 1
  fi
  
  # Store original directory and create a backup
  local original_dir="$APP_DIR"
  local backup_dir="${original_dir}_backup_${timestamp}"
  
  # Save original APP_DIR value for restoration in case of failure
  local saved_app_dir="$APP_DIR"
  
  # Set APP_DIR to staging directory for preparation
  APP_DIR="$staging_dir"
  export APP_DIR
  
  # Prepare deployment in staging
  if ! uds_prepare_deployment; then
    uds_log "Deployment preparation failed in staging environment" "error"
    
    # Restore original APP_DIR
    APP_DIR="$saved_app_dir"
    export APP_DIR
    
    # Clean up staging directory
    rm -rf "$staging_dir" 2>/dev/null || true
    
    return 1
  fi
  
  # Stage 3: Deployment to staging
  uds_log "Stage 3: Deploying to staging environment" "info"
  
  # Deploy application to staging with robust error handling
  local deploy_start_time=$(date +%s)
  local deploy_result=0
  
  # Deploy to staging with timeout
  (
    # Set timeout handler (if timeout command is available)
    if command -v timeout &>/dev/null; then
      timeout --foreground 600 bash -c "cd '$APP_DIR' && uds_deploy_application"
      deploy_result=$?
    else
      # Fallback if timeout command is not available
      cd "$APP_DIR" && uds_deploy_application
      deploy_result=$?
    fi
    
    exit $deploy_result
  ) 
  
  deploy_result=$?
  local deploy_duration=$(($(date +%s) - deploy_start_time))
  
  if [ $deploy_result -ne 0 ]; then
    uds_log "Deployment to staging failed after ${deploy_duration}s" "error"
    
    # Restore original APP_DIR
    APP_DIR="$saved_app_dir"
    export APP_DIR
    
    # Clean up staging directory
    rm -rf "$staging_dir" 2>/dev/null || true
    
    return 1
  fi
  
  uds_log "Deployment to staging completed successfully (${deploy_duration}s)" "success"
  
  # Stage 4: Cutover with backup
  uds_log "Stage 4: Cutover - switching traffic to new deployment" "info"
  
  # Create backup of existing production deployment if it exists
  if [ -d "$original_dir" ]; then
    uds_log "Creating backup of current deployment at $backup_dir" "info"
    
    # Use atomic mv for more reliable backups
    if ! mv "$original_dir" "$backup_dir"; then
      uds_log "Failed to create backup, aborting cutover" "error"
      
      # Restore original APP_DIR
      APP_DIR="$saved_app_dir"
      export APP_DIR
      
      # Attempt to clean up staging
      rm -rf "$staging_dir" 2>/dev/null || true
      
      return 1
    fi
    
    # Check if backup was successful
    if [ ! -d "$backup_dir" ]; then
      uds_log "Backup directory not found after move, deployment may be in an inconsistent state" "error"
      
      # Restore original APP_DIR
      APP_DIR="$saved_app_dir"
      export APP_DIR
      return 1
    fi
  else
    uds_log "No existing deployment to backup" "info"
  fi
  
  # Move staging to production
  uds_log "Moving staging deployment to production" "info"
  
  if ! mv "$staging_dir" "$original_dir"; then
    uds_log "Failed to move staging to production" "error"
    
    # Attempt recovery from backup if it exists
    if [ -d "$backup_dir" ]; then
      uds_log "Attempting to restore from backup" "warning"
      
      if ! mv "$backup_dir" "$original_dir"; then
        uds_log "Failed to restore backup! Deployment may be in an inconsistent state" "critical"
        
        # Restore original APP_DIR
        APP_DIR="$saved_app_dir"
        export APP_DIR
        return 1
      fi
      
      uds_log "Successfully restored from backup" "warning"
    else
      # Try to create an empty directory as a last resort
      mkdir -p "$original_dir" || true
    fi
    
    # Restore original APP_DIR
    APP_DIR="$saved_app_dir"
    export APP_DIR
    return 1
  fi
  
  # Restore original APP_DIR path after successful move
  APP_DIR="$original_dir"
  export APP_DIR
  
  # Execute post-cutover hooks
  uds_execute_hook "post_cutover" "$APP_NAME" "$APP_DIR"
  
  # Stage 5: Verification
  uds_log "Stage 5: Verification - testing new deployment" "info"
  
  # Determine appropriate health check type if auto-detect is enabled
  if [ "$HEALTH_CHECK_TYPE" = "auto" ] && type uds_detect_health_check_type &>/dev/null; then
    local detected_type=$(uds_detect_health_check_type "$APP_NAME" "$IMAGE" "$HEALTH_CHECK")
    uds_log "Auto-detected health check type: $detected_type" "debug"
    HEALTH_CHECK_TYPE="$detected_type"
  fi
  
  # Skip health check if explicitly disabled
  if [ "$HEALTH_CHECK_TYPE" = "none" ] || [ "$HEALTH_CHECK" = "none" ] || [ "$HEALTH_CHECK" = "disabled" ]; then
    uds_log "Health check disabled, skipping verification" "info"
  else
    # Use enhanced health check function with proper error handling
    if type uds_health_check_with_retry &>/dev/null; then
      # Set extra attempts for post-deployment verification (more thorough than regular health check)
      local verify_attempts=8
      local verify_timeout=$((HEALTH_CHECK_TIMEOUT * 2)) # Double the timeout for verification
      
      uds_log "Verifying deployment with health check (timeout: ${verify_timeout}s)" "info"
      
      if ! uds_health_check_with_retry "$APP_NAME" "$PORT" "$HEALTH_CHECK" "$verify_attempts" "$verify_timeout" "$HEALTH_CHECK_TYPE" "${APP_NAME}-app" "$HEALTH_CHECK_COMMAND"; then
        uds_log "Deployment verification failed - health check did not pass" "error"
        
        # Roll back to previous version if backup exists
        if [ -d "$backup_dir" ] && [ "${AUTO_ROLLBACK:-true}" = "true" ]; then
          uds_log "Rolling back to previous version" "warning"
          
          # Stop current deployment
          docker ps -a -q --filter "name=${APP_NAME}-" | xargs docker stop 2>/dev/null || true
          
          # Remove current directory with force
          rm -rf "$APP_DIR"
          
          # Restore from backup
          if ! mv "$backup_dir" "$APP_DIR"; then
            uds_log "Failed to restore from backup during rollback" "critical"
            return 1
          fi
          
          # Start the previous version
          cd "$APP_DIR" || {
            uds_log "Failed to change to app directory" "critical"
            return 1
          }
          
          if [ -f "$APP_DIR/docker-compose.yml" ]; then
            uds_log "Restarting previous version" "warning"
            
            if ! $UDS_DOCKER_COMPOSE_CMD -f docker-compose.yml up -d; then
              uds_log "Failed to start previous version" "critical"
              return 1
            fi
            
            uds_log "Rollback completed successfully" "warning"
            
            # Execute rollback hooks
            uds_execute_hook "post_rollback" "$APP_NAME" "$APP_DIR"
            
            # Special case: we count this as a non-error return code
            # because the rollback itself was successful
            return 0
          fi
        else
          # No backup or auto-rollback disabled
          uds_log "No rollback performed, deployment is in an inconsistent state" "error"
          return 1
        fi
      fi
    fi
  fi
  
  # Check for any warnings during deployment
  if docker logs --since=5m "${APP_NAME}-app" 2>&1 | grep -i -E 'warn|error|exception|fatal' | grep -v 'info'; then
    uds_log "Warning: Potential issues detected in application logs" "warning"
  fi
  
  # Cleanup old backups after successful deployment
  if [ -d "$backup_dir" ]; then
    if [ "${KEEP_BACKUP:-false}" = "true" ]; then
      uds_log "Deployment successful. Backup kept at: $backup_dir" "info"
    else
      uds_log "Cleaning up old deployment backup" "info"
      # Schedule removal with delay to ensure everything is working
      (
        sleep 300 # Wait 5 minutes before removing backup
        if [ -d "$backup_dir" ]; then
          rm -rf "$backup_dir"
        fi
      ) &>/dev/null &
    fi
  fi
  
  uds_log "Multi-stage deployment completed successfully" "success"
  return 0
}

# Main deployment function
uds_do_deploy() {
  # Parse command-line arguments
  uds_parse_args "$@"
  
  # Load configuration
  uds_load_config "$CONFIG_FILE"
  
  # Execute hook after configuration is loaded
  uds_execute_hook "config_loaded" "$APP_NAME"
  
  # Check if we should use multi-stage deployment
  if [ "${MULTI_STAGE}" = "true" ]; then
    uds_multi_stage_deployment "$APP_NAME" || {
      uds_log "Multi-stage deployment failed" "error"
      return 1
    }
  else
    # Traditional deployment flow
    # Check dependencies if flag is set
    if [ "${CHECK_DEPENDENCIES}" = "true" ]; then
      if ! uds_check_deploy_dependencies "$APP_NAME" "$IMAGE" "$TAG"; then
        uds_log "Dependency check failed" "error"
        return 1
      fi
    fi
    
    # Prepare the deployment
    uds_prepare_deployment || {
      uds_log "Deployment preparation failed" "error"
      return 1
    }
    
    # Deploy the application with automatic rollback if enabled
    if [ "${AUTO_ROLLBACK}" = "true" ]; then
      uds_deploy_with_rollback || {
        uds_log "Deployment with rollback failed" "error"
        return 1
      }
    else
      # Deploy without rollback
      uds_deploy_application || {
        uds_log "Deployment failed" "error"
        return 1
      }
    fi
  fi
  
  return 0
}

# Execute deployment if being run directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  uds_do_deploy "$@"
  exit $?
fi