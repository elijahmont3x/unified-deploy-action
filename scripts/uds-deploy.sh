#!/bin/bash
#
# uds-deploy.sh - Main deployment script for Unified Deployment System
#
# This script handles the deployment workflow for applications

set -eo pipefail

# Determine base directory and load required modules
UDS_BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load essential modules directly
source "${UDS_BASE_DIR}/uds-env.sh"
source "${UDS_BASE_DIR}/uds-logging.sh"
source "${UDS_BASE_DIR}/uds-security.sh"

# Log execution start
uds_log "Loading UDS deployment system modules..." "debug"

# Load additional required modules - these are loaded as needed rather than all at once
uds_load_module "uds-docker.sh"       # For Docker operations
uds_load_module "uds-service.sh"      # For service registry
uds_load_module "uds-nginx.sh"        # For Nginx configuration

# Conditionally load modules based on need
if [ -f "${UDS_BASE_DIR}/uds-health.sh" ]; then
  uds_load_module "uds-health.sh"     # For health checks
fi

if [ -f "${UDS_BASE_DIR}/uds-dependency.sh" ]; then
  uds_load_module "uds-dependency.sh" # For dependency management
fi

# For plugin functionality
uds_load_module "uds-plugin.sh"

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
  export PORT_AUTO_ASSIGN VERSION_TRACKING MAX_LOG_LINES APP_DIR PLUGINS
  
  # Load and discover plugins
  uds_discover_plugins
  
  # Activate configured plugins
  if [ -n "$PLUGINS" ]; then
    uds_activate_plugins "$PLUGINS"
  fi
  
  return 0
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
    uds_pull_docker_images "$IMAGE" "$TAG" || {
      uds_log "Failed to pull required Docker images" "error"
      return 1
    }
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
  
  # Check if we're in dry run mode
  if [ "${DRY_RUN:-false}" = "true" ]; then
    uds_log "DRY RUN: Would deploy $APP_NAME" "info"
    return 0
  }
  
  # Change to application directory
  cd "$APP_DIR" || {
    uds_log "Failed to change to app directory: $APP_DIR" "error"
    return 1
  }
  
  # Check dependencies if needed
  if [ "${CHECK_DEPENDENCIES:-false}" = "true" ]; then
    if type uds_wait_for_dependencies &>/dev/null; then
      uds_log "Checking service dependencies" "info"
      uds_wait_for_dependencies "$APP_NAME" || {
        uds_log "Dependency check failed" "error"
        return 1
      }
    fi
  fi
  
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
    }
    
    return 1
  fi
  
  # Check application health if health module is available
  if type uds_health_check_with_retry &>/dev/null; then
    uds_log "Checking application health" "info"
    
    # Determine appropriate health check type if auto-detect is enabled
    if [ "$HEALTH_CHECK_TYPE" = "auto" ] && type uds_detect_health_check_type &>/dev/null; then
      local detected_type=$(uds_detect_health_check_type "$APP_NAME" "$IMAGE" "$HEALTH_CHECK")
      uds_log "Auto-detected health check type: $detected_type" "debug"
      HEALTH_CHECK_TYPE="$detected_type"
    fi
    
    if [ "$HEALTH_CHECK_TYPE" != "none" ]; then
      if ! uds_health_check_with_retry "$APP_NAME" "$PORT" "$HEALTH_CHECK" "5" "$HEALTH_CHECK_TIMEOUT" "$HEALTH_CHECK_TYPE" "${APP_NAME}-app" "$HEALTH_CHECK_COMMAND"; then
        uds_log "Health check failed" "error"
        
        # Execute health-check-failed hooks
        uds_execute_hook "health_check_failed" "$APP_NAME" "$APP_DIR"
        
        return 1
      fi
    fi
  fi
  
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
    
    # Execute pre-rollback hooks
    uds_execute_hook "pre_rollback" "$APP_NAME" "$APP_DIR"
    
    # Get previous version info
    local prev_version=$(echo "$version_history" | jq -r 'if length > 0 then .[length-1] else null end')
    local prev_image=$(echo "$prev_version" | jq -r '.image')
    local prev_tag=$(echo "$prev_version" | jq -r '.tag')
    
    # Set up rollback with previous version
    IMAGE="$prev_image"
    TAG="$prev_tag"
    export IMAGE TAG
    
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
}

# Multi-stage deployment implementation with improved reliability
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
  local deploy_timeout="${MULTI_STAGE_DEPLOY_TIMEOUT:-600}" # 10 minutes default
  
  # Deploy to staging with timeout
  (
    # Set timeout handler (if timeout command is available)
    if command -v timeout &>/dev/null; then
      timeout --foreground "$deploy_timeout" bash -c "cd '$APP_DIR' && uds_deploy_application"
      deploy_result=$?
    else
      # Fallback if timeout command is not available
      # Use a subshell with background process and wait
      (
        cd "$APP_DIR" || exit 1
        uds_deploy_application
      ) & 
      local deploy_pid=$!
      
      # Monitor the process with our own timeout
      local start_time=$(date +%s)
      local end_time=$((start_time + deploy_timeout))
      
      while [ "$(date +%s)" -lt "$end_time" ]; do
        # Check if process is still running
        if ! kill -0 $deploy_pid 2>/dev/null; then
          # Process completed, get exit status
          wait $deploy_pid
          deploy_result=$?
          break
        fi
        sleep 1
      done
      
      # If we're here and the process is still running, kill it
      if kill -0 $deploy_pid 2>/dev/null; then
        kill -TERM $deploy_pid 2>/dev/null || kill -KILL $deploy_pid 2>/dev/null
        deploy_result=124  # Use same exit code as timeout command
      fi
    fi
    
    exit $deploy_result
  )
  
  deploy_result=$?
  local deploy_duration=$(($(date +%s) - deploy_start_time))
  
  # Handle deployment result with improved logging and diagnostics
  if [ $deploy_result -ne 0 ]; then
    uds_log "Deployment to staging failed after ${deploy_duration}s (exit code: $deploy_result)" "error"
    
    # Collect more detailed diagnostic information on failure
    if [ -d "$APP_DIR" ]; then
      uds_log "Collecting diagnostic information from failed deployment" "info"
      
      # Check for Docker containers and logs
      if docker ps -a --filter "name=${APP_NAME}-" | grep -q .; then
        uds_log "Container logs from failed deployment:" "info"
        docker ps -a --filter "name=${APP_NAME}-" --format "{{.Names}}" | while read container; do
          uds_log "--- Logs for $container ---" "info"
          docker logs --tail=50 "$container" 2>&1 || true
          uds_log "--- End logs for $container ---" "info"
        done
      fi
      
      # Capture any Docker Compose logs
      if [ -f "$APP_DIR/docker-compose.yml" ]; then
        uds_log "Docker Compose configuration:" "info"
        cat "$APP_DIR/docker-compose.yml" || true
      fi
      
      # Capture Nginx configuration if present
      if [ -f "${UDS_NGINX_DIR}/${APP_NAME}.conf" ]; then
        uds_log "Nginx configuration:" "info"
        cat "${UDS_NGINX_DIR}/${APP_NAME}.conf" || true
      fi
    fi
    
    # Restore original APP_DIR
    APP_DIR="$saved_app_dir"
    export APP_DIR
    
    # Clean up staging directory
    uds_log "Cleaning up staging directory after failed deployment" "info"
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
      
      # Attempt to clean up staging but keep it for diagnosis
      uds_log "Keeping staging directory at $staging_dir for diagnosis" "warning"
      
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
  
  # Stage 5: Verification with enhanced health checking
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
    # Use enhanced multi-phase health check for thorough verification
    # First perform quick check with lower timeout
    local quick_check_timeout=$((HEALTH_CHECK_TIMEOUT / 2))
    local quick_check_attempts=3
    
    uds_log "Performing initial quick health check (timeout: ${quick_check_timeout}s)" "info"
    
    local quick_check_result=0
    if type uds_health_check_with_retry &>/dev/null; then
      uds_health_check_with_retry "$APP_NAME" "$PORT" "$HEALTH_CHECK" "$quick_check_attempts" "$quick_check_timeout" "$HEALTH_CHECK_TYPE" "${APP_NAME}-app" "$HEALTH_CHECK_COMMAND"
      quick_check_result=$?
    else
      # Fallback if enhanced health check isn't available
      # Simple sleep and basic check
      sleep 5
      if ! curl -s -o /dev/null -w "%{http_code}" "http://localhost:${PORT}${HEALTH_CHECK}" | grep -q "2[0-9][0-9]"; then
        quick_check_result=1
      fi
    fi
    
    # If quick check passes, perform thorough check
    if [ $quick_check_result -eq 0 ]; then
      uds_log "Initial health check passed, performing thorough verification" "info"
      
      # Set extra attempts and longer timeout for thorough post-deployment verification
      local verify_attempts=8
      local verify_timeout=$((HEALTH_CHECK_TIMEOUT * 2)) # Double the timeout for thorough verification
      
      uds_log "Verifying deployment with extended health check (timeout: ${verify_timeout}s)" "info"
      
      if type uds_health_check_with_retry &>/dev/null; then
        if ! uds_health_check_with_retry "$APP_NAME" "$PORT" "$HEALTH_CHECK" "$verify_attempts" "$verify_timeout" "$HEALTH_CHECK_TYPE" "${APP_NAME}-app" "$HEALTH_CHECK_COMMAND"; then
          uds_log "Deployment verification failed - health check did not pass thorough verification" "error"
          uds_perform_rollback "$original_dir" "$backup_dir" "$APP_NAME"
          return 0  # Return success since rollback handled the failure
        fi
      else
        # Fallback to basic checks if enhanced health check is unavailable
        sleep 10
        for i in {1..5}; do
          local status_code=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:${PORT}${HEALTH_CHECK}" 2>/dev/null || echo "000")
          if [[ "$status_code" =~ ^2[0-9][0-9]$ ]]; then
            break
          fi
          
          if [ $i -eq 5 ]; then
            uds_log "Deployment verification failed - basic health check failed after 5 attempts" "error"
            uds_perform_rollback "$original_dir" "$backup_dir" "$APP_NAME"
            return 0  # Return success since rollback handled the failure
          fi
          
          sleep 5
        done
      fi
    else
      uds_log "Initial health check failed - deployment appears unhealthy" "error"
      uds_perform_rollback "$original_dir" "$backup_dir" "$APP_NAME"
      return 0  # Return success since rollback handled the failure
    fi
  fi
  
  # Stage 6: Cleanup
  uds_log "Stage 6: Final cleanup and verification" "info"
  
  # Cleanup old backups after successful deployment and verification
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
  
  # Final status display with deployment URL if available
  local deployment_url=$(uds_get_service_url "$APP_NAME" "$SSL" 2>/dev/null)
  if [ -n "$deployment_url" ]; then
    uds_log "Multi-stage deployment completed successfully" "success"
    uds_log "Application is available at: $deployment_url" "success"
    
    # Store URL in an output file for GitHub Actions if running in that context
    if [ -n "$GITHUB_OUTPUT" ]; then
      echo "deployment_url=$deployment_url" >> $GITHUB_OUTPUT
      echo "status=success" >> $GITHUB_OUTPUT
    fi
  else
    uds_log "Multi-stage deployment completed successfully" "success"
  fi
  
  return 0
}


# Enhanced rollback function for multi-stage deployment
uds_perform_rollback() {
  local original_dir="$1"
  local backup_dir="$2"
  local app_name="$3"
  
  # Check if auto-rollback is enabled
  if [ "${AUTO_ROLLBACK:-true}" != "true" ]; then
    uds_log "Auto-rollback disabled. Deployment remains in failed state." "warning"
    return 1
  fi
  
  # Check if we have a backup to roll back to
  if [ ! -d "$backup_dir" ]; then
    uds_log "No backup found to roll back to" "error"
    return 1
  fi
  
  uds_log "Starting rollback to previous version" "warning"
  
  # Execute pre-rollback hooks
  uds_execute_hook "pre_rollback" "$app_name" "$original_dir"
  
  # Stop current deployment
  if [ -d "$original_dir" ]; then
    # Navigate to original directory and attempt to stop containers
    cd "$original_dir" || {
      uds_log "Failed to change to deployment directory for shutdown" "warning"
    }
    
    if [ -f "docker-compose.yml" ]; then
      uds_log "Stopping failed deployment with docker-compose" "info"
      $UDS_DOCKER_COMPOSE_CMD -f docker-compose.yml down 2>/dev/null || {
        uds_log "Warning: Failed to gracefully stop containers, forcing removal" "warning"
        # Force stop containers
        docker ps -a -q --filter "name=${app_name}-" | xargs docker stop 2>/dev/null || true
        docker ps -a -q --filter "name=${app_name}-" | xargs docker rm -f 2>/dev/null || true
      }
    else
      # Direct container removal fallback
      uds_log "No docker-compose.yml found, stopping containers directly" "info"
      docker ps -a -q --filter "name=${app_name}-" | xargs docker stop 2>/dev/null || true
      docker ps -a -q --filter "name=${app_name}-" | xargs docker rm -f 2>/dev/null || true
    }
    
    # Move current failing deployment to a timestamped failed directory for diagnosis
    local failed_dir="${original_dir}_failed_$(date +%s)"
    if [ -d "$original_dir" ]; then
      uds_log "Moving failed deployment to $failed_dir for diagnosis" "info"
      mv "$original_dir" "$failed_dir" || {
        uds_log "Failed to move failed deployment, attempting removal" "warning"
        rm -rf "$original_dir"
      }
    fi
  fi
  
  # Restore from backup
  uds_log "Restoring previous deployment from backup" "info"
  if ! mv "$backup_dir" "$original_dir"; then
    uds_log "Failed to restore from backup during rollback" "critical"
    
    # Try to recreate original directory if it doesn't exist
    if [ ! -d "$original_dir" ]; then
      mkdir -p "$original_dir"
    fi
    
    return 1
  fi
  
  # Start the previous version
  cd "$original_dir" || {
    uds_log "Failed to change to app directory" "critical"
    return 1
  }
  
  if [ -f "$original_dir/docker-compose.yml" ]; then
    uds_log "Restarting previous version with docker-compose" "info"
    
    if ! $UDS_DOCKER_COMPOSE_CMD -f docker-compose.yml up -d; then
      uds_log "Failed to start previous version" "critical"
      return 1
    fi
    
    # Verify previous version started successfully
    local container_name="${app_name}-app"
    if ! docker ps -q --filter "name=$container_name" | grep -q .; then
      uds_log "Container $container_name did not start during rollback" "error"
      return 1
    fi
    
    uds_log "Rollback completed successfully - reverted to previous version" "warning"
    
    # Execute rollback hooks
    uds_execute_hook "post_rollback" "$app_name" "$original_dir"
    
    return 0
  else
    uds_log "No docker-compose.yml found in backup, rollback incomplete" "error"
    return 1
  fi
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
    }
  fi
  
  return 0
}

# Execute deployment if being run directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  uds_do_deploy "$@"
  exit $?
fi