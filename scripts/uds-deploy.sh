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

# Check if all dependencies are satisfied
uds_check_deploy_dependencies() {
  local app_name="$1"
  local image="$2"
  local tag="$3"
  
  uds_log "Checking dependencies for $app_name" "info"
  
  # Check if image exists or can be pulled
  uds_log "Checking if image $image:$tag is available" "debug"
  
  if ! docker image inspect "$image:$tag" &>/dev/null; then
    uds_log "Image $image:$tag not found locally, attempting to pull" "info"
    if ! docker pull "$image:$tag"; then
      uds_log "Failed to pull image $image:$tag" "error"
      return 1
    fi
  fi
  
  # Check for multi-container dependencies
  if [[ "$image" == *","* ]]; then
    IFS=',' read -ra IMAGES <<< "$image"
    
    for img in "${IMAGES[@]}"; do
      if ! docker image inspect "$img:$tag" &>/dev/null; then
        uds_log "Image $img:$tag not found locally, attempting to pull" "info"
        if ! docker pull "$img:$tag"; then
          uds_log "Failed to pull image $img:$tag" "error"
          return 1
        fi
      fi
    done
  fi
  
  # Check if ports are available
  local resolved_port=$(uds_resolve_port_conflicts "$PORT" "$app_name")
  if [ -z "$resolved_port" ]; then
    uds_log "Failed to find available port for $app_name" "error"
    return 1
  fi
  
  # Check if required directories exist and can be written to
  if [ ! -d "$APP_DIR" ] && ! mkdir -p "$APP_DIR"; then
    uds_log "Failed to create directory $APP_DIR" "error"
    return 1
  fi
  
  # Check disk space
  local required_space=500 # 500MB minimum
  local available_space=$(df -m "$APP_DIR" | awk 'NR==2 {print $4}')
  
  if [ "$available_space" -lt "$required_space" ]; then
    uds_log "Insufficient disk space: ${available_space}MB available, ${required_space}MB required" "error"
    return 1
  fi
  
  uds_log "All dependencies satisfied for $app_name" "success"
  return 0
}

# Multi-stage deployment process
uds_multi_stage_deployment() {
  local app_name="$1"
  
  uds_log "Starting multi-stage deployment for $app_name" "info"
  
  # Stage 1: Validation
  uds_log "Stage 1: Validation" "info"
  
  # Check dependencies if flag is set
  if [ "${CHECK_DEPENDENCIES:-false}" = "true" ] || [ "${MULTI_STAGE:-false}" = "true" ]; then
    if ! uds_check_deploy_dependencies "$APP_NAME" "$IMAGE" "$TAG"; then
      uds_log "Dependency validation failed" "error"
      return 1
    fi
  fi
  
  # Stage 2: Preparation
  uds_log "Stage 2: Preparation" "info"
  if ! uds_prepare_deployment; then
    uds_log "Deployment preparation failed" "error"
    return 1
  fi
  
  # Stage 3: Deployment
  uds_log "Stage 3: Deployment" "info"
  
  # Create a staging directory for staged deployment
  local staging_dir="${APP_DIR}_staging"
  rm -rf "$staging_dir" || true
  mkdir -p "$staging_dir"
  
  # Clone the app configuration
  cp -a "$APP_DIR"/* "$staging_dir/" || true
  
  # Save original directory
  local original_dir="$APP_DIR"
  
  # Temporarily set the app directory to staging directory
  APP_DIR="$staging_dir"
  export APP_DIR
  
  # Deploy to staging
  if ! uds_deploy_application; then
    # Restore original directory path for cleanup
    APP_DIR="$original_dir"
    export APP_DIR
    
    # Clean up staging directory
    rm -rf "$staging_dir"
    
    uds_log "Deployment to staging environment failed" "error"
    return 1
  fi
  
  # Stage 4: Cutover
  uds_log "Stage 4: Cutover" "info"
  
  # Stop original deployment if it exists
  if docker ps -a --filter "name=${APP_NAME}-" | grep -q "${APP_NAME}-"; then
    uds_log "Stopping existing deployment" "info"
    
    # Check if we have original directory with docker-compose
    if [ -f "${original_dir}/docker-compose.yml" ]; then
      (cd "$original_dir" && $UDS_DOCKER_COMPOSE_CMD -f docker-compose.yml down) || true
    else
      # Try stopping directly
      docker stop $(docker ps -a -q --filter "name=${APP_NAME}-") 2>/dev/null || true
      docker rm $(docker ps -a -q --filter "name=${APP_NAME}-") 2>/dev/null || true
    fi
  fi
  
  # Swap staged deployment to production
  uds_log "Swapping staged deployment to production" "info"
  
  # Create backup of original
  if [ -d "$original_dir" ]; then
    mv "$original_dir" "${original_dir}_backup_$(date +%s)" || true
  fi
  
  # Move staging to production
  mv "$staging_dir" "$original_dir"
  
  # Restore original app directory path
  APP_DIR="$original_dir"
  export APP_DIR
  
  # Execute post-cutover hooks
  uds_execute_hook "post_cutover" "$APP_NAME" "$APP_DIR"
  
  # Stage 5: Verification
  uds_log "Stage 5: Verification" "info"
  
  # Determine appropriate health check type if auto-detect is enabled
  if [ "$HEALTH_CHECK_TYPE" = "auto" ] && type uds_detect_health_check_type &>/dev/null; then
    local detected_type=$(uds_detect_health_check_type "$APP_NAME" "$IMAGE" "$HEALTH_CHECK")
    uds_log "Auto-detected health check type: $detected_type" "debug"
    HEALTH_CHECK_TYPE="$detected_type"
  fi
  
  # Perform health check
  if [ "$HEALTH_CHECK_TYPE" != "none" ] && type uds_check_health &>/dev/null; then
    local container_name="${APP_NAME}-app"
    
    if ! uds_check_health "$APP_NAME" "$PORT" "$HEALTH_CHECK" "$HEALTH_CHECK_TIMEOUT" "$HEALTH_CHECK_TYPE" "$container_name" "$HEALTH_CHECK_COMMAND"; then
      uds_log "Post-deployment health check failed" "error"
      
      # Execute health-check-failed hooks
      uds_execute_hook "health_check_failed" "$APP_NAME" "$APP_DIR"
      
      return 1
    fi
  fi
  
  uds_log "Multi-stage deployment completed successfully" "success"
  return 0
}

# Prepare the deployment environment
uds_prepare_deployment() {
  uds_log "Preparing deployment for $APP_NAME" "info"
  
  # Create app directory
  mkdir -p "$APP_DIR"
  
  # Execute pre-deployment hooks
  uds_execute_hook "pre_deploy" "$APP_NAME" "$APP_DIR"
  
  # Resolve port conflicts if auto-assign is enabled
  if [ "${PORT_AUTO_ASSIGN:-true}" = "true" ]; then
    local resolved_port=$(uds_resolve_port_conflicts "$PORT" "$APP_NAME")
    if [ -n "$resolved_port" ]; then
      if [ "$resolved_port" != "$PORT" ]; then
        uds_log "Port $PORT is in use, using port $resolved_port instead" "warning"
        PORT="$resolved_port"
        export PORT
      fi
    else
      uds_log "Failed to resolve port conflicts" "error"
      return 1
    fi
  fi
  
  # Check if we need to generate a compose file
  if [ -z "${COMPOSE_FILE:-}" ]; then
    local compose_file="${APP_DIR}/docker-compose.yml"
    uds_generate_compose_file "$APP_NAME" "$IMAGE" "$TAG" "$PORT" "$compose_file" "$ENV_VARS" "$VOLUMES" "$USE_PROFILES" "$EXTRA_HOSTS"
    COMPOSE_FILE="$compose_file"
  else
    # Copy the provided compose file to app directory
    cp "$COMPOSE_FILE" "${APP_DIR}/docker-compose.yml"
    COMPOSE_FILE="${APP_DIR}/docker-compose.yml"
  fi
  
  # Check if we need to handle SSL
  if [ "$SSL" = "true" ]; then
    local server_name="$DOMAIN"
    if [ "$ROUTE_TYPE" = "subdomain" ] && [ -n "$ROUTE" ]; then
      server_name="${ROUTE}.${DOMAIN}"
    fi
    
    # Check if SSL plugin is available
    if type "plugin_ssl_check" &>/dev/null; then
      uds_log "Checking SSL certificates using SSL plugin" "debug"
      plugin_ssl_check "$APP_NAME"
    else
      # Check if SSL cert already exists
      if [ ! -d "${UDS_CERTS_DIR}/${server_name}" ]; then
        uds_log "Setting up SSL certificate for $server_name" "info"
        
        # Create cert directory
        mkdir -p "${UDS_CERTS_DIR}/${server_name}"
        
        # Generate self-signed certificate as fallback
        uds_log "No SSL plugin available, using self-signed certificate" "warning"
        openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
          -keyout "${UDS_CERTS_DIR}/${server_name}/privkey.pem" \
          -out "${UDS_CERTS_DIR}/${server_name}/fullchain.pem" \
          -subj "/CN=${server_name}"
      fi
    fi
  fi
  
  # Create Nginx configuration
  uds_create_nginx_config "$APP_NAME" "$DOMAIN" "$ROUTE_TYPE" "$ROUTE" "$PORT" "$SSL"
  
  uds_log "Deployment preparation completed" "success"
  return 0
}

# Deploy the application
uds_deploy_application() {
  uds_log "Deploying application: $APP_NAME" "info"
  
  if [ "${DRY_RUN:-false}" = "true" ]; then
    uds_log "DRY RUN: Would deploy $APP_NAME using $COMPOSE_FILE" "info"
    return 0
  fi
  
  # Stop existing containers if they exist
  if docker ps -a --filter "name=${APP_NAME}-" | grep -q "${APP_NAME}-"; then
    uds_log "Stopping existing containers for $APP_NAME" "info"
    cd "$APP_DIR"
    $UDS_DOCKER_COMPOSE_CMD -f "$COMPOSE_FILE" down || true
  fi
  
  # Execute pre-start hooks
  uds_execute_hook "pre_start" "$APP_NAME" "$APP_DIR"
  
  # Start the application
  uds_log "Starting $APP_NAME" "info"
  cd "$APP_DIR"
  
  # Determine if we need to use profiles
  if [ "$USE_PROFILES" = "true" ]; then
    $UDS_DOCKER_COMPOSE_CMD -f "$COMPOSE_FILE" --profile app up -d
  else
    $UDS_DOCKER_COMPOSE_CMD -f "$COMPOSE_FILE" up -d
  fi
  
  if [ $? -ne 0 ]; then
    uds_log "Failed to start $APP_NAME containers" "error"
    return 1
  fi
  
  # Execute post-start hooks
  uds_execute_hook "post_start" "$APP_NAME" "$APP_DIR"
  
  # Determine appropriate health check type if auto-detect is enabled
  if [ "$HEALTH_CHECK_TYPE" = "auto" ] && type uds_detect_health_check_type &>/dev/null; then
    local detected_type=$(uds_detect_health_check_type "$APP_NAME" "$IMAGE" "$HEALTH_CHECK")
    uds_log "Auto-detected health check type: $detected_type" "debug"
    HEALTH_CHECK_TYPE="$detected_type"
  fi
  
  # Perform health check if needed
  if [ "$HEALTH_CHECK_TYPE" != "none" ] && type uds_check_health &>/dev/null; then
    local container_name="${APP_NAME}-app"
    
    # Handle health check
    if ! uds_check_health "$APP_NAME" "$PORT" "$HEALTH_CHECK" "$HEALTH_CHECK_TIMEOUT" "$HEALTH_CHECK_TYPE" "$container_name" "$HEALTH_CHECK_COMMAND"; then
      uds_log "Application health check failed" "error"
      
      # Collect logs from failed container
      uds_log "Container logs for $container_name:" "info"
      docker logs --tail="${MAX_LOG_LINES:-100}" "$container_name" 2>&1 || true
      
      # Execute health-check-failed hooks
      uds_execute_hook "health_check_failed" "$APP_NAME" "$APP_DIR"
      
      return 1
    fi
  fi
  
  # Register the service
  uds_register_service "$APP_NAME" "$DOMAIN" "$ROUTE_TYPE" "$ROUTE" "$PORT" "$IMAGE" "$TAG" "$PERSISTENT"
  
  # Reload Nginx to apply configuration
  uds_reload_nginx
  
  # Execute post-deploy hooks
  uds_execute_hook "post_deploy" "$APP_NAME" "$APP_DIR"
  
  uds_log "Deployment of $APP_NAME completed successfully" "success"
  
  # Print access URL
  local url_scheme="http"
  if [ "$SSL" = "true" ]; then
    url_scheme="https"
  fi
  
  local access_url=""
  if [ "$ROUTE_TYPE" = "subdomain" ] && [ -n "$ROUTE" ]; then
    access_url="${url_scheme}://${ROUTE}.${DOMAIN}"
  elif [ "$ROUTE_TYPE" = "path" ] && [ -n "$ROUTE" ]; then
    access_url="${url_scheme}://${DOMAIN}/${ROUTE}"
  else
    access_url="${url_scheme}://${DOMAIN}"
  fi
  
  uds_log "Application available at: $access_url" "success"
  
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
  if [ "${MULTI_STAGE:-false}" = "true" ]; then
    uds_multi_stage_deployment "$APP_NAME" || {
      uds_log "Multi-stage deployment failed" "error"
      return 1
    }
  else
    # Traditional deployment flow
    # Check dependencies if flag is set
    if [ "${CHECK_DEPENDENCIES:-false}" = "true" ]; then
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
    
    # Deploy the application
    uds_deploy_application || {
      uds_log "Deployment failed" "error"
      return 1
    }
  fi
  
  return 0
}

# Execute deployment if being run directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  uds_do_deploy "$@"
  exit $?
fi