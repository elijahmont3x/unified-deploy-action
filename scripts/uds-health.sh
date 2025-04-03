#!/bin/bash
#
# uds-health.sh - Health check functionality for Unified Deployment System
#
# This script provides functions for checking application health

# Avoid sourcing multiple times
if [ -n "$UDS_HEALTH_LOADED" ]; then
  return 0
fi
UDS_HEALTH_LOADED=1

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
  
  # Enhanced container type detection for better health check selection
  if [[ "$image" == *"redis"* ]]; then
    echo "tcp"
    return 0
  elif [[ "$image" == *"postgres"* ]] || [[ "$image" == *"mysql"* ]] || [[ "$image" == *"mariadb"* ]]; then
    echo "database"
    return 0
  elif [[ "$image" == *"mongo"* ]]; then
    echo "database"
    return 0
  elif [[ "$image" == *"rabbitmq"* ]]; then
    echo "rabbitmq"
    return 0
  elif [[ "$image" == *"kafka"* ]]; then
    echo "kafka"
    return 0
  elif [[ "$image" == *"elasticsearch"* ]]; then
    echo "elasticsearch"
    return 0
  elif [[ "$image" == *"nginx"* ]] || [[ "$image" == *"httpd"* ]] || [[ "$image" == *"caddy"* ]]; then
    echo "http"
    return 0
  else
    # Default to http for most applications, but try to detect from container
    local container_name="${app_name}-app"
    if docker inspect --format='{{.State.Health}}' "$container_name" &>/dev/null; then
      # Container has health check defined
      echo "container"
      return 0
    fi
    
    echo "http"
    return 0
  fi
}

# Base health check function - no retry logic
uds_check_health() {
  local app_name="$1"
  local port="$2"
  local health_endpoint="${3:-/health}"
  local timeout="${4:-60}"
  local health_type="${5:-http}" # http, tcp, database, container, command, rabbitmq, elasticsearch, kafka
  local container_name="${6:-}"
  local health_command="${7:-}"
  
  # Skip health check if explicitly disabled
  if [ "$health_endpoint" = "none" ] || [ "$health_endpoint" = "disabled" ]; then
    uds_log "Health check disabled for $app_name" "info"
    return 0
  fi
  
  uds_log "Checking health of $app_name using $health_type check" "info"
  
  # Determine container name if not provided for container checks
  if [ -z "$container_name" ]; then
    container_name="${app_name}-app"
  fi
  
  local start_time=$(date +%s)
  local end_time=$((start_time + timeout))
  local current_time=$start_time
  local check_interval=5
  local error_message=""
  
  while [ $current_time -lt $end_time ]; do
    # Attempt health check based on type
    case "$health_type" in
      http)
        # HTTP-based health check
        uds_log "HTTP health check: http://localhost:${port}${health_endpoint}" "debug"
        local http_result=$(curl -s -o /dev/null -w "%{http_code}" -m 5 "http://localhost:${port}${health_endpoint}" 2>/dev/null)
        
        if [ "$http_result" -ge 200 ] && [ "$http_result" -lt 300 ]; then
          uds_log "HTTP health check passed with status $http_result for $app_name" "success"
          return 0
        elif [ "$http_result" -ge 300 ]; then
          error_message="HTTP status $http_result returned from health check endpoint"
        else
          error_message="Failed to connect to health check endpoint"
        fi
        ;;
      
      tcp)
        # TCP-based health check (just check if port is open)
        uds_log "TCP health check: port ${port}" "debug"
        if ! uds_is_port_available "$port"; then
          uds_log "TCP health check passed for $app_name (port $port is in use)" "success"
          return 0
        else
          error_message="TCP port $port is not open"
        fi
        ;;
      
      database)
        # Specialized database health check
        uds_log "Database health check for $container_name" "debug"
        if ! docker ps -q --filter "name=$container_name" | grep -q .; then
          error_message="Database container $container_name is not running"
        elif docker exec $container_name pg_isready 2>/dev/null; then
          # PostgreSQL ready
          uds_log "PostgreSQL health check passed for $app_name" "success"
          return 0
        elif docker exec $container_name mysqladmin ping --silent 2>/dev/null; then
          # MySQL ready
          uds_log "MySQL health check passed for $app_name" "success"
          return 0
        elif docker exec $container_name mongo --eval "db.adminCommand('ping')" 2>/dev/null | grep -q "ok" ; then
          # MongoDB ready
          uds_log "MongoDB health check passed for $app_name" "success"
          return 0
        else
          error_message="Database is not ready"
        fi
        ;;
      
      container)
        # Container-based health check (check if container is running and healthy)
        uds_log "Container health check: $container_name" "debug"
        if ! docker ps -q --filter "name=$container_name" | grep -q .; then
          error_message="Container $container_name is not running"
        else
          # If container has health check, verify it
          local health_status=$(docker inspect --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$container_name" 2>/dev/null)
          
          if [ "$health_status" = "healthy" ]; then
            uds_log "Container health check passed for $app_name (container reports healthy)" "success"
            return 0
          elif [ "$health_status" = "none" ] || [ -z "$health_status" ]; then
            # No health check, check if running is enough
            if docker inspect --format='{{.State.Running}}' "$container_name" 2>/dev/null | grep -q "true"; then
              uds_log "Container health check passed for $app_name (container is running)" "success"
              return 0
            else
              error_message="Container is not running"
            fi
          else
            error_message="Container health check status: $health_status"
            # Get the last health check log
            local health_log=$(docker inspect --format='{{if .State.Health}}{{range $i, $h := (index .State.Health.Log 0)}}{{$h}}{{end}}{{end}}' "$container_name" 2>/dev/null)
            if [ -n "$health_log" ]; then
              error_message="$error_message - Last health check: $health_log"
            fi
          fi
        fi
        ;;
      
      rabbitmq)
        # RabbitMQ specific health check
        uds_log "RabbitMQ health check for $container_name" "debug"
        if docker exec $container_name rabbitmqctl status 2>/dev/null | grep -q "RabbitMQ"; then
          uds_log "RabbitMQ health check passed for $app_name" "success"
          return 0
        else
          error_message="RabbitMQ is not ready"
        fi
        ;;
        
      elasticsearch)
        # Elasticsearch specific health check
        uds_log "Elasticsearch health check on port ${port}" "debug"
        if curl -s "http://localhost:${port}/_cluster/health" 2>/dev/null | grep -q "status"; then
          uds_log "Elasticsearch health check passed for $app_name" "success"
          return 0
        else
          error_message="Elasticsearch is not ready"
        fi
        ;;
        
      kafka)
        # Kafka specific health check
        uds_log "Kafka health check for $container_name" "debug"
        if docker exec $container_name kafka-topics.sh --bootstrap-server localhost:9092 --list 2>/dev/null; then
          uds_log "Kafka health check passed for $app_name" "success"
          return 0
        else
          error_message="Kafka is not ready"
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
        else
          error_message="Custom health check command failed"
        fi
        ;;
      
      *)
        # Fallback to HTTP health check
        uds_log "Unknown health check type: $health_type, falling back to HTTP" "warning"
        if curl -s -f -m 5 "http://localhost:${port}${health_endpoint}" &> /dev/null; then
          uds_log "Fallback HTTP health check passed for $app_name" "success"
          return 0
        else
          error_message="Fallback HTTP health check failed"
        fi
        ;;
    esac
    
    # Wait and try again
    sleep $check_interval
    current_time=$(date +%s)
    
    # Calculate remaining time
    local remaining=$((end_time - current_time))
    local elapsed=$((current_time - start_time))
    local percent_complete=$((elapsed * 100 / (timeout)))
    
    # Display progress
    uds_log "Health check pending... ${remaining}s remaining (${percent_complete}% elapsed) - Last error: ${error_message}" "debug"
    
    # Increase check interval for longer timeouts to reduce log noise
    if [ $elapsed -gt 30 ] && [ $check_interval -lt 10 ]; then
      check_interval=10
    fi
  done
  
  # Collect diagnostics on failure
  uds_log "Health check failed for $app_name after ${timeout}s: $error_message" "error"
  
  # Check if container exists and collect logs
  if docker ps -a -q --filter "name=$container_name" | grep -q .; then
    uds_log "Container logs for $container_name (last ${MAX_LOG_LINES:-20} lines):" "info"
    docker logs --tail="${MAX_LOG_LINES:-20}" "$container_name" 2>&1 || true
    
    # Check container status
    local container_status=$(docker inspect --format='{{.State.Status}}' "$container_name" 2>/dev/null)
    uds_log "Container status: $container_status" "info"
    
    # If container exited, get exit code
    if [ "$container_status" = "exited" ]; then
      local exit_code=$(docker inspect --format='{{.State.ExitCode}}' "$container_name" 2>/dev/null)
      uds_log "Container exit code: $exit_code" "info"
    fi
  fi
  
  return 1
}

# Enhanced health check with standardized retry logic
uds_health_check_with_retry() {
  local app_name="$1"
  local port="$2"
  local health_endpoint="${3:-/health}"
  local max_attempts="${4:-5}"
  local timeout="${5:-60}"
  local health_type="${6:-auto}"
  local container_name="${7:-${app_name}-app}"
  local health_command="${8:-}"
  
  # Auto-detect health check type if needed
  if [ "$health_type" = "auto" ]; then
    health_type=$(uds_detect_health_check_type "$app_name" "$IMAGE" "$health_endpoint")
  fi
  
  # Implement exponential backoff
  local attempt=1
  local wait_time=$((timeout / max_attempts))
  
  while [ $attempt -le $max_attempts ]; do
    uds_log "Health check attempt $attempt of $max_attempts (type: $health_type)" "info"
    
    if uds_check_health "$app_name" "$port" "$health_endpoint" "$wait_time" "$health_type" "$container_name" "$health_command"; then
      uds_log "Health check passed on attempt $attempt" "success"
      return 0
    fi
    
    attempt=$((attempt + 1))
    wait_time=$((wait_time * 2)) # Exponential backoff
    
    if [ $attempt -le $max_attempts ]; then
      uds_log "Health check failed, waiting ${wait_time}s before retry" "warning"
      sleep $wait_time
    fi
  done
  
  uds_log "Health check failed after $max_attempts attempts" "error"
  return 1
}

# Export all health check functions
export -f uds_detect_health_check_type uds_check_health uds_health_check_with_retry