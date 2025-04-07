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

# Default dependency map with better structure
declare -A UDS_SERVICE_DEPENDENCIES=()
declare -A UDS_SERVICE_REQUIRED_BY=()
declare -A UDS_DEPENDENCY_HEALTH_CACHE=()

# Register a service dependency with validation
uds_register_dependency() {
  local service="$1"
  local depends_on="$2"
  local optional="${3:-false}"
  
  # Validate inputs
  if [ -z "$service" ] || [ -z "$depends_on" ]; then
    uds_log "Invalid dependency registration: service and dependency must be provided" "error"
    return 1
  fi
  
  # Prevent self-dependencies
  if [ "$service" = "$depends_on" ]; then
    uds_log "Invalid dependency: service cannot depend on itself" "error"
    return 1
  fi
  
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
    # Store dependency with optional flag
    local dep_info="${depends_on}"
    if [ "$optional" = "true" ]; then
      dep_info="${dep_info}:optional"
    fi
    
    if [ -n "${UDS_SERVICE_DEPENDENCIES[$service]}" ]; then
      UDS_SERVICE_DEPENDENCIES["$service"]="${UDS_SERVICE_DEPENDENCIES[$service]},${dep_info}"
    else
      UDS_SERVICE_DEPENDENCIES["$service"]="$dep_info"
    fi
    
    # Add reverse dependency
    if [ -n "${UDS_SERVICE_REQUIRED_BY[$depends_on]}" ]; then
      UDS_SERVICE_REQUIRED_BY["$depends_on"]="${UDS_SERVICE_REQUIRED_BY[$depends_on]},$service"
    else
      UDS_SERVICE_REQUIRED_BY["$depends_on"]="$service"
    fi
    
    uds_log "Registered dependency: $service depends on $depends_on (optional: $optional)" "debug"
    
    # Check for circular dependencies
    if uds_has_dependency "$depends_on" "$service"; then
      uds_log "Warning: Circular dependency detected between $service and $depends_on" "warning"
    fi
  fi
  
  return 0
}

# Get dependencies for a service
uds_get_dependencies() {
  local service="$1"
  local include_optional="${2:-true}"
  
  # Return raw dependencies if including optional
  if [ "$include_optional" = "true" ]; then
    echo "${UDS_SERVICE_DEPENDENCIES[$service]:-}"
    return 0
  fi
  
  # Filter out optional dependencies
  local deps="${UDS_SERVICE_DEPENDENCIES[$service]:-}"
  if [ -n "$deps" ]; then
    local filtered_deps=""
    IFS=',' read -ra DEPS_ARRAY <<< "$deps"
    
    for dep in "${DEPS_ARRAY[@]}"; do
      if [[ ! "$dep" =~ :optional$ ]]; then
        if [ -n "$filtered_deps" ]; then
          filtered_deps="${filtered_deps},${dep%%:*}"
        else
          filtered_deps="${dep%%:*}"
        fi
      fi
    done
    
    echo "$filtered_deps"
  fi
  
  return 0
}

# Check if a dependency is optional
uds_is_dependency_optional() {
  local service="$1"
  local dependency="$2"
  
  local deps="${UDS_SERVICE_DEPENDENCIES[$service]:-}"
  if [ -n "$deps" ]; then
    IFS=',' read -ra DEPS_ARRAY <<< "$deps"
    
    for dep in "${DEPS_ARRAY[@]}"; do
      # Extract dependency name and check if it matches
      local dep_name="${dep%%:*}"
      
      if [ "$dep_name" = "$dependency" ] && [[ "$dep" =~ :optional$ ]]; then
        return 0  # Is optional
      fi
    done
  fi
  
  return 1  # Not optional
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
  local -n _visited=$3
  
  # Check if already visited to avoid cycles
  for v in "${_visited[@]}"; do
    if [ "$v" = "$service" ]; then
      return 1
    fi
  done
  
  # Add to visited
  _visited+=("$service")
  
  # Extract dependencies from the service
  local deps="${UDS_SERVICE_DEPENDENCIES[$service]:-}"
  if [ -n "$deps" ]; then
    IFS=',' read -ra DEPS_ARRAY <<< "$deps"
    
    for dep in "${DEPS_ARRAY[@]}"; do
      # Extract dependency name
      local dep_name="${dep%%:*}"
      
      # Check direct dependency
      if [ "$dep_name" = "$dependency" ]; then
        return 0
      fi
      
      # Check indirect dependencies
      if _uds_check_dependency "$dep_name" "$dependency" _visited; then
        return 0
      fi
    done
  fi
  
  return 1
}

# Sort services in dependency order with enhanced cycle detection
uds_sort_services() {
  local services_list="$1"
  local IFS=','
  local sorted_services=()
  local visited=()
  # Temporary marking array for cycle detection in topological sort
  # Used via nameref in _uds_topo_sort
  # shellcheck disable=SC2034
  local temp_mark=()
  
  # Convert comma-separated list to array
  local services_array=()
  for service in $services_list; do
    services_array+=("$service")
    # Initialize markers
    visited["$service"]=0
    temp_mark["$service"]=0
  done
  
  # Topological sort
  for service in "${services_array[@]}"; do
    if [ "${visited[$service]:-0}" -eq 0 ]; then
      if ! _uds_topo_sort "$service" sorted_services visited temp_mark; then
        uds_log "Circular dependency detected involving $service, results may not be accurate" "warning"
      fi
    fi
  done
  
  # Return sorted services as comma-separated list
  local result=$(IFS=,; echo "${sorted_services[*]}")
  echo "$result"
}

# Helper function for topological sort
_uds_topo_sort() {
  local service="$1"
  local -n _sorted="$2"
  local -n _visited="$3"
  local -n _temp_mark="$4"
  
  # Check for cycle
  if [ "${_temp_mark[$service]:-0}" -eq 1 ]; then
    return 1
  fi
  
  # Skip if already visited
  if [ "${_visited[$service]:-0}" -eq 1 ]; then
    return 0
  fi
  
  # Mark temporarily
  _temp_mark["$service"]=1
  
  # Process dependencies
  local deps="${UDS_SERVICE_DEPENDENCIES[$service]:-}"
  if [ -n "$deps" ]; then
    IFS=',' read -ra DEPS_ARRAY <<< "$deps"
    
    for dep in "${DEPS_ARRAY[@]}"; do
      # Extract dependency name
      local dep_name="${dep%%:*}"
      
      # Visit dependency
      if ! _uds_topo_sort "$dep_name" _sorted _visited _temp_mark; then
        return 1
      fi
    done
  fi
  
  # Mark as permanently visited
  _visited["$service"]=1
  # shellcheck disable=SC2034
  _temp_mark["$service"]=0
  
  # Add to sorted list
  _sorted+=("$service")
  
  return 0
}

# Enhanced health check function for dependencies
uds_check_service_availability() {
  local service="$1"
  local timeout="${2:-60}"  # Default timeout is 60s
  local wait_between="${3:-5}"
  local use_cache="${4:-true}"
  
  # Check if result is cached and cache is enabled
  if [ "$use_cache" = "true" ] && [ -n "${UDS_DEPENDENCY_HEALTH_CACHE[$service]:-}" ]; then
    uds_log "Using cached health status for $service" "debug"
    return "${UDS_DEPENDENCY_HEALTH_CACHE[$service]}"
  fi
  
  uds_log "Checking availability of service: $service (timeout: ${timeout}s)" "info"
  
  local start_time=$(date +%s)
  local end_time=$((start_time + timeout))
  local current_time=$start_time
  
  # Get service data
  local service_data=$(uds_get_service "$service")
  if [ -z "$service_data" ]; then
    uds_log "Service $service not found in registry" "error"
    
    # Cache the negative result
    if [ "$use_cache" = "true" ]; then
      UDS_DEPENDENCY_HEALTH_CACHE["$service"]=1
    fi
    
    return 1
  fi
  
  # Extract ports and health check
  local port=$(echo "$service_data" | jq -r '.port // "3000"')
  local health_check=$(echo "$service_data" | jq -r '.health_check // "/health"')
  local health_check_type=$(echo "$service_data" | jq -r '.health_check_type // "auto"')
  
  # Check if explicit timeout was provided (if $2 is set)
  if [ -z "$2" ]; then
    # No explicit timeout provided, check for service-specific value
    local service_timeout=$(echo "$service_data" | jq -r '.health_check_timeout')
    if [ -n "$service_timeout" ] && [ "$service_timeout" != "null" ]; then
      uds_log "Using service-specific health check timeout: ${service_timeout}s" "debug"
      timeout="$service_timeout"
    fi
  fi
  
  # Recalculate end time with possibly updated timeout
  end_time=$((start_time + timeout))
  
  # Progressive backoff for health check intervals
  local check_interval=$wait_between
  local max_interval=15
  
  while [ "$current_time" -lt $end_time ]; do
    # Use the consolidated health check function if available
    if type uds_check_health &>/dev/null; then
      if uds_check_health "$service" "$port" "$health_check" "$check_interval" "$health_check_type" "${service}-app"; then
        uds_log "Service $service is available" "success"
        
        # Cache the positive result
        if [ "$use_cache" = "true" ]; then
          UDS_DEPENDENCY_HEALTH_CACHE["$service"]=0
        fi
        
        return 0
      fi
    else
      # Simple TCP check as fallback
      if ! uds_is_port_available "$port" "localhost"; then
        uds_log "Service $service is available (port check)" "success"
        
        # Cache the positive result
        if [ "$use_cache" = "true" ]; then
          UDS_DEPENDENCY_HEALTH_CACHE["$service"]=0
        fi
        
        return 0
      fi
    fi
    
    # Calculate remaining time and progress
    local remaining=$((end_time - current_time))
    local elapsed=$((current_time - start_time))
    local percent_complete=$((elapsed * 100 / (timeout)))
    
    # Show progress every 5 seconds to prevent log spam
    if [ $((elapsed % 5)) -eq 0 ]; then
      uds_log "Waiting for service $service... ${remaining}s remaining (${percent_complete}% elapsed)" "debug"
    fi
    
    # Progressive backoff
    if [ $elapsed -gt 30 ] && [ "$check_interval" -lt $max_interval ]; then
      check_interval=$((check_interval + 2))
      if [ $check_interval -gt $max_interval ]; then
        check_interval=$max_interval
      fi
    fi
    
    sleep "$check_interval"
    current_time=$(date +%s)
  done
  
  uds_log "Timed out waiting for service $service to become available (${timeout}s elapsed)" "error"
  
  # Cache the negative result
  if [ "$use_cache" = "true" ]; then
    UDS_DEPENDENCY_HEALTH_CACHE["$service"]=1
  fi
  
  return 1
}

# Clear health check cache
uds_clear_dependency_health_cache() {
  uds_log "Clearing dependency health check cache" "debug"
  # Clear associative array properly
  for key in "${!UDS_DEPENDENCY_HEALTH_CACHE[@]}"; do
    unset "UDS_DEPENDENCY_HEALTH_CACHE[$key]"
  done
}

# Check if all dependencies are available with parallel checking
uds_wait_for_dependencies() {
  local service="$1"
  local timeout="${2:-120}"
  local parallel="${3:-true}"
  
  # Clear health cache to ensure fresh checks
  uds_clear_dependency_health_cache
  
  # Get service dependencies
  local dependencies=$(uds_get_dependencies "$service")
  if [ -z "$dependencies" ]; then
    uds_log "Service $service has no dependencies" "debug"
    return 0
  fi
  
  uds_log "Checking dependencies for service $service" "info"
  
  # Convert to array
  local -a deps_array=()
  IFS=',' read -ra deps_array <<< "$dependencies"
  
  # Track failed dependencies
  local failed_deps=()
  local optional_failed=()
  
  if [ "$parallel" = "true" ] && [ ${#deps_array[@]} -gt 1 ]; then
    # Parallel checking for multiple dependencies
    uds_log "Checking ${#deps_array[@]} dependencies in parallel" "info"
    
    # Create temporary directory for status files
    local temp_dir=$(mktemp -d)
    
    # Launch each dependency check in background
    for dep in "${deps_array[@]}"; do
      # Extract dependency name
      local dep_name="${dep%%:*}"
      local is_optional=false
      
      # Check if dependency is optional
      if [[ "$dep" =~ :optional$ ]]; then
        is_optional=true
      fi
      
      uds_log "Launching check for dependency: $dep_name (optional: $is_optional)" "debug"
      
      # Run check in background
      (
        if uds_check_service_availability "$dep_name" "$timeout" "5" "false"; then
          echo "success" > "${temp_dir}/${dep_name}.status"
        else
          echo "failure:$is_optional" > "${temp_dir}/${dep_name}.status"
        fi
      ) &
    done
    
    # Wait for all background jobs to complete or timeout
    local wait_start=$(date +%s)
    local wait_timeout=$((timeout + 10))  # Add buffer for process startup
    
    uds_log "Waiting for dependency checks to complete..." "info"
    
    # Display periodic progress updates
    while true; do
      # Check if all files exist
      local all_complete=true
      for dep in "${deps_array[@]}"; do
        local dep_name="${dep%%:*}"
        if [ ! -f "${temp_dir}/${dep_name}.status" ]; then
          all_complete=false
          break
        fi
      done
      
      if [ "$all_complete" = "true" ]; then
        break
      fi
      
      # Check timeout
      local current_time=$(date +%s)
      if [ $((current_time - wait_start)) -gt $wait_timeout ]; then
        uds_log "Timeout waiting for dependency checks to complete" "warning"
        
        # Kill any remaining background jobs
        kill "$(jobs -p)" 2>/dev/null || true
        break
      fi
      
      # Show progress every 5 seconds
      if [ $(((current_time - wait_start) % 5)) -eq 0 ]; then
        local completed=0
        for dep in "${deps_array[@]}"; do
          local dep_name="${dep%%:*}"
          if [ -f "${temp_dir}/${dep_name}.status" ]; then
            completed=$((completed + 1))
          fi
        done
        
        local percent=$((completed * 100 / ${#deps_array[@]}))
        uds_log "Dependency check progress: $completed/${#deps_array[@]} ($percent%)" "debug"
      fi
      
      sleep 1
    done
    
    # Process results
    for dep in "${deps_array[@]}"; do
      local dep_name="${dep%%:*}"
      if [ -f "${temp_dir}/${dep_name}.status" ]; then
        local status=$(cat "${temp_dir}/${dep_name}.status")
        
        if [ "$status" = "success" ]; then
          uds_log "Dependency $dep_name is available" "success"
        else
          # Parse failure status to check if optional
          local optional=false
          if [[ "$status" =~ failure:true ]]; then
            optional=true
            optional_failed+=("$dep_name")
          else
            failed_deps+=("$dep_name")
          fi
          
          local severity="error"
          if [ "$optional" = "true" ]; then
            severity="warning"
          fi
          
          uds_log "Dependency $dep_name is not available (optional: $optional)" "$severity"
        fi
      else
        # Status file missing - assume failure
        uds_log "Dependency check for $dep_name did not complete" "error"
        
        # Check if dependency is optional
        if uds_is_dependency_optional "$service" "$dep_name"; then
          optional_failed+=("$dep_name")
        else
          failed_deps+=("$dep_name")
        fi
      fi
    done
    
    # Clean up
    rm -rf "$temp_dir"
    
  else
    # Sequential checking
    for dep in "${deps_array[@]}"; do
      # Extract dependency name
      local dep_name="${dep%%:*}"
      
      # Check if dependency is optional
      local is_optional=false
      if [[ "$dep" =~ :optional$ ]]; then
        is_optional=true
      fi
      
      uds_log "Waiting for dependency: $dep_name (optional: $is_optional)" "info"
      
      if ! uds_check_service_availability "$dep_name" "$timeout"; then
        uds_log "Dependency $dep_name is not available" "error"
        
        if [ "$is_optional" = "true" ]; then
          optional_failed+=("$dep_name")
        else
          failed_deps+=("$dep_name")
        fi
      fi
    done
  fi
  
  # Check results
  if [ ${#failed_deps[@]} -eq 0 ]; then
    if [ ${#optional_failed[@]} -eq 0 ]; then
      uds_log "All dependencies for $service are available" "success"
    else
      uds_log "All required dependencies are available, but ${#optional_failed[@]} optional dependencies failed: ${optional_failed[*]}" "warning"
    fi
    return 0
  else
    uds_log "Required dependencies not available: ${failed_deps[*]}, cannot proceed with $service" "error"
    if [ ${#optional_failed[@]} -gt 0 ]; then
      uds_log "Optional dependencies also not available: ${optional_failed[*]}" "warning"
    fi
    return 1
  fi
}

# Export functions
export -f uds_register_dependency uds_get_dependencies uds_has_dependency
export -f uds_sort_services uds_check_service_availability uds_wait_for_dependencies
export -f uds_is_dependency_optional uds_get_required_by uds_clear_dependency_health_cache