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

# Constants for health check state
readonly HEALTH_CHECK_SUCCESS=0
readonly HEALTH_CHECK_FAILURE=1
readonly HEALTH_CHECK_TIMEOUT=2
readonly HEALTH_CHECK_TEMPORARY_FAILURE=3

# Global cache for health check results
declare -A UDS_HEALTH_CHECK_CACHE=()

# Standard health check retry configuration
# These values can be overridden by environment variables
UDS_HEALTH_BASE_WAIT_TIME=${UDS_HEALTH_BASE_WAIT_TIME:-2}
UDS_HEALTH_MAX_WAIT_TIME=${UDS_HEALTH_MAX_WAIT_TIME:-30}
UDS_HEALTH_JITTER_FACTOR=${UDS_HEALTH_JITTER_FACTOR:-0.3}
UDS_HEALTH_CACHE_TTL=${UDS_HEALTH_CACHE_TTL:-30}  # Seconds

# Define service-specific check commands
declare -A SERVICE_CHECK_COMMANDS=(
  ["redis"]="redis-cli ping"
  ["postgres"]="pg_isready"
  ["mysql"]="mysqladmin ping --silent"
  ["mariadb"]="mysqladmin ping --silent"
  ["mongodb"]="mongo --eval \"db.adminCommand('ping')\" | grep -q \"ok.*1\""
  ["rabbitmq"]="rabbitmqctl status | grep -q \"RabbitMQ\""
  ["elasticsearch"]="curl -s \"http://localhost:9200/_cluster/health\" | grep -q \"status\""
  ["kafka"]="kafka-topics.sh --bootstrap-server localhost:9092 --list"
)

# Define service response patterns
declare -A SERVICE_SUCCESS_PATTERNS=(
  ["redis"]="PONG"
  ["postgres"]=""  # pg_isready returns 0 on success
  ["mysql"]=""     # mysqladmin returns 0 on success
  ["mariadb"]=""   # mysqladmin returns 0 on success
  ["mongodb"]="ok.*1"
  ["rabbitmq"]="RabbitMQ"
  ["elasticsearch"]="status"
  ["kafka"]=""     # kafka-topics.sh returns 0 on success
)

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
    
    # First check for container-defined health
    local check_type=$(uds_detect_health_check_from_container "$app_name" "$image")
    
    if [ -n "$check_type" ]; then
      return 0
    fi
    
    # Try to detect from image name if container doesn't exist or has no health check info
    check_type=$(uds_detect_health_check_from_image "$image")
    
    if [ -n "$check_type" ]; then
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

# Detect health check from container configuration
uds_detect_health_check_from_container() {
  local app_name="$1"
  local image="$2"
  
  # Get container name
  local container_name="${app_name}-app"
  
  # Check if container exists
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
  
  return 1
}

# Detect health check from image name
uds_detect_health_check_from_image() {
  local image="$1"
  
  # Get lowercase image name for more accurate detection
  local image_lower=$(echo "$image" | tr '[:upper:]' '[:lower:]')
  
  # Map common database/service images to their health check types
  local service_types=("redis" "postgres" "mysql" "mariadb" "mongo" "rabbitmq" "kafka" "elasticsearch")
  
  for service in "${service_types[@]}"; do
    if [[ "$image_lower" == *"$service"* ]]; then
      uds_log "Detected $service image, using $service health check" "debug"
      echo "$service"
      return 0
    fi
  done
  
  # Check for web server images
  if [[ "$image_lower" == *"nginx"* ]] || [[ "$image_lower" == *"httpd"* ]] || [[ "$image_lower" == *"caddy"* ]]; then
    uds_log "Detected web server image, using http health check" "debug"
    echo "http"
    return 0
  fi
  
  return 1
}

# Generate jitter for retry backoff
uds_health_generate_jitter() {
  local base_wait="$1"
  local jitter_factor="${2:-$UDS_HEALTH_JITTER_FACTOR}"
  
  # Calculate jitter amount
  local max_jitter=$(echo "$base_wait * $jitter_factor" | bc 2>/dev/null)
  if [ -z "$max_jitter" ]; then
    # Fallback if bc is not available
    max_jitter=$(( (base_wait * 3) / 10 ))
  fi
  
  # Convert to integer milliseconds for RANDOM
  local max_jitter_ms=$(printf "%.0f" "$(echo "$max_jitter * 1000" | bc 2>/dev/null || echo "$max_jitter * 1000" | awk '{print $1}')")
  
  # Generate random jitter between -max_jitter_ms and +max_jitter_ms
  local jitter=$((RANDOM % (2 * max_jitter_ms + 1) - max_jitter_ms))
  
  # Convert back to seconds with 3 decimal places
  local jitter_seconds=$(printf "%.3f" "$(echo "$jitter / 1000" | bc -l 2>/dev/null || echo "scale=3; $jitter / 1000" | bc 2>/dev/null || echo "$jitter / 1000" | awk '{printf "%.3f", $1}')")
  
  echo "$jitter_seconds"
}

# Calculate exponential backoff with jitter
uds_health_calculate_backoff() {
  local attempt="$1"
  local base_wait="${2:-$UDS_HEALTH_BASE_WAIT_TIME}"
  local max_wait="${3:-$UDS_HEALTH_MAX_WAIT_TIME}"
  
  # Calculate exponential backoff
  local exp_backoff=0
  if [ $attempt -le 1 ]; then
    exp_backoff=$base_wait
  else
    # Use bc for floating point if available
    if command -v bc &>/dev/null; then
      exp_backoff=$(echo "$base_wait * (2 ^ ($attempt - 1))" | bc)
    else
      # Fallback to bash arithmetic (less precise)
      exp_backoff=$((base_wait * (2 ** (attempt - 1))))
    fi
  fi
  
  # Cap at max wait time
  if (( $(echo "$exp_backoff > $max_wait" | bc -l 2>/dev/null || echo "$exp_backoff > $max_wait" | awk '{print ($1 > $2)}') )); then
    exp_backoff=$max_wait
  fi
  
  # Add jitter
  local jitter=$(uds_health_generate_jitter "$exp_backoff")
  
  # Calculate final wait time with jitter
  local wait_time=0
  if command -v bc &>/dev/null; then
    wait_time=$(echo "$exp_backoff + $jitter" | bc)
    
    # Ensure wait time is not negative
    if (( $(echo "$wait_time < 0.1" | bc -l) )); then
      wait_time=0.1
    fi
  else
    # Integer fallback
    wait_time=$exp_backoff
  fi
  
  echo "$wait_time"
}

# Clear health check cache
uds_health_clear_cache() {
  uds_log "Clearing health check cache" "debug"
  UDS_HEALTH_CHECK_CACHE=()
}

# Get cache key for health check
uds_health_get_cache_key() {
  local app_name="$1"
  local health_type="$2"
  
  echo "${app_name}:${health_type}"
}

# Set cache entry for health check result
uds_health_set_cache() {
  local key="$1"
  local result="$2"
  local timestamp=$(date +%s)
  
  UDS_HEALTH_CHECK_CACHE["$key"]="${result}:${timestamp}"
}

# Get cached health check result if valid
uds_health_get_cache() {
  local key="$1"
  local cache_ttl="${2:-$UDS_HEALTH_CACHE_TTL}"
  
  if [ -n "${UDS_HEALTH_CHECK_CACHE[$key]:-}" ]; then
    local cached_data="${UDS_HEALTH_CHECK_CACHE[$key]}"
    local result=${cached_data%%:*}
    local timestamp=${cached_data##*:}
    local current_time=$(date +%s)
    
    # Check if cache is still valid
    if [ $((current_time - timestamp)) -le "$cache_ttl" ]; then
      echo "$result"
      return 0
    fi
  fi
  
  return 1
}

# HTTP health check implementation
uds_http_health_check() {
  local app_name="$1"
  local port="$2"
  local health_endpoint="$3"
  local timeout="$4"
  
  local http_url="http://localhost:${port}${health_endpoint}"
  uds_log "HTTP health check: $http_url" "debug"
  
  local start_time=$(date +%s)
  local end_time=$((start_time + timeout))
  local current_time=$start_time
  
  while [ $current_time -lt $end_time ]; do
    local http_result=$(curl -s -o /dev/null -w "%{http_code}" -m 5 "$http_url" 2>/dev/null)
    
    if [ "$http_result" -ge 200 ] && [ "$http_result" -lt 300 ]; then
      uds_log "HTTP health check passed with status $http_result for $app_name" "success"
      return $HEALTH_CHECK_SUCCESS
    elif [ "$http_result" -ge 500 ] || [ "$http_result" -eq 0 ]; then
      # Server error or connection error - likely temporary
      local error_message="HTTP error $http_result returned from health check endpoint"
      uds_log "$error_message" "debug"
      sleep 2
    else
      # Client error or redirect - unlikely to resolve on retry
      local error_message="HTTP status $http_result returned from health check endpoint"
      uds_log "$error_message" "warning"
      return $HEALTH_CHECK_FAILURE
    fi
    
    current_time=$(date +%s)
  done
  
  uds_log "HTTP health check timed out for $app_name after ${timeout}s" "error"
  return $HEALTH_CHECK_TIMEOUT
}

# TCP health check implementation
uds_tcp_health_check() {
  local app_name="$1"
  local port="$2"
  local timeout="$3"
  
  uds_log "TCP health check: port ${port}" "debug"
  
  local start_time=$(date +%s)
  local end_time=$((start_time + timeout))
  local current_time=$start_time
  
  while [ $current_time -lt $end_time ]; do
    # Use netcat if available, otherwise try /dev/tcp
    if command -v nc &>/dev/null; then
      if timeout 5 nc -z localhost "$port" 2>/dev/null; then
        uds_log "TCP health check passed for $app_name (port $port is open)" "success"
        return $HEALTH_CHECK_SUCCESS
      fi
    else
      # Fallback to bash built-in /dev/tcp
      if timeout 5 bash -c "< /dev/tcp/localhost/$port" 2>/dev/null; then
        uds_log "TCP health check passed for $app_name (port $port is open)" "success"
        return $HEALTH_CHECK_SUCCESS
      fi
    fi
    
    sleep 2
    current_time=$(date +%s)
  done
  
  uds_log "TCP health check timed out for $app_name after ${timeout}s" "error"
  return $HEALTH_CHECK_TIMEOUT
}

# Container health check implementation
uds_container_health_check() {
  local app_name="$1"
  local container_name="$2"
  local timeout="$3"
  
  uds_log "Container health check: $container_name" "debug"
  
  local start_time=$(date +%s)
  local end_time=$((start_time + timeout))
  local current_time=$start_time
  
  while [ $current_time -lt $end_time ]; do
    # Check if container is running
    if ! docker ps -q --filter "name=$container_name" | grep -q .; then
      sleep 2
      current_time=$(date +%s)
      continue
    fi
    
    # Check container's health status
    local container_status=$(uds_get_container_health_status "$container_name")
    local check_result=$(uds_evaluate_container_health "$container_name" "$container_status")
    
    if [ "$check_result" -eq $HEALTH_CHECK_SUCCESS ]; then
      return $HEALTH_CHECK_SUCCESS
    elif [ "$check_result" -eq $HEALTH_CHECK_FAILURE ]; then
      return $HEALTH_CHECK_FAILURE
    fi
    
    # If still waiting, continue
    sleep 2
    current_time=$(date +%s)
  done
  
  uds_log "Container health check timed out for $app_name after ${timeout}s" "error"
  return $HEALTH_CHECK_TIMEOUT
}

# Get container health status
uds_get_container_health_status() {
  local container_name="$1"
  
  # If container has health check, verify it
  local health_status=$(docker inspect --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$container_name" 2>/dev/null)
  
  echo "$health_status"
}

# Evaluate container health status
uds_evaluate_container_health() {
  local container_name="$1"
  local health_status="$2"
  
  if [ "$health_status" = "healthy" ]; then
    uds_log "Container health check passed for container (container reports healthy)" "success"
    return $HEALTH_CHECK_SUCCESS
  elif [ "$health_status" = "starting" ]; then
    # Container is still starting - continue waiting
    return $HEALTH_CHECK_TEMPORARY_FAILURE
  elif [ "$health_status" = "none" ] || [ -z "$health_status" ]; then
    # No health check, check if running is enough
    if docker inspect --format='{{.State.Running}}' "$container_name" 2>/dev/null | grep -q "true"; then
      uds_log "Container health check passed (container is running)" "success"
      return $HEALTH_CHECK_SUCCESS
    else
      uds_log "Container is not running" "error"
      return $HEALTH_CHECK_FAILURE
    fi
  else
    # Unhealthy or unknown status
    local health_log=""
    health_log=$(docker inspect --format='{{if .State.Health}}{{range $i, $h := .State.Health.Log}}{{if eq $i 0}}{{$h.Output}}{{end}}{{end}}{{end}}' "$container_name" 2>/dev/null)
    
    if [ -n "$health_log" ]; then
      uds_log "Container health status: $health_status - ${health_log:0:100}..." "warning"
    else
      uds_log "Container health status: $health_status" "warning"
    fi
    
    # Check if container is unhealthy (unrecoverable) or just not ready yet
    if [ "$health_status" = "unhealthy" ]; then
      return $HEALTH_CHECK_FAILURE
    fi
  fi
  
  return $HEALTH_CHECK_TEMPORARY_FAILURE
}

# Command health check implementation
uds_command_health_check() {
  local app_name="$1"
  local health_command="$2"
  local timeout="$3"
  
  if [ -z "$health_command" ]; then
    uds_log "No health command specified" "error"
    return $HEALTH_CHECK_FAILURE
  fi
  
  uds_log "Command health check: $health_command" "debug"
  
  local start_time=$(date +%s)
  local end_time=$((start_time + timeout))
  local current_time=$start_time
  
  while [ $current_time -lt $end_time ]; do
    if eval "$health_command"; then
      uds_log "Command health check passed for $app_name" "success"
      return $HEALTH_CHECK_SUCCESS
    fi
    
    sleep 2
    current_time=$(date +%s)
  done
  
  uds_log "Command health check timed out for $app_name after ${timeout}s" "error"
  return $HEALTH_CHECK_TIMEOUT
}

# Unified service health check implementation
uds_service_health_check() {
  local app_name="$1"
  local service_type="$2"
  local container_name="$3"
  local port="${4:-}"
  local timeout="$5"
  
  uds_log "Service health check for $service_type: $container_name" "debug"
  
  local start_time=$(date +%s)
  local end_time=$((start_time + timeout))
  local current_time=$start_time
  
  # Get appropriate check command for this service type
  local check_command="${SERVICE_CHECK_COMMANDS["$service_type"]}"
  local success_pattern="${SERVICE_SUCCESS_PATTERNS["$service_type"]}"
  
  if [ -z "$check_command" ]; then
    uds_log "No check command defined for $service_type" "warning"
    return $HEALTH_CHECK_FAILURE
  }
  
  while [ $current_time -lt $end_time ]; do
    # Check if container is running
    if ! docker ps -q --filter "name=$container_name" | grep -q .; then
      sleep 2
      current_time=$(date +%s)
      continue
    }
    
    # Try to execute the check command
    local check_result
    
    if [ -n "$success_pattern" ]; then
      # When a success pattern is defined, check for that pattern
      if docker exec "$container_name" sh -c "$check_command" 2>/dev/null | grep -q "$success_pattern"; then
        uds_log "$service_type health check passed for $app_name" "success"
        return $HEALTH_CHECK_SUCCESS
      fi
    else
      # When no pattern is defined, rely on the command exit code
      if docker exec "$container_name" sh -c "$check_command" 2>/dev/null; then
        uds_log "$service_type health check passed for $app_name" "success"
        return $HEALTH_CHECK_SUCCESS
      fi
    fi
    
    sleep 2
    current_time=$(date +%s)
  done
  
  uds_log "$service_type health check timed out for $app_name after ${timeout}s" "error"
  return $HEALTH_CHECK_TIMEOUT
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
  local use_cache="${8:-false}"
  
  # Skip health check if explicitly disabled
  if [ "$health_type" = "none" ] || [ "$health_endpoint" = "none" ] || [ "$health_endpoint" = "disabled" ]; then
    uds_log "Health check disabled for $app_name" "info"
    return $HEALTH_CHECK_SUCCESS
  fi
  
  # Check cache if enabled
  if [ "$use_cache" = "true" ]; then
    local cache_key=$(uds_health_get_cache_key "$app_name" "$health_type")
    local cached_result=$(uds_health_get_cache "$cache_key")
    
    if [ -n "$cached_result" ]; then
      uds_log "Using cached health check result for $app_name (type: $health_type)" "debug"
      return $cached_result
    fi
  fi
  
  uds_log "Checking health of $app_name using $health_type check (timeout: ${timeout}s)" "info"
  
  # Determine container name if not provided for container checks
  if [ -z "$container_name" ]; then
    container_name="${app_name}-app"
  fi
  
  # Disable the "command not found" errors during health checks
  set +e
  
  # Standardized health check implementation
  local check_result=$HEALTH_CHECK_FAILURE
  
  case "$health_type" in
    http)
      # HTTP-based health check
      uds_http_health_check "$app_name" "$port" "$health_endpoint" "$timeout"
      check_result=$?
      ;;
    
    tcp)
      # TCP-based health check
      uds_tcp_health_check "$app_name" "$port" "$timeout"
      check_result=$?
      ;;
      
    container)
      # Container-based health check
      uds_container_health_check "$app_name" "$container_name" "$timeout"
      check_result=$?
      ;;
    
    command)
      # Command-based health check
      uds_command_health_check "$app_name" "$health_command" "$timeout"
      check_result=$?
      ;;
    
    # Use unified service check for all service-specific health checks
    redis|postgres|mysql|mariadb|mongodb|rabbitmq|elasticsearch|kafka)
      uds_service_health_check "$app_name" "$health_type" "$container_name" "$port" "$timeout"
      check_result=$?
      ;;
    
    *)
      # Fallback to HTTP health check
      uds_log "Unknown health check type: $health_type, falling back to HTTP" "warning"
      uds_http_health_check "$app_name" "$port" "$health_endpoint" "$timeout"
      check_result=$?
      ;;
  esac
  
  # Re-enable error checking
  set -e
  
  # Update cache if enabled
  if [ "$use_cache" = "true" ]; then
    local cache_key=$(uds_health_get_cache_key "$app_name" "$health_type")
    uds_health_set_cache "$cache_key" "$check_result"
  fi
  
  return $check_result
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
    uds_log "Auto-detected health check type: $health_type" "debug"
  fi
  
  # Skip if health check is explicitly disabled
  if [ "$health_type" = "none" ] || [ "$health_endpoint" = "none" ] || [ "$health_endpoint" = "disabled" ]; then
    uds_log "Health check disabled for $app_name" "info"
    return 0
  fi
  
  # Reset cache for fresh checks
  uds_health_clear_cache
  
  # Execute health check with retry
  local result=$(uds_execute_health_check_with_retry "$app_name" "$port" "$health_endpoint" "$max_attempts" "$timeout" "$health_type" "$container_name" "$health_command")
  return $result
}

# Helper function for health check execution with retry logic
uds_execute_health_check_with_retry() {
  local app_name="$1"
  local port="$2"
  local health_endpoint="$3"
  local max_attempts="$4"
  local timeout="$5"
  local health_type="$6"
  local container_name="$7"
  local health_command="$8"
  
  # Calculate timeout budget for each attempt
  local attempt_timeout=$((timeout / max_attempts))
  if [ $attempt_timeout -lt 10 ]; then
    attempt_timeout=10
  fi
  
  # Implement standardized retry logic with exponential backoff and jitter
  local attempt=1
  local total_time=0
  
  while [ $attempt -le $max_attempts ]; do
    uds_log "Health check attempt $attempt of $max_attempts (type: $health_type)" "info"
    
    # Perform health check
    local check_result=0
    uds_check_health "$app_name" "$port" "$health_endpoint" "$attempt_timeout" "$health_type" "$container_name" "$health_command" "false"
    check_result=$?
    
    # Check result and determine action
    case $check_result in
      $HEALTH_CHECK_SUCCESS)
        # Success - exit immediately
        return 0
        ;;
      
      $HEALTH_CHECK_TIMEOUT)
        # Timeout - might succeed with more time
        uds_log "Health check timed out, retrying" "warning"
        ;;
      
      $HEALTH_CHECK_TEMPORARY_FAILURE)
        # Temporary failure - retry with progressive backoff
        uds_log "Health check failed temporarily, retrying" "warning"
        ;;
      
      $HEALTH_CHECK_FAILURE)
        # Permanent failure - return immediately
        uds_log "Health check failed (unrecoverable error)" "error"
        
        # Execute health-check-failed hooks
        uds_execute_hook "health_check_failed" "$app_name" "$APP_DIR"
        
        return 1
        ;;
      
      *)
        # Unknown result - treat as temporary failure
        uds_log "Health check returned unknown status: $check_result" "warning"
        ;;
    esac
    
    # Calculate backoff time and wait
    if [ $attempt -lt $max_attempts ]; then
      if ! uds_health_backoff_and_check_timeout "$attempt" "$timeout" "$total_time"; then
        break
      fi
      
      # Update time spent
      total_time=$((total_time + attempt_timeout + wait_time))
    fi
    
    attempt=$((attempt + 1))
  done
  
  # Execute health-check-failed hooks
  uds_execute_hook "health_check_failed" "$app_name" "$APP_DIR"
  
  uds_log "Health check failed after $max_attempts attempts" "error"
  
  # Collect diagnostics on failure
  uds_health_collect_diagnostics "$app_name" "$container_name" "$health_type"
  
  return 1
}

# Helper function for backoff calculation and timeout checking
uds_health_backoff_and_check_timeout() {
  local attempt="$1"
  local timeout="$2"
  local total_time="$3"
  
  local wait_time=$(uds_health_calculate_backoff "$attempt")
  
  # Check if we've exceeded total timeout
  if [ $((total_time + wait_time)) -gt $timeout ]; then
    uds_log "Health check total timeout exceeded" "warning"
    return 1
  fi
  
  uds_log "Waiting ${wait_time}s before retry (attempt $attempt)" "info"
  sleep $wait_time
  
  return 0
}

# Collect diagnostics for failed health checks
uds_health_collect_diagnostics() {
  local app_name="$1"
  local container_name="$2"
  local health_type="$3"
  
  uds_log "Collecting diagnostics for failed health check of $app_name" "info"
  
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
    
    # Collect specific diagnostics based on service type
    case "$health_type" in
      postgres)
        docker exec "$container_name" pg_isready -v 2>/dev/null || true
        ;;
      
      mysql|mariadb)
        docker exec "$container_name" mysqladmin version 2>/dev/null || true
        ;;
      
      redis)
        docker exec "$container_name" redis-cli info 2>/dev/null || true
        ;;
      
      elasticsearch)
        docker exec "$container_name" curl -s http://localhost:9200/_cat/health 2>/dev/null || true
        ;;
        
      *)
        # No additional service-specific diagnostics
        ;;
    esac
  else
    uds_log "Container $container_name not found" "warning"
  fi
}

# Export all health check functions
export -f uds_detect_health_check_type uds_check_health uds_health_check_with_retry
export -f uds_health_clear_cache uds_health_collect_diagnostics
export -f uds_http_health_check uds_tcp_health_check uds_container_health_check 
export -f uds_service_health_check uds_command_health_check
export -f uds_detect_health_check_from_container uds_detect_health_check_from_image
export -f uds_health_generate_jitter uds_health_calculate_backoff
export -f uds_health_get_cache_key uds_health_set_cache uds_health_get_cache
export -f uds_get_container_health_status uds_evaluate_container_health
export -f uds_execute_health_check_with_retry uds_health_backoff_and_check_timeout