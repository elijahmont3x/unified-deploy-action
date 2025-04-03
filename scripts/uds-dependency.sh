#!/bin/bash
#
# uds-dependency.sh - Dependency management module for Unified Deployment System
#
# This script provides functions for managing service dependencies

# Avoid loading multiple times
if [ -n "$UDS_DEPENDENCY_LOADED" ]; then
  return 0
fi
UDS_DEPENDENCY_LOADED=1

# Default dependency map
declare -A UDS_SERVICE_DEPENDENCIES=()
declare -A UDS_SERVICE_REQUIRED_BY=()

# Register a service dependency
uds_register_dependency() {
  local service="$1"
  local depends_on="$2"
  
  # Initialize if not set
  if [ -z "${UDS_SERVICE_DEPENDENCIES[$service]:-}" ]; then
    UDS_SERVICE_DEPENDENCIES["$service"]=""
  fi
  
  # Initialize reverse dependency
  if [ -z "${UDS_SERVICE_REQUIRED_BY[$depends_on]:-}" ]; then
    UDS_SERVICE_REQUIRED_BY["$depends_on"]=""
  fi
  
  # Add the dependency if not already present
  if [[ ! "${UDS_SERVICE_DEPENDENCIES[$service]}" =~ (^|,)"$depends_on"(,|$) ]]; then
    if [ -n "${UDS_SERVICE_DEPENDENCIES[$service]}" ]; then
      UDS_SERVICE_DEPENDENCIES["$service"]="${UDS_SERVICE_DEPENDENCIES[$service]},$depends_on"
    else
      UDS_SERVICE_DEPENDENCIES["$service"]="$depends_on"
    fi
    
    # Add reverse dependency
    if [ -n "${UDS_SERVICE_REQUIRED_BY[$depends_on]}" ]; then
      UDS_SERVICE_REQUIRED_BY["$depends_on"]="${UDS_SERVICE_REQUIRED_BY[$depends_on]},$service"
    else
      UDS_SERVICE_REQUIRED_BY["$depends_on"]="$service"
    fi
    
    uds_log "Registered dependency: $service depends on $depends_on" "debug"
  fi
}

# Get dependencies for a service
uds_get_dependencies() {
  local service="$1"
  
  echo "${UDS_SERVICE_DEPENDENCIES[$service]:-}"
}

# Get services that depend on this service
uds_get_required_by() {
  local service="$1"
  
  echo "${UDS_SERVICE_REQUIRED_BY[$service]:-}"
}

# Check if a service depends on another service (direct or indirect)
uds_has_dependency() {
  local service="$1"
  local dependency="$2"
  local visited=()
  
  _uds_check_dependency "$service" "$dependency" visited
}

# Helper function for checking dependencies (recursive)
_uds_check_dependency() {
  local service="$1"
  local dependency="$2"
  local -n _visited="$3"
  
  # Check if already visited to avoid cycles
  for v in "${_visited[@]}"; do
    if [ "$v" = "$service" ]; then
      return 1
    fi
  done
  
  # Add to visited
  _visited+=("$service")
  
  # Check direct dependency
  if [[ "${UDS_SERVICE_DEPENDENCIES[$service]:-}" =~ (^|,)"$dependency"(,|$) ]]; then
    return 0
  fi
  
  # Check indirect dependencies
  if [ -n "${UDS_SERVICE_DEPENDENCIES[$service]:-}" ]; then
    IFS=',' read -ra DEPS <<< "${UDS_SERVICE_DEPENDENCIES[$service]}"
    for dep in "${DEPS[@]}"; do
      if _uds_check_dependency "$dep" "$dependency" _visited; then
        return 0
      fi
    done
  fi
  
  return 1
}

# Sort services in dependency order
uds_sort_services() {
  local services_list="$1"
  local IFS=','
  local sorted_services=()
  local visited=()
  
  for service in $services_list; do
    _uds_visit_service "$service" sorted_services visited
  done
  
  # Return sorted services as comma-separated list
  local result=$(IFS=,; echo "${sorted_services[*]}")
  echo "$result"
}

# Helper function for topological sort of services
_uds_visit_service() {
  local service="$1"
  local -n _sorted="$2"
  local -n _visited="$3"
  
  # Check if already visited
  for v in "${_visited[@]}"; do
    if [ "$v" = "$service" ]; then
      return 0
    fi
  done
  
  # Add to visited
  _visited+=("$service")
  
  # Visit dependencies first
  if [ -n "${UDS_SERVICE_DEPENDENCIES[$service]:-}" ]; then
    IFS=',' read -ra DEPS <<< "${UDS_SERVICE_DEPENDENCIES[$service]}"
    for dep in "${DEPS[@]}"; do
      _uds_visit_service "$dep" _sorted _visited
    done
  fi
  
  # Add to sorted list
  _sorted+=("$service")
}

# Check if a service is available
uds_check_service_availability() {
  local service="$1"
  local timeout="${2:-60}"
  local wait_between="${3:-5}"
  
  local start_time=$(date +%s)
  local end_time=$((start_time + timeout))
  local current_time=$start_time
  
  # Get service data
  local service_data=$(uds_get_service "$service")
  if [ -z "$service_data" ]; then
    uds_log "Service $service not found in registry" "error"
    return 1
  fi
  
  # Extract ports and health check
  local port=$(echo "$service_data" | jq -r '.port // "3000"')
  local health_check=$(echo "$service_data" | jq -r '.health_check // "/health"')
  local health_check_type=$(echo "$service_data" | jq -r '.health_check_type // "auto"')
  
  uds_log "Checking availability of service: $service (timeout: ${timeout}s)" "info"
  
  while [ $current_time -lt $end_time ]; do
    # Use the consolidated health check function
    if type uds_check_health &>/dev/null; then
      if uds_check_health "$service" "$port" "$health_check" "5" "$health_check_type" "${service}-app"; then
        uds_log "Service $service is available" "success"
        return 0
      fi
    else
      # Simple TCP check as fallback
      if ! uds_is_port_available "$port" "localhost"; then
        uds_log "Service $service is available (port check)" "success"
        return 0
      fi
    fi
    
    sleep $wait_between
    current_time=$(date +%s)
    
    # Calculate remaining time
    local remaining=$((end_time - current_time))
    local elapsed=$((current_time - start_time))
    local percent_complete=$((elapsed * 100 / (timeout)))
    
    # Display progress
    uds_log "Waiting for service $service... ${remaining}s remaining (${percent_complete}% elapsed)" "debug"
    
    # Increase check interval for longer timeouts to reduce log noise
    if [ $elapsed -gt 30 ] && [ $check_interval -lt 10 ]; then
      check_interval=10
    fi
  done
  
  uds_log "Timed out waiting for service $service to become available" "error"
  return 1
}

# Check if all dependencies are available
uds_wait_for_dependencies() {
  local service="$1"
  local timeout="${2:-120}"
  
  if [ -z "${UDS_SERVICE_DEPENDENCIES[$service]:-}" ]; then
    uds_log "Service $service has no dependencies" "debug"
    return 0
  fi
  
  uds_log "Checking dependencies for service $service" "info"
  
  IFS=',' read -ra DEPS <<< "${UDS_SERVICE_DEPENDENCIES[$service]}"
  for dep in "${DEPS[@]}"; do
    uds_log "Waiting for dependency: $dep" "info"
    if ! uds_check_service_availability "$dep" "$timeout"; then
      uds_log "Dependency $dep is not available, cannot proceed with $service" "error"
      return 1
    fi
  done
  
  uds_log "All dependencies for $service are available" "success"
  return 0
}

# Export functions
export -f uds_register_dependency uds_get_dependencies uds_has_dependency
export -f uds_sort_services uds_check_service_availability uds_wait_for_dependencies
