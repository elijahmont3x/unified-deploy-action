#!/bin/bash
#
# uds-service.sh - Service registry for Unified Deployment System
#
# This module provides functions for managing the service registry

# Avoid loading multiple times
if [ -n "$UDS_SERVICE_LOADED" ]; then
  return 0
fi
UDS_SERVICE_LOADED=1

# Enhanced service registry operations with better locking and error recovery

# Acquire a lock on the registry file with improved timeout and recovery
uds_registry_acquire_lock() {
  local lock_type="$1"  # "read" or "write"
  local timeout="${2:-30}"
  local lock_file=""
  
  if [ "$lock_type" = "read" ]; then
    lock_file="${UDS_REGISTRY_FILE}.read.lock"
  elif [ "$lock_type" = "write" ]; then
    lock_file="${UDS_REGISTRY_FILE}.lock"
  else
    uds_log "Invalid lock type: $lock_type, must be 'read' or 'write'" "error" 
    return 1
  fi
  
  # Create lock directory if it doesn't exist
  local lock_dir=$(dirname "$lock_file")
  if [ ! -d "$lock_dir" ]; then
    mkdir -p "$lock_dir" 2>/dev/null || {
      uds_log "Failed to create lock directory: $lock_dir" "error"
      return 1
    }
  fi
  
  # Try to acquire the lock with timeout
  local start_time=$(date +%s)
  local end_time=$((start_time + timeout))
  local retry_count=0
  local max_retries=10
  local wait_time=1
  
  while [ "$(date +%s)" -lt "$end_time" ]; do
    # For read locks, check if write lock exists (write operations have priority)
    if [ "$lock_type" = "read" ] && [ -d "${UDS_REGISTRY_FILE}.lock" ]; then
      sleep 0.5
      continue
    fi
    
    # Try to create lock directory
    if mkdir "$lock_file" 2>/dev/null; then
      # Record PID, hostname, and timestamp in the lock for diagnostics
      echo "$$:$(hostname):$(date +%s)" > "${lock_file}/info"
      
      # Export the acquired lock type and file for cleanup trap
      export UDS_CURRENT_LOCK_TYPE="$lock_type"
      export UDS_CURRENT_LOCK_FILE="$lock_file"
      
      # Set trap for automatic lock cleanup on script exit, if not already set
      # Only set trap if UDS_LOCK_TRAP_SET is not already defined
      if [ -z "${UDS_LOCK_TRAP_SET:-}" ]; then
        trap 'uds_registry_release_lock "$UDS_CURRENT_LOCK_TYPE" "$UDS_CURRENT_LOCK_FILE" || true' EXIT
        export UDS_LOCK_TRAP_SET=1
      fi
      
      return 0
    fi
    
    # Check if lock is stale (older than 5 minutes or from a non-existent process)
    if [ -d "$lock_file" ]; then
      local is_stale=false
      
      # First check: Lock info file exists and has timestamp
      if [ -f "${lock_file}/info" ]; then
        local lock_info=$(cat "${lock_file}/info" 2>/dev/null || echo "unknown")
        local lock_pid=$(echo "$lock_info" | cut -d':' -f1)
        local lock_time=$(echo "$lock_info" | cut -d':' -f3)
        local current_time=$(date +%s)
        
        # Check if process exists
        if [ -n "$lock_pid" ] && [ "$lock_pid" -gt 0 ] && ! ps -p "$lock_pid" &>/dev/null; then
          uds_log "Removing stale lock from non-existent process $lock_pid" "warning"
          is_stale=true
        # Check if lock is too old (5 minutes)
        elif [ -n "$lock_time" ] && [ $((current_time - lock_time)) -gt 300 ]; then
          uds_log "Removing stale lock created at $(date -d @"$lock_time" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -r "$lock_time" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "unknown time")" "warning"
          is_stale=true
        fi
      else
        # Second check: Lock directory exists but no info file
        local lock_ctime=$(stat -c %Y "$lock_file" 2>/dev/null || stat -f %c "$lock_file" 2>/dev/null)
        local current_time=$(date +%s)
        
        if [ -n "$lock_ctime" ] && [ $((current_time - lock_ctime)) -gt 300 ]; then
          uds_log "Removing stale lock without info file" "warning"
          is_stale=true
        fi
      fi
      
      # Remove stale lock if detected
      if [ "$is_stale" = "true" ]; then
        rm -rf "$lock_file" 2>/dev/null || {
          uds_log "Failed to remove stale lock: $lock_file" "warning"
          # Continue anyway, we'll try again
        }
        continue
      fi
    fi
    
    # Exponential backoff with jitter
    retry_count=$((retry_count + 1))
    if [ $retry_count -gt $max_retries ]; then
      break
    fi
    
    # Calculate backoff with some randomness to prevent lock convoy
    wait_time=$(( wait_time * 2 ))
    # Cap at 10 seconds
    [ $wait_time -gt 10 ] && wait_time=10
    # Add jitter (±30% of wait time)
    local jitter=$(( RANDOM % (wait_time * 6 / 10) - (wait_time * 3 / 10) ))
    [ $jitter -lt 0 ] && [ $((-jitter)) -gt $wait_time ] && jitter=$((-wait_time + 1))
    local actual_wait_time=$(( wait_time + jitter ))
    [ $actual_wait_time -lt 1 ] && actual_wait_time=1
    
    sleep $actual_wait_time
  done
  
  # If we get here, we failed to acquire the lock
  uds_log "Failed to acquire $lock_type lock after ${timeout}s" "error"
  return 1
}

# Release a lock on the registry file
uds_registry_release_lock() {
  local lock_type="$1"  # "read" or "write"
  local specified_lock_file="$2"  # Optional: directly specified lock file
  local force="${3:-false}"  # Force removal even if we don't own the lock
  local lock_file=""
  
  # Use specified lock file if provided, otherwise determine from lock type
  if [ -n "$specified_lock_file" ]; then
    lock_file="$specified_lock_file"
  elif [ "$lock_type" = "read" ]; then
    lock_file="${UDS_REGISTRY_FILE}.read.lock"
  elif [ "$lock_type" = "write" ]; then
    lock_file="${UDS_REGISTRY_FILE}.lock"
  else
    uds_log "Invalid lock type: $lock_type" "warning"
    return 1
  fi
  
  # Remove the lock directory if it exists and we have the right to do so
  if [ -d "$lock_file" ]; then
    # Check if we own the lock (based on PID) or if force is true
    local should_remove=false
    
    if [ "$force" = "true" ]; then
      should_remove=true
    elif [ -f "${lock_file}/info" ]; then
      local lock_info=$(cat "${lock_file}/info" 2>/dev/null || echo "unknown")
      local lock_pid=$(echo "$lock_info" | cut -d':' -f1)
      
      # Only remove if we own the lock
      if [ "$lock_pid" = "$$" ]; then
        should_remove=true
      else
        uds_log "Attempted to release lock owned by PID $lock_pid (we are $$)" "warning"
        return 1
      fi
    else
      # No info file, consider it orphaned and remove it
      should_remove=true
    fi
    
    if [ "$should_remove" = "true" ]; then
      rm -rf "$lock_file" 2>/dev/null || {
        uds_log "Failed to remove lock: $lock_file" "warning"
        return 1
      }
    fi
    
    # Reset trap and environment variables if we're releasing our own lock
    if [ "$lock_file" = "${UDS_CURRENT_LOCK_FILE:-}" ]; then
      # Unset variables to prevent stale references
      unset UDS_CURRENT_LOCK_TYPE
      unset UDS_CURRENT_LOCK_FILE
      
      # Only reset trap if we're sure no other locks are held
      if [ -z "${UDS_REGISTRY_LOCKS_HELD:-}" ]; then
        # Remove trap only if we're not in a subshell (which would inherit traps)
        # Since trap removal is tricky and can have side effects, we'll just leave it
        # but make it harmless by unsetting the variables it references
        export UDS_LOCK_TRAP_SET=
      fi
    fi
    
    return 0
  fi
  
  # Lock didn't exist, not an error
  uds_log "Lock not found: $lock_file" "debug"
  return 0
}

# Register a service in the registry with better error handling and locking
uds_register_service() {
  local app_name="$1"
  local domain="$2"
  local route_type="$3"
  local route="$4"
  local port="$5"
  local image="$6"
  local tag="$7"
  local is_persistent="${8:-false}"
  
  uds_log "Registering service: $app_name" "info"
  
  # Validate required parameters
  if [ -z "$app_name" ]; then
    uds_log "Missing required parameter: app_name" "error"
    return 1
  fi
  
  # Ensure registry directory exists
  local registry_dir=$(dirname "$UDS_REGISTRY_FILE")
  mkdir -p "$registry_dir" 2>/dev/null || {
    uds_log "Failed to create registry directory: $registry_dir" "error"
    return 1
  }
  
  # Acquire lock with a specific timeout (30 seconds should be enough for most operations)
  uds_registry_acquire_lock "write" 30 || {
    uds_log "Failed to acquire lock for registry operation" "error"
    return 1
  }
  
  # Ensure registry file exists and is valid
  local init_registry=false
  if [ ! -f "$UDS_REGISTRY_FILE" ]; then
    echo '{"services":{}}' > "$UDS_REGISTRY_FILE"
    chmod 600 "$UDS_REGISTRY_FILE"
    init_registry=true
  fi
  
  # Read the registry file with error handling
  local registry_data=""
  if [ "$init_registry" = "true" ]; then
    registry_data='{"services":{}}'
  else
    if ! registry_data=$(cat "$UDS_REGISTRY_FILE" 2>/dev/null); then
      uds_log "Failed to read registry file: $UDS_REGISTRY_FILE" "error"
      uds_registry_release_lock "write"
      return 1
    fi
  fi
  
  # Validate registry file content
  if ! echo "$registry_data" | jq empty 2>/dev/null; then
    uds_log "Invalid JSON in registry file, attempting to repair" "warning"
    
    # Try to repair if it looks like a JSON object
    if [[ "$registry_data" == \{*\} ]]; then
      registry_data='{"services":{}}'
    else
      uds_log "Cannot repair registry file, resetting to empty registry" "error"
      registry_data='{"services":{}}'
    fi
    
    # Save repaired registry
    echo "$registry_data" > "$UDS_REGISTRY_FILE"
    chmod 600 "$UDS_REGISTRY_FILE"
  fi
  
  # Build the service entry with date in ISO format
  local registration_time=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  local service_entry=$(cat << EOF
{
  "name": "${app_name}",
  "domain": "${domain}",
  "route_type": "${route_type}",
  "route": "${route}",
  "port": "${port}",
  "image": "${image}",
  "tag": "${tag}",
  "is_persistent": ${is_persistent},
  "registered_at": "${registration_time}"
}
EOF
)

  # Get existing service data if available
  local existing_service=""
  local version_history="[]"
  
  if echo "$registry_data" | jq -e --arg name "$app_name" '.services[$name]' > /dev/null 2>&1; then
    existing_service=$(echo "$registry_data" | jq --arg name "$app_name" '.services[$name]')
    version_history=$(echo "$existing_service" | jq -r '.version_history // []')
    
    # Add current version to history if different
    local current_version=$(echo "$existing_service" | jq -r '.tag // "unknown"')
    local current_image=$(echo "$existing_service" | jq -r '.image // "unknown"')
    
    if [ "$current_version" != "$tag" ] || [ "$current_image" != "$image" ]; then
      # Create history entry
      local history_entry=$(cat << EOF
{
  "tag": "${current_version}",
  "image": "${current_image}",
  "deployed_at": $(echo "$existing_service" | jq '.registered_at // "unknown"')
}
EOF
)
      
      # Add to version history
      if [ "$version_history" = "[]" ]; then
        version_history="[$history_entry]"
      else
        version_history=$(echo "$version_history" | jq --argjson entry "$history_entry" '. + [$entry]')
      fi
    fi
  fi
  
  # Update service entry with version history
  service_entry=$(echo "$service_entry" | jq --argjson history "$version_history" '. + {"version_history": $history, "deployed_at": "'"$registration_time"'"}')
  
  # Create a temporary file for atomic update
  local temp_registry=""
  temp_registry=$(mktemp) || {
    uds_log "Failed to create temporary file for registry update" "error"
    uds_registry_release_lock "write"
    return 1
  }
  
  # Set secure permissions on temp file
  chmod 600 "$temp_registry" || {
    uds_log "Failed to set permissions on temporary registry file" "warning"
  }
  
  # Update the registry data
  local updated_registry=""
  updated_registry=$(echo "$registry_data" | jq --arg name "$app_name" --argjson service "$service_entry" '.services[$name] = $service') || {
    uds_log "Failed to update registry data" "error"
    rm -f "$temp_registry"
    uds_registry_release_lock "write"
    return 1
  }
  
  # Write the updated registry to the temporary file
  echo "$updated_registry" > "$temp_registry" || {
    uds_log "Failed to write to temporary registry file" "error"
    rm -f "$temp_registry"
    uds_registry_release_lock "write"
    return 1
  }
  
  # Use atomic move to update the registry file
  if ! mv "$temp_registry" "$UDS_REGISTRY_FILE"; then
    uds_log "Failed to update registry file" "error"
    rm -f "$temp_registry"
    uds_registry_release_lock "write"
    return 1
  fi
  
  # Update file permissions
  chmod 600 "$UDS_REGISTRY_FILE" || {
    uds_log "Failed to update registry file permissions" "warning"
  }
  
  # Release lock
  uds_registry_release_lock "write"
  
  uds_log "Service registered successfully: $app_name" "success"
  return 0
}

# Unregister a service from the registry with improved locking
uds_unregister_service() {
  local app_name="$1"
  
  uds_log "Unregistering service: $app_name" "info"
  
  # Acquire lock with a reasonable timeout
  uds_registry_acquire_lock "write" 30 || {
    uds_log "Failed to acquire lock for registry operation" "error"
    return 1
  }
  
  # Ensure registry file exists
  if [ ! -f "$UDS_REGISTRY_FILE" ]; then
    echo '{"services":{}}' > "$UDS_REGISTRY_FILE"
    chmod 600 "$UDS_REGISTRY_FILE"
    uds_registry_release_lock "write"
    uds_log "Service not found in registry: $app_name" "warning"
    return 1
  fi
  
  # Read the registry file
  local registry_data=$(cat "$UDS_REGISTRY_FILE" 2>/dev/null)
  if [ $? -ne 0 ]; then
    uds_log "Failed to read registry file: $UDS_REGISTRY_FILE" "error"
    uds_registry_release_lock "write"
    return 1
  fi
  
  # Check if the service exists
  if ! echo "$registry_data" | jq -e --arg name "$app_name" '.services[$name]' > /dev/null; then
    uds_registry_release_lock "write"
    uds_log "Service not found in registry: $app_name" "warning"
    return 1
  fi
  
  # Remove the service from the registry
  local temp_registry=$(mktemp)
  chmod 600 "$temp_registry" || {
    uds_log "Failed to set permissions on temporary registry file" "warning"
  }
  
  local updated_registry=$(echo "$registry_data" | jq --arg name "$app_name" 'del(.services[$name])')
  echo "$updated_registry" > "$temp_registry" || {
    uds_log "Failed to write to temporary registry file" "error"
    rm -f "$temp_registry"
    uds_registry_release_lock "write"
    return 1
  }
  
  # Use atomic move to prevent partial writes
  if ! mv "$temp_registry" "$UDS_REGISTRY_FILE"; then
    uds_log "Failed to update registry file" "error"
    rm -f "$temp_registry"
    uds_registry_release_lock "write"
    return 1
  fi
  
  # Update file permissions
  chmod 600 "$UDS_REGISTRY_FILE" || {
    uds_log "Failed to update registry file permissions" "warning"
  }
  
  # Release lock
  uds_registry_release_lock "write"
  
  uds_log "Service unregistered successfully: $app_name" "success"
  return 0
}

# Get service information from the registry with improved read locking
uds_get_service() {
  local app_name="$1"
  
  # Acquire read lock with shorter timeout since reads should be quick
  uds_registry_acquire_lock "read" 10 || {
    uds_log "Failed to acquire read lock for registry" "warning"
    # Continue anyway - better to return potentially stale data than none
  }
  
  # If registry file doesn't exist, return error
  if [ ! -f "$UDS_REGISTRY_FILE" ]; then
    uds_registry_release_lock "read"
    return 1
  fi
  
  # Read the registry file
  local registry_data=$(cat "$UDS_REGISTRY_FILE" 2>/dev/null)
  if [ $? -ne 0 ]; then
    uds_log "Failed to read registry file: $UDS_REGISTRY_FILE" "error"
    uds_registry_release_lock "read"
    return 1
  fi
  
  # Release lock as early as possible
  uds_registry_release_lock "read"
  
  # Get the service data
  local service_data=$(echo "$registry_data" | jq -e --arg name "$app_name" '.services[$name]' 2>/dev/null)
  
  # Check if the service exists
  if [ $? -ne 0 ]; then
    return 1
  fi
  
  echo "$service_data"
  return 0
}

# List all registered services with improved read locking
uds_list_services() {
  # Acquire read lock with shorter timeout since reads should be quick
  uds_registry_acquire_lock "read" 10 || {
    uds_log "Failed to acquire read lock for registry" "warning"
    # Continue anyway - better to return potentially stale data than none
  }
  
  # If registry file doesn't exist, create it
  if [ ! -f "$UDS_REGISTRY_FILE" ]; then
    if [ -w "$(dirname "$UDS_REGISTRY_FILE")" ]; then
      echo '{"services":{}}' > "$UDS_REGISTRY_FILE"
      chmod 600 "$UDS_REGISTRY_FILE"
    fi
    uds_registry_release_lock "read"
    return 0
  fi
  
  # Read the registry file
  local registry_data=$(cat "$UDS_REGISTRY_FILE" 2>/dev/null)
  if [ $? -ne 0 ]; then
    uds_log "Failed to read registry file: $UDS_REGISTRY_FILE" "error"
    uds_registry_release_lock "read"
    return 1
  fi
  
  # Release lock as early as possible
  uds_registry_release_lock "read"
  
  # Get all service names
  local services=$(echo "$registry_data" | jq -r '.services | keys[]' 2>/dev/null)
  
  echo "$services"
  return 0
}

# Get service deployment history
uds_get_service_history() {
  local app_name="$1"
  local max_entries="${2:-10}"
  
  # Get service data with error handling
  local service_data=$(uds_get_service "$app_name")
  if [ $? -ne 0 ] || [ -z "$service_data" ]; then
    uds_log "Service not found: $app_name" "error"
    return 1
  fi
  
  # Extract version history
  local version_history=$(echo "$service_data" | jq -r '.version_history // []')
  
  # Limit to maximum entries if specified
  if [ "$max_entries" -gt 0 ]; then
    version_history=$(echo "$version_history" | jq -r "| .[-$max_entries:]")
  fi
  
  echo "$version_history"
  return 0
}

# Get service URL
uds_get_service_url() {
  local app_name="$1"
  local use_ssl="${2:-true}"
  
  # Get service data with error handling
  local service_data=$(uds_get_service "$app_name")
  if [ $? -ne 0 ] || [ -z "$service_data" ]; then
    uds_log "Service not found: $app_name" "error"
    return 1
  fi
  
  # Extract domain, route type, and route
  local domain=$(echo "$service_data" | jq -r '.domain // ""')
  local route_type=$(echo "$service_data" | jq -r '.route_type // "path"')
  local route=$(echo "$service_data" | jq -r '.route // ""')
  
  if [ -z "$domain" ]; then
    uds_log "Service has no domain: $app_name" "error"
    return 1
  fi
  
  # Build URL
  local protocol="http"
  if [ "$use_ssl" = "true" ]; then
    protocol="https"
  fi
  
  local url=""
  if [ "$route_type" = "subdomain" ] && [ -n "$route" ]; then
    url="${protocol}://${route}.${domain}"
  elif [ "$route_type" = "path" ] && [ -n "$route" ]; then
    url="${protocol}://${domain}/${route}"
  else
    url="${protocol}://${domain}"
  fi
  
  echo "$url"
  return 0
}

# Check if a service exists
uds_service_exists() {
  local app_name="$1"
  
  if uds_get_service "$app_name" &>/dev/null; then
    return 0
  else
    return 1
  fi
}

# Export functions
export -f uds_registry_acquire_lock uds_registry_release_lock
export -f uds_register_service uds_unregister_service uds_get_service
export -f uds_list_services uds_get_service_history uds_get_service_url
export -f uds_service_exists