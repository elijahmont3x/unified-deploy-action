#!/bin/bash
#
# uds-deploy.sh - Main deployment script for Unified Deployment System
#
# This script handles the deployment workflow for applications

set -eo pipefail

# Get script directory and load core module
UDS_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$UDS_SCRIPT_DIR/uds-core.sh"

# Load health check module if not already loaded
if ! type uds_check_health &>/dev/null && [ -f "${UDS_SCRIPT_DIR}/uds-health.sh" ]; then
  source "${UDS_SCRIPT_DIR}/uds-health.sh"
fi

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
  --help                   Show this help message

EXAMPLES:
  # Deploy using a configuration file
  ./uds-deploy.sh --config=my-app-config.json

  # Deploy with debug logging
  ./uds-deploy.sh --config=my-app-config.json --log-level=debug

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

# Prepare the deployment environment
uds_prepare_deployment() {
  uds_log "Preparing deployment for $APP_NAME" "info"
  
  # Create app directory
  mkdir -p "$APP_DIR"
  
  # Execute pre-deployment hooks
  uds_execute_hook "pre_deploy" "$APP_NAME" "$APP_DIR"
  
  # Resolve port conflicts
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
    
    # Check if SSL cert already exists
    if [ ! -d "${UDS_CERTS_DIR}/${server_name}" ]; then
      uds_log "Setting up SSL certificate for $server_name" "info"
      
      # Create cert directory
      mkdir -p "${UDS_CERTS_DIR}/${server_name}"
      
      # Check for optional SSL plugin
      if type "plugin_ssl_setup" &>/dev/null; then
        plugin_ssl_setup "$server_name" "$SSL_EMAIL" "${UDS_CERTS_DIR}/${server_name}"
      else
        uds_log "No SSL plugin available, using self-signed certificate" "warning"
        
        # Generate self-signed certificate
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
  
  # Execute post-start hooks
  uds_execute_hook "post_start" "$APP_NAME" "$APP_DIR"
  
  # Determine appropriate health check type
  local health_check_type=$(uds_detect_health_check_type "$APP_NAME" "$IMAGE" "$HEALTH_CHECK")
  
  # Check if container has a HEALTHCHECK defined
  if [ "$health_check_type" != "none" ]; then
    local container_name="${APP_NAME}-app"
    
    # Handle health check based on detected type
    if ! uds_check_health "$APP_NAME" "$PORT" "$HEALTH_CHECK" "$HEALTH_CHECK_TIMEOUT" "$health_check_type" "$container_name"; then
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
  
  # Prepare the deployment
  uds_prepare_deployment
  
  # Deploy the application
  uds_deploy_application
  
  return $?
}

# Execute deployment if being run directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  uds_do_deploy "$@"
  exit $?
fi