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

# Register a service in the registry with file locking
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
  
  # Create a lock file for safe registry operations
  local lock_file="${UDS_REGISTRY_FILE}.lock"
  
  # Acquire lock (with timeout)
  local lock_timeout=30
  local lock_start_time=$(date +%s)
  local lock_end_time=$((lock_start_time + lock_timeout))
  
  while [ "$(date +%s)" -lt "$lock_end_time" ]; do
    if mkdir "$lock_file" 2>/dev/null; then
      # Lock acquired
      break
    fi
    
    # Check if lock is stale (older than 5 minutes)
    if [ -d "$lock_file" ]; then
      local lock_ctime=$(stat -c %Y "$lock_file" 2>/dev/null || stat -f %c "$lock_file" 2>/dev/null)
      local current_time=$(date +%s)
      
      if [ $((current_time - lock_ctime)) -gt 300 ]; then
        uds_log "Removing stale lock file" "warning"
        rmdir "$lock_file" 2>/dev/null || true
      fi
    fi
    
    sleep 1
  done
  
  # Check if lock was acquired
  if [ ! -d "$lock_file" ]; then
    uds_log "Failed to acquire lock for registry operation" "error"
    return 1
  fi
  
  # Ensure registry file exists
  if [ ! -f "$UDS_REGISTRY_FILE" ]; then
    echo '{"services":{}}' > "$UDS_REGISTRY_FILE"
    chmod 600 "$UDS_REGISTRY_FILE"
  fi
  
  # Read the registry file
  local registry_data=$(cat "$UDS_REGISTRY_FILE")
  
  # Build the service entry
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
  "registered_at": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
}
EOF
)

  # Get the current date and time for version tracking
  local deployment_time=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  
  # Check if service already exists to handle version history
  if echo "$registry_data" | jq -e --arg name "$app_name" '.services[$name]' > /dev/null; then
    # Get existing service data
    local existing_service=$(echo "$registry_data" | jq --arg name "$app_name" '.services[$name]')
    
    # Extract version history or create new array
    local version_history=$(echo "$existing_service" | jq -r '.version_history // []')
    
    # Add current version to history if different
    local current_version=$(echo "$existing_service" | jq -r '.tag // "unknown"')
    
    if [ "$current_version" != "$tag" ]; then
      # Create history entry
      local history_entry=$(cat << EOF
{
  "tag": "${current_version}",
  "deployed_at": $(echo "$existing_service" | jq '.registered_at // "unknown"'),
  "image": $(echo "$existing_service" | jq '.image // "unknown"')
}
EOF
)
      
      # Add to version history
      if [ "$version_history" = "[]" ]; then
        version_history="[$history_entry]"
      else
        version_history=$(echo "$version_history" | jq --argjson entry "$history_entry" '. + [$entry]')
      fi
      
      # Update service entry with version history
      service_entry=$(echo "$service_entry" | jq --argjson history "$version_history" '. + {"version_history": $history, "deployed_at": "'"$deployment_time"'"}')
    else
      # Same version, just update deployment time
      service_entry=$(echo "$service_entry" | jq --argjson history "$version_history" '. + {"version_history": $history, "deployed_at": "'"$deployment_time"'"}')
    fi
  else
    # New service, initialize version history
    service_entry=$(echo "$service_entry" | jq '. + {"version_history": [], "deployed_at": "'"$deployment_time"'"}')
  fi

  # Update the registry file with atomic write
  local temp_registry=$(mktemp)
  local updated_registry=$(echo "$registry_data" | jq --arg name "$app_name" --argjson service "$service_entry" '.services[$name] = $service')
  echo "$updated_registry" > "$temp_registry"
  
  # Use atomic move to prevent partial writes
  if ! mv "$temp_registry" "$UDS_REGISTRY_FILE"; then
    uds_log "Failed to update registry file" "error"
    rmdir "$lock_file"
    return 1
  fi
  
  # Update file permissions
  chmod 600 "$UDS_REGISTRY_FILE"
  
  # Release lock
  rmdir "$lock_file"
  
  uds_log "Service registered successfully: $app_name" "success"
  return 0
}

# Unregister a service from the registry with file locking
uds_unregister_service() {
  local app_name="$1"
  
  uds_log "Unregistering service: $app_name" "info"
  
  # Create a lock file for safe registry operations
  local lock_file="${UDS_REGISTRY_FILE}.lock"
  
  # Acquire lock (with timeout)
  local lock_timeout=30
  local lock_start_time=$(date +%s)
  local lock_end_time=$((lock_start_time + lock_timeout))
  
  while [ "$(date +%s)" -lt "$lock_end_time" ]; do
    if mkdir "$lock_file" 2>/dev/null; then
      # Lock acquired
      break
    fi
    
    # Check if lock is stale (older than 5 minutes)
    if [ -d "$lock_file" ]; then
      local lock_ctime=$(stat -c %Y "$lock_file" 2>/dev/null || stat -f %c "$lock_file" 2>/dev/null)
      local current_time=$(date +%s)
      
      if [ $((current_time - lock_ctime)) -gt 300 ]; then
        uds_log "Removing stale lock file" "warning"
        rmdir "$lock_file" 2>/dev/null || true
      fi
    fi
    
    sleep 1
  done
  
  # Check if lock was acquired
  if [ ! -d "$lock_file" ]; then
    uds_log "Failed to acquire lock for registry operation" "error"
    return 1
  fi
  
  # Ensure registry file exists
  if [ ! -f "$UDS_REGISTRY_FILE" ]; then
    echo '{"services":{}}' > "$UDS_REGISTRY_FILE"
    chmod 600 "$UDS_REGISTRY_FILE"
    rmdir "$lock_file"
    uds_log "Service not found in registry: $app_name" "warning"
    return 1
  fi
  
  # Read the registry file
  local registry_data=$(cat "$UDS_REGISTRY_FILE")
  
  # Check if the service exists
  if ! echo "$registry_data" | jq -e --arg name "$app_name" '.services[$name]' > /dev/null; then
    rmdir "$lock_file"
    uds_log "Service not found in registry: $app_name" "warning"
    return 1
  fi
  
  # Remove the service from the registry
  local temp_registry=$(mktemp)
  local updated_registry=$(echo "$registry_data" | jq --arg name "$app_name" 'del(.services[$name])')
  echo "$updated_registry" > "$temp_registry"
  
  # Use atomic move to prevent partial writes
  if ! mv "$temp_registry" "$UDS_REGISTRY_FILE"; then
    uds_log "Failed to update registry file" "error"
    rmdir "$lock_file"
    return 1
  fi
  
  # Update file permissions
  chmod 600 "$UDS_REGISTRY_FILE"
  
  # Release lock
  rmdir "$lock_file"
  
  uds_log "Service unregistered successfully: $app_name" "success"
  return 0
}

# Get service information from the registry with read lock
uds_get_service() {
  local app_name="$1"
  
  # Create a lock file for safe registry operations
  local lock_file="${UDS_REGISTRY_FILE}.read.lock"
  
  # Acquire read lock (with shorter timeout)
  local lock_timeout=10
  local lock_start_time=$(date +%s)
  local lock_end_time=$((lock_start_time + lock_timeout))
  
  while [ "$(date +%s)" -lt "$lock_end_time" ]; do
    # Check if write lock exists (write operations have priority)
    if [ ! -d "${UDS_REGISTRY_FILE}.lock" ]; then
      if mkdir "$lock_file" 2>/dev/null; then
        # Lock acquired
        break
      fi
    fi
    
    sleep 0.5
  done
  
  # If registry file doesn't exist, return error
  if [ ! -f "$UDS_REGISTRY_FILE" ]; then
    rmdir "$lock_file" 2>/dev/null || true
    return 1
  fi
  
  # Read the registry file
  local registry_data=$(cat "$UDS_REGISTRY_FILE")
  
  # Release lock
  rmdir "$lock_file" 2>/dev/null || true
  
  # Get the service data
  local service_data=$(echo "$registry_data" | jq -e --arg name "$app_name" '.services[$name]')
  
  # Check if the service exists
  if [ $? -ne 0 ]; then
    return 1
  fi
  
  echo "$service_data"
  return 0
}

# List all registered services with read lock
uds_list_services() {
  # Create a lock file for safe registry operations
  local lock_file="${UDS_REGISTRY_FILE}.read.lock"
  
  # Acquire read lock (with shorter timeout)
  local lock_timeout=10
  local lock_start_time=$(date +%s)
  local lock_end_time=$((lock_start_time + lock_timeout))
  
  while [ "$(date +%s)" -lt "$lock_end_time" ]; do
    # Check if write lock exists (write operations have priority)
    if [ ! -d "${UDS_REGISTRY_FILE}.lock" ]; then
      if mkdir "$lock_file" 2>/dev/null; then
        # Lock acquired
        break
      fi
    fi
    
    sleep 0.5
  done
  
  # If registry file doesn't exist, create it
  if [ ! -f "$UDS_REGISTRY_FILE" ]; then
    echo '{"services":{}}' > "$UDS_REGISTRY_FILE"
    chmod 600 "$UDS_REGISTRY_FILE"
    rmdir "$lock_file" 2>/dev/null || true
    return 0
  fi
  
  # Read the registry file
  local registry_data=$(cat "$UDS_REGISTRY_FILE")
  
  # Release lock
  rmdir "$lock_file" 2>/dev/null || true
  
  # Get all service names
  local services=$(echo "$registry_data" | jq -r '.services | keys[]')
  
  echo "$services"
  return 0
}

# Get service deployment history
uds_get_service_history() {
  local app_name="$1"
  local max_entries="${2:-10}"
  
  # Get service data
  local service_data=$(uds_get_service "$app_name")
  
  if [ -z "$service_data" ]; then
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
  
  # Get service data
  local service_data=$(uds_get_service "$app_name")
  
  if [ -z "$service_data" ]; then
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
export -f uds_register_service uds_unregister_service uds_get_service
export -f uds_list_services uds_get_service_history uds_get_service_url
export -f uds_service_exists