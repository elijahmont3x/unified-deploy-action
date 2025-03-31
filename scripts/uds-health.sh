#!/bin/bash
#
# uds-health.sh - Health check functionality for Unified Deployment System
#
# This script provides functions for checking application health

# Detect appropriate health check type for an application
uds_detect_health_check_type() {
  local app_name="$1"
  local image="$2"
  local health_endpoint="${3:-/health}"
  
  # Skip if health check is explicitly disabled
  if [ "$health_endpoint" = "none" ] || [ "$health_endpoint" = "disabled" ]; then
    echo "none"
    return 0
  fi
  
  # Check if this is a known container type that might not have HTTP
  if [[ "$image" == *"redis"* ]]; then
    echo "tcp"
    return 0
  elif [[ "$image" == *"postgres"* ]] || [[ "$image" == *"mysql"* ]] || [[ "$image" == *"mariadb"* ]]; then
    echo "tcp"
    return 0
  elif [[ "$image" == *"nginx"* ]] || [[ "$image" == *"httpd"* ]] || [[ "$image" == *"caddy"* ]]; then
    echo "http"
    return 0
  else
    # Default to http for most applications
    echo "http"
    return 0
  fi
}

# Check health of a deployed application
uds_check_health() {
  local app_name="$1"
  local port="$2"
  local health_endpoint="${3:-/health}"
  local timeout="${4:-60}"
  local health_type="${5:-http}" # http, tcp, container, command
  local container_name="${6:-}"
  local health_command="${7:-}"
  
  # Skip health check if explicitly disabled
  if [ "$health_endpoint" = "none" ] || [ "$health_endpoint" = "disabled" ]; then
    uds_log "Health check disabled for $app_name" "info"
    return 0
  fi
  
  uds_log "Checking health of $app_name using $health_type check" "info"
  
  # Determine container name if not provided for container checks
  if [ "$health_type" = "container" ] && [ -z "$container_name" ]; then
    container_name="${app_name}-app"
  fi
  
  local start_time=$(date +%s)
  local end_time=$((start_time + timeout))
  local current_time=$start_time
  
  while [ $current_time -lt $end_time ]; do
    # Attempt health check based on type
    case "$health_type" in
      http)
        # HTTP-based health check
        uds_log "HTTP health check: http://localhost:${port}${health_endpoint}" "debug"
        if curl -s -f -m 5 "http://localhost:${port}${health_endpoint}" &> /dev/null; then
          uds_log "HTTP health check passed for $app_name" "success"
          return 0
        fi
        ;;
      
      tcp)
        # TCP-based health check (just check if port is open)
        uds_log "TCP health check: port ${port}" "debug"
        if ! uds_is_port_available "$port"; then
          uds_log "TCP health check passed for $app_name" "success"
          return 0
        fi
        ;;
      
      container)
        # Container-based health check (check if container is running)
        uds_log "Container health check: $container_name" "debug"
        if docker inspect --format='{{.State.Running}}' "$container_name" 2>/dev/null | grep -q "true"; then
          # If container has health check, verify it
          local health_status=$(docker inspect --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$container_name" 2>/dev/null)
          
          if [ "$health_status" = "healthy" ]; then
            uds_log "Container health check passed for $app_name" "success"
            return 0
          elif [ "$health_status" = "none" ] || [ -z "$health_status" ]; then
            # No health check, running is enough
            uds_log "Container health check passed for $app_name (no HEALTHCHECK)" "success"
            return 0
          fi
        fi
        ;;
      
      command)
        # Command-based health check
        if [ -z "$health_command" ]; then
          uds_log "No health command specified" "error"
          return 1
        fi
        
        uds_log "Command health check: $health_command" "debug"
        if eval "$health_command"; then
          uds_log "Command health check passed for $app_name" "success"
          return 0
        fi
        ;;
      
      *)
        # Fallback to HTTP health check
        uds_log "Unknown health check type: $health_type, falling back to HTTP" "warning"
        if curl -s -f -m 5 "http://localhost:${port}${health_endpoint}" &> /dev/null; then
          uds_log "Fallback HTTP health check passed for $app_name" "success"
          return 0
        fi
        ;;
    esac
    
    # Wait and try again
    sleep 5
    current_time=$(date +%s)
    
    # Calculate remaining time
    local remaining=$((end_time - current_time))
    uds_log "Health check pending... ${remaining}s remaining" "debug"
  done
  
  uds_log "Health check failed for $app_name after ${timeout}s" "error"
  return 1
}

# Export functions
export -f uds_check_health uds_detect_health_check_type
