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
  
  # Check if we need to infer from container
  if [ "$health_endpoint" = "auto" ] || [ -z "$health_endpoint" ]; then
    uds_log "Automatically detecting health check type for $app_name" "debug"
    
    # Get lowercase image name for more accurate detection
    local image_lower=$(echo "$image" | tr '[:upper:]' '[:lower:]')
    
    # Get container name
    local container_name="${app_name}-app"
    
    # First try to detect from Docker labels if container exists
    if docker ps -q --filter "name=$container_name" | grep -q .; then
      # Check for health check label
      local health_label=$(docker inspect --format='{{index .Config.Labels "uds.health.type" }}' "$container_name" 2>/dev/null)
      
      if [ -n "$health_label" ]; then
        uds_log "Using health check type from container label: $health_label" "debug"
        echo "$health_label"
        return 0
      fi
      
      # Check if container has health check defined
      if docker inspect --format='{{if .Config.Healthcheck}}true{{else}}false{{end}}' "$container_name" 2>/dev/null | grep -q "true"; then
        uds_log "Container has built-in health check" "debug"
        echo "container"
        return 0
      fi
    fi
    
    # Try to detect from image name if container doesn't exist or has no health check info
    if [[ "$image_lower" == *"redis"* ]]; then
      uds_log "Detected Redis image, using TCP health check" "debug"
      echo "redis"
      return 0
    elif [[ "$image_lower" == *"postgres"* ]]; then
      uds_log "Detected PostgreSQL image, using database health check" "debug"
      echo "postgres"
      return 0
    elif [[ "$image_lower" == *"mysql"* ]] || [[ "$image_lower" == *"mariadb"* ]]; then
      uds_log "Detected MySQL/MariaDB image, using database health check" "debug"
      echo "mysql"
      return 0
    elif [[ "$image_lower" == *"mongo"* ]]; then
      uds_log "Detected MongoDB image, using database health check" "debug"
      echo "mongodb"
      return 0
    elif [[ "$image_lower" == *"rabbitmq"* ]]; then
      uds_log "Detected RabbitMQ image, using rabbitmq health check" "debug"
      echo "rabbitmq"
      return 0
    elif [[ "$image_lower" == *"kafka"* ]]; then
      uds_log "Detected Kafka image, using kafka health check" "debug"
      echo "kafka"
      return 0
    elif [[ "$image_lower" == *"elastic"* ]] || [[ "$image_lower" == *"elasticsearch"* ]]; then
      uds_log "Detected Elasticsearch image, using elasticsearch health check" "debug"
      echo "elasticsearch"
      return 0
    elif [[ "$image_lower" == *"nginx"* ]] || [[ "$image_lower" == *"httpd"* ]] || [[ "$image_lower" == *"caddy"* ]]; then
      uds_log "Detected web server image, using HTTP health check" "debug"
      echo "http"
      return 0
    fi
    
    # Default to http for most applications
    uds_log "No specific health check type detected, defaulting to HTTP" "debug"
    echo "http"
    return 0
  else
    # If health check endpoint is provided but not a special keyword, assume HTTP
    if [[ "$health_endpoint" == "/"* ]]; then
      echo "http"
    else
      # Otherwise, assume it's a specific type
      echo "$health_endpoint"
    fi
    return 0
  fi
}

# Enhanced health check function with more robust handling
uds_check_health() {
  local app_name="$1"
  local port="$2"
  local health_endpoint="${3:-/health}"
  local timeout="${4:-60}"
  local health_type="${5:-http}" # http, tcp, redis, postgres, mysql, mongodb, rabbitmq, elasticsearch, kafka, container, command
  local container_name="${6:-}"
  local health_command="${7:-}"
  
  # Skip health check if explicitly disabled
  if [ "$health_type" = "none" ] || [ "$health_endpoint" = "none" ] || [ "$health_endpoint" = "disabled" ]; then
    uds_log "Health check disabled for $app_name" "info"
    return 0
  fi
  
  uds_log "Checking health of $app_name using $health_type check (timeout: ${timeout}s)" "info"
  
  # Determine container name if not provided for container checks
  if [ -z "$container_name" ]; then
    container_name="${app_name}-app"
  fi
  
  local start_time=$(date +%s)
  local end_time=$((start_time + timeout))
  local current_time=$start_time
  local check_interval=5
  local error_message=""
  
  # Disable the "command not found" errors during health checks
  set +e
  
  while [ $current_time -lt $end_time ]; do
    # Attempt health check based on type
    case "$health_type" in
      http)
        # HTTP-based health check
        local http_url="http://localhost:${port}${health_endpoint}"
        uds_log "HTTP health check: $http_url" "debug"
        
        local http_result=$(curl -s -o /dev/null -w "%{http_code}" -m 5 "$http_url" 2>/dev/null)
        
        if [ "$http_result" -ge 200 ] && [ "$http_result" -lt 300 ]; then
          uds_log "HTTP health check passed with status $http_result for $app_name" "success"
          set -e
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
        
        # Use netcat if available, otherwise try /dev/tcp
        if command -v nc &>/dev/null; then
          if nc -z localhost "$port" 2>/dev/null; then
            uds_log "TCP health check passed for $app_name (port $port is open)" "success"
            set -e
            return 0
          else
            error_message="TCP port $port is not open"
          fi
        else
          # Fallback to bash built-in /dev/tcp
          if timeout 2 bash -c "< /dev/tcp/localhost/$port" 2>/dev/null; then
            uds_log "TCP health check passed for $app_name (port $port is open)" "success"
            set -e
            return 0
          else
            error_message="TCP port $port is not open"
          fi
        fi
        ;;
      
      redis)
        # Redis-specific health check
        uds_log "Redis health check: $container_name" "debug"
        
        if ! docker ps -q --filter "name=$container_name" | grep -q .; then
          error_message="Redis container $container_name is not running"
        else
          # Try redis-cli ping
          if docker exec "$container_name" redis-cli ping 2>/dev/null | grep -q "PONG"; then
            uds_log "Redis health check passed for $app_name" "success"
            set -e
            return 0
          else
            error_message="Redis is not responding to ping"
          fi
        fi
        ;;
      
      postgres)
        # PostgreSQL-specific health check
        uds_log "PostgreSQL health check: $container_name" "debug"
        
        if ! docker ps -q --filter "name=$container_name" | grep -q .; then
          error_message="PostgreSQL container $container_name is not running"
        else
          # Try pg_isready
          if docker exec "$container_name" pg_isready 2>/dev/null; then
            uds_log "PostgreSQL health check passed for $app_name" "success"
            set -e
            return 0
          else
            error_message="PostgreSQL is not ready"
          fi
        fi
        ;;
      
      mysql|mariadb)
        # MySQL/MariaDB-specific health check
        uds_log "MySQL health check: $container_name" "debug"
        
        if ! docker ps -q --filter "name=$container_name" | grep -q .; then
          error_message="MySQL container $container_name is not running"
        else
          # Try mysqladmin ping
          if docker exec "$container_name" mysqladmin ping --silent 2>/dev/null; then
            uds_log "MySQL health check passed for $app_name" "success"
            set -e
            return 0
          else
            error_message="MySQL is not responding to ping"
          fi
        fi
        ;;
      
      mongodb)
        # MongoDB-specific health check
        uds_log "MongoDB health check: $container_name" "debug"
        
        if ! docker ps -q --filter "name=$container_name" | grep -q .; then
          error_message="MongoDB container $container_name is not running"
        else
          # Try mongo ping
          if docker exec "$container_name" mongo --eval "db.adminCommand('ping')" 2>/dev/null | grep -q "ok.*1"; then
            uds_log "MongoDB health check passed for $app_name" "success"
            set -e
            return 0
          else
            error_message="MongoDB is not responding to ping"
          fi
        fi
        ;;
      
      rabbitmq)
        # RabbitMQ specific health check
        uds_log "RabbitMQ health check: $container_name" "debug"
        
        if ! docker ps -q --filter "name=$container_name" | grep -q .; then
          error_message="RabbitMQ container $container_name is not running"
        else
          # Check RabbitMQ status
          if docker exec "$container_name" rabbitmqctl status 2>/dev/null | grep -q "RabbitMQ"; then
            uds_log "RabbitMQ health check passed for $app_name" "success"
            set -e
            return 0
          else
            error_message="RabbitMQ is not ready"
          fi
        fi
        ;;
        
      elasticsearch)
        # Elasticsearch specific health check
        uds_log "Elasticsearch health check: port ${port}" "debug"
        
        # Try both localhost and container
        if curl -s "http://localhost:${port}/_cluster/health" 2>/dev/null | grep -q "status"; then
          uds_log "Elasticsearch health check passed for $app_name" "success"
          set -e
          return 0
        elif docker ps -q --filter "name=$container_name" | grep -q . && \
             docker exec "$container_name" curl -s "http://localhost:9200/_cluster/health" 2>/dev/null | grep -q "status"; then
          uds_log "Elasticsearch health check passed for $app_name" "success"
          set -e
          return 0
        else
          error_message="Elasticsearch is not ready"
        fi
        ;;
        
      kafka)
        # Kafka specific health check
        uds_log "Kafka health check: $container_name" "debug"
        
        if ! docker ps -q --filter "name=$container_name" | grep -q .; then
          error_message="Kafka container $container_name is not running"
        else
          # Try to list topics
          if docker exec "$container_name" kafka-topics.sh --bootstrap-server localhost:9092 --list 2>/dev/null; then
            uds_log "Kafka health check passed for $app_name" "success"
            set -e
            return 0
          else
            error_message="Kafka is not ready"
          fi
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
            set -e
            return 0
          elif [ "$health_status" = "none" ] || [ -z "$health_status" ]; then
            # No health check, check if running is enough
            if docker inspect --format='{{.State.Running}}' "$container_name" 2>/dev/null | grep -q "true"; then
              uds_log "Container health check passed for $app_name (container is running)" "success"
              set -e
              return 0
            else
              error_message="Container is not running"
            fi
          else
            error_message="Container health check status: $health_status"
            
            # Get the last health check log for better diagnostics
            local health_log=""
            health_log=$(docker inspect --format='{{if .State.Health}}{{range $i, $h := .State.Health.Log}}{{if eq $i 0}}{{$h.Output}}{{end}}{{end}}{{end}}' "$container_name" 2>/dev/null)
            
            if [ -n "$health_log" ]; then
              error_message="$error_message - Last health check: ${health_log:0:100}..."
            fi
          fi
        fi
        ;;
      
      command)
        # Command-based health check
        if [ -z "$health_command" ]; then
          uds_log "No health command specified" "error"
          set -e
          return 1
        fi
        
        uds_log "Command health check: $health_command" "debug"
        
        if eval "$health_command"; then
          uds_log "Command health check passed for $app_name" "success"
          set -e
          return 0
        else
          error_message="Custom health check command failed with exit code $?"
        fi
        ;;
      
      *)
        # Fallback to HTTP health check
        uds_log "Unknown health check type: $health_type, falling back to HTTP" "warning"
        local http_url="http://localhost:${port}${health_endpoint}"
        
        if curl -s -f -m 5 "$http_url" &> /dev/null; then
          uds_log "Fallback HTTP health check passed for $app_name" "success"
          set -e
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
  
  # Re-enable error checking
  set -e
  
  # Collect diagnostics on failure
  uds_log "Health check failed for $app_name after ${timeout}s: $error_message" "error"
  
  # Check if container exists and collect logs
  if docker ps -a -q --filter "name=$container_name" | grep -q .; then
    uds_log "Container logs for $container_name (last ${MAX_LOG_LINES:-20} lines):" "info"
    docker logs --tail="${MAX_LOG_LINES:-20}" "$container_name" 2>&1 || true
    
    # Check container status
    local container_status=$(docker inspect --format='{{.State.Status}}' "$container_name" 2>/dev/null)
    uds_log "Container status: $container_status" "info"
    
    # If container exited, get exit code and capture more extensive logs
    if [ "$container_status" = "exited" ]; then
      local exit_code=$(docker inspect --format='{{.State.ExitCode}}' "$container_name" 2>/dev/null)
      uds_log "Container exit code: $exit_code" "info"
      
      # For non-zero exit codes, capture more logs for better diagnostics
      if [ "$exit_code" != "0" ]; then
        uds_log "Container log context (last 50 lines):" "info"
        docker logs --tail=50 "$container_name" 2>&1 || true
      fi
    fi
  fi
  
  return 1
}

# Enhanced health check with standardized retry logic and progressive backoff
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
    uds_log "Auto-detected health check type: $health_type" "debug"
  fi
  
  # Skip if health check is explicitly disabled
  if [ "$health_type" = "none" ] || [ "$health_endpoint" = "none" ] || [ "$health_endpoint" = "disabled" ]; then
    uds_log "Health check disabled for $app_name" "info"
    return 0
  fi
  
  # Implement exponential backoff with jitter for more reliable health checking
  local attempt=1
  local base_wait=3
  local wait_time=$base_wait
  local max_wait=30  # Maximum wait time in seconds
  local total_time=0
  
  while [ $attempt -le $max_attempts ]; do
    uds_log "Health check attempt $attempt of $max_attempts (type: $health_type)" "info"
    
    # Main health check call
    if uds_check_health "$app_name" "$port" "$health_endpoint" "$timeout" "$health_type" "$container_name" "$health_command"; then
      return 0
    fi
    
    # Update attempt counter and wait time for next attempt using exponential backoff
    attempt=$((attempt + 1))
    total_time=$((total_time + wait_time))
    
    # Check if we've exceeded total timeout
    if [ $total_time -ge $timeout ]; then
      uds_log "Health check attempts exceeded total timeout of ${timeout}s" "error"
      break
    fi
    
    # Only wait and retry if we have attempts left
    if [ $attempt -le $max_attempts ]; then
      # Exponential backoff with jitter for retry
      wait_time=$(( (base_wait * 2**(attempt-1)) + (RANDOM % 5) ))
      
      # Cap at maximum wait time
      if [ $wait_time -gt $max_wait ]; then
        wait_time=$max_wait
      fi
      
      uds_log "Health check failed, waiting ${wait_time}s before retry (attempt $attempt of $max_attempts)" "warning"
      sleep $wait_time
    fi
  done
  
  # Execute health-check-failed hooks
  uds_execute_hook "health_check_failed" "$app_name" "$APP_DIR"
  
  return 1
}

# Export all health check functions
export -f uds_detect_health_check_type uds_check_health uds_health_check_with_retry