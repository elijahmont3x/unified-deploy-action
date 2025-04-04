#!/bin/bash
#
# uds-plugin.sh - Plugin management for Unified Deployment System
#
# This module provides functions for plugin registration, dependency resolution, and execution

# Avoid loading multiple times
if [ -n "$UDS_PLUGIN_LOADED" ]; then
  return 0
fi

# Load dependencies
if [ -z "$UDS_ENV_LOADED" ]; then
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/uds-env.sh"
fi

if [ -z "$UDS_LOGGING_LOADED" ]; then
  source "${UDS_BASE_DIR}/uds-logging.sh"
fi

UDS_PLUGIN_LOADED=1

# Enhanced plugin registry with dependencies
declare -A UDS_PLUGIN_REGISTRY=()
declare -A UDS_PLUGIN_ARGS=()
declare -A UDS_PLUGIN_HOOKS=()
declare -A UDS_PLUGIN_DEPENDENCIES=()
declare -a UDS_PLUGIN_EXECUTION_ORDER=()
declare -A UDS_CIRCULAR_DEPENDENCY_FOUND=()

# Discover and register available plugins
uds_discover_plugins() {
  local plugin_dir="${UDS_PLUGINS_DIR}"
  
  if [ ! -d "$plugin_dir" ]; then
    uds_log "Plugin directory not found: $plugin_dir" "warning"
    mkdir -p "$plugin_dir"
    return 0
  fi
  
  # Clear existing plugin registry
  UDS_PLUGIN_REGISTRY=()
  
  # Find and source plugin files
  for plugin_file in "$plugin_dir"/*.sh; do
    # Skip if no plugins match the pattern (handle empty directories)
    if [ ! -f "$plugin_file" ]; then
      continue
    fi
    
    uds_log "Loading plugin: $(basename "$plugin_file")" "debug"
    
    # Source the plugin file with error handling
    if ! source "$plugin_file"; then
      uds_log "Error sourcing plugin: $(basename "$plugin_file")" "error"
      continue
    fi
    
    # Extract plugin name from filename
    local plugin_name=$(basename "$plugin_file" .sh)
    local register_func="plugin_register_${plugin_name//-/_}"
    
    # Check if registration function exists and call it
    if declare -f "$register_func" > /dev/null; then
      uds_log "Registering plugin: $plugin_name" "debug"
      if ! "$register_func"; then
        uds_log "Failed to register plugin: $plugin_name" "error"
        continue
      fi
      UDS_PLUGIN_REGISTRY["$plugin_name"]=1
    else
      uds_log "Plugin registration function not found: $register_func" "warning"
    fi
  done
  
  uds_log "Registered ${#UDS_PLUGIN_REGISTRY[@]} plugins" "debug"
}

# Activate specific plugins
uds_activate_plugins() {
  local plugins_to_activate="$1"
  
  if [ -z "$plugins_to_activate" ]; then
    return 0
  fi
  
  # Sort plugins by dependency order before activating
  local sorted_plugins=$(uds_sort_plugins "$plugins_to_activate")
  
  if [ -n "$sorted_plugins" ]; then
    uds_log "Activating plugins in dependency order: $sorted_plugins" "debug"
    
    IFS=',' read -ra PLUGIN_ARRAY <<< "$sorted_plugins"
    
    for plugin in "${PLUGIN_ARRAY[@]}"; do
      if [ -n "${UDS_PLUGIN_REGISTRY[$plugin]:-}" ]; then
        local activate_func="plugin_activate_${plugin//-/_}"
        
        if declare -f "$activate_func" > /dev/null; then
          uds_log "Activating plugin: $plugin" "debug"
          if ! "$activate_func"; then
            uds_log "Failed to activate plugin: $plugin" "warning"
          fi
        else
          uds_log "Activation function not found for plugin: $plugin" "warning"
        fi
      else
        uds_log "Plugin not found in registry: $plugin" "warning"
      fi
    done
  else
    # Handle the case where sorting failed (likely due to circular dependencies)
    uds_log "Plugin dependency resolution failed. Falling back to unsorted activation." "warning"
    
    IFS=',' read -ra PLUGIN_ARRAY <<< "$plugins_to_activate"
    
    for plugin in "${PLUGIN_ARRAY[@]}"; do
      plugin=$(echo "$plugin" | tr -d ' ')
      
      if [ -n "${UDS_PLUGIN_REGISTRY[$plugin]:-}" ]; then
        local activate_func="plugin_activate_${plugin//-/_}"
        
        if declare -f "$activate_func" > /dev/null; then
          uds_log "Activating plugin: $plugin" "debug"
          if ! "$activate_func"; then
            uds_log "Failed to activate plugin: $plugin" "warning"
          fi
        fi
      else
        uds_log "Plugin not found: $plugin" "warning"
      fi
    done
  fi
}

# Register a plugin argument
uds_register_plugin_arg() {
  local plugin="$1"
  local arg_name="$2"
  local default_value="$3"
  
  # Validate inputs
  if [ -z "$plugin" ] || [ -z "$arg_name" ]; then
    uds_log "Invalid argument registration: plugin and argument name must be provided" "error"
    return 1
  fi
  
  UDS_PLUGIN_ARGS["${plugin}_${arg_name}"]="$default_value"
  
  # If the value isn't already set, set it to the default
  if [ -z "${!arg_name+x}" ]; then
    eval "$arg_name=\"$default_value\""
    export "$arg_name"
  fi
}

# Get a plugin argument value
uds_get_plugin_arg() {
  local plugin="$1"
  local arg_name="$2"
  
  if [ -z "$plugin" ] || [ -z "$arg_name" ]; then
    uds_log "Invalid argument retrieval: plugin and argument name must be provided" "error"
    return 1
  fi
  
  echo "${UDS_PLUGIN_ARGS["${plugin}_${arg_name}"]:-}"
}

# Register a plugin hook
uds_register_plugin_hook() {
  local plugin="$1"
  local hook_name="$2"
  local hook_function="$3"
  
  # Validate inputs
  if [ -z "$plugin" ] || [ -z "$hook_name" ] || [ -z "$hook_function" ]; then
    uds_log "Invalid hook registration: plugin, hook name, and function must be provided" "error"
    return 1
  fi
  
  # Validate that the hook function exists
  if ! declare -f "$hook_function" > /dev/null; then
    uds_log "Invalid hook registration: function '$hook_function' does not exist" "error"
    return 1
  fi
  
  local hook_key="${hook_name}"
  
  # Initialize hook registry if needed
  if [ -z "${UDS_PLUGIN_HOOKS[$hook_key]:-}" ]; then
    UDS_PLUGIN_HOOKS["$hook_key"]="$hook_function"
  else
    UDS_PLUGIN_HOOKS["$hook_key"]="${UDS_PLUGIN_HOOKS[$hook_key]},$hook_function"
  fi
}

# List all registered hooks
uds_list_hooks() {
  for hook_name in "${!UDS_PLUGIN_HOOKS[@]}"; do
    echo "$hook_name: ${UDS_PLUGIN_HOOKS[$hook_name]}"
  done
}

# Register a plugin dependency with enhanced validation
uds_register_plugin_dependency() {
  local plugin="$1"
  local depends_on="$2"
  
  # Validate inputs
  if [ -z "$plugin" ] || [ -z "$depends_on" ]; then
    uds_log "Invalid dependency registration: plugin and dependency must be provided" "error"
    return 1
  fi
  
  # Prevent self-dependencies
  if [ "$plugin" = "$depends_on" ]; then
    uds_log "Invalid dependency: plugin '$plugin' cannot depend on itself" "error"
    return 1
  fi
  
  # Warn about unregistered dependencies
  if [ -z "${UDS_PLUGIN_REGISTRY[$depends_on]:-}" ]; then
    uds_log "Warning: Plugin '$plugin' depends on unregistered plugin '$depends_on'" "warning"
    # Continue anyway as the dependency might be registered later
  fi
  
  # Initialize dependency array if it doesn't exist
  if [ -z "${UDS_PLUGIN_DEPENDENCIES[$plugin]:-}" ]; then
    UDS_PLUGIN_DEPENDENCIES["$plugin"]=""
  fi
  
  # Add the dependency if not already present
  if [[ ! "${UDS_PLUGIN_DEPENDENCIES[$plugin]}" =~ (^|,)"$depends_on"(,|$) ]]; then
    # Store dependency with optional flag
    if [ -n "${UDS_PLUGIN_DEPENDENCIES[$plugin]}" ]; then
      UDS_PLUGIN_DEPENDENCIES["$plugin"]="${UDS_PLUGIN_DEPENDENCIES[$plugin]},${depends_on}"
    else
      UDS_PLUGIN_DEPENDENCIES["$plugin"]="$depends_on"
    fi
    
    uds_log "Registered dependency: $plugin depends on $depends_on" "debug"
    
    # Check for circular dependencies early (this is a shallow check, deep circular deps are detected during sort)
    if [ -n "${UDS_PLUGIN_DEPENDENCIES[$depends_on]:-}" ]; then
      if [[ "${UDS_PLUGIN_DEPENDENCIES[$depends_on]}" =~ (^|,)"$plugin"(,|$) ]]; then
        uds_log "Warning: Circular dependency detected between $plugin and $depends_on" "warning"
      fi
    fi
  fi
  
  return 0
}

# Get dependencies for a plugin
uds_get_dependencies() {
  local plugin="$1"
  
  if [ -z "$plugin" ]; then
    uds_log "Invalid argument: plugin name must be provided" "error"
    return 1
  fi
  
  echo "${UDS_PLUGIN_DEPENDENCIES[$plugin]:-}"
}

# Sort plugins in dependency order using enhanced topological sort
uds_sort_plugins() {
  local plugin_list="$1"
  
  # Skip if no plugins specified
  if [ -z "$plugin_list" ]; then
    return 0
  fi
  
  # Reset tracking variables
  UDS_PLUGIN_EXECUTION_ORDER=()
  UDS_CIRCULAR_DEPENDENCY_FOUND=()
  
  # Split comma-separated list
  IFS=',' read -ra PLUGINS_ARRAY <<< "$plugin_list"
  
  # Build dependency graph
  declare -A graph=()
  declare -A visited=()
  declare -A temp_mark=()
  declare -A current_path=()  # For tracking the current path for better cycle reporting
  
  for plugin in "${PLUGINS_ARRAY[@]}"; do
    # Skip invalid plugin names
    if [ -z "$plugin" ]; then
      continue
    fi
    
    # Store dependencies in the graph
    if [ -n "${UDS_PLUGIN_DEPENDENCIES[$plugin]:-}" ]; then
      graph["$plugin"]="${UDS_PLUGIN_DEPENDENCIES[$plugin]}"
    else
      graph["$plugin"]=""
    fi
    
    # Initialize visit tracking
    visited["$plugin"]=0
    temp_mark["$plugin"]=0
    current_path["$plugin"]=0
  done
  
  # Topological sort with cycle detection
  for plugin in "${!graph[@]}"; do
    if [ "${visited[$plugin]:-0}" -eq 0 ]; then
      if ! _uds_visit_plugin "$plugin" graph visited temp_mark current_path; then
        # Cycle detected, add special handling here
        uds_log "Circular dependency detected involving plugin: $plugin" "error"
        UDS_CIRCULAR_DEPENDENCY_FOUND["$plugin"]=1
        
        # We still try to continue with remaining plugins
        continue
      fi
    fi
  done
  
  # Handle the case where circular dependencies were detected
  if [ "${#UDS_CIRCULAR_DEPENDENCY_FOUND[@]}" -gt 0 ]; then
    uds_log "Warning: ${#UDS_CIRCULAR_DEPENDENCY_FOUND[@]} circular dependencies detected. Dependency order may not be optimal." "warning"
    
    # Log the specific circular dependencies for debugging
    for plugin in "${!UDS_CIRCULAR_DEPENDENCY_FOUND[@]}"; do
      uds_log "Circular dependency involves plugin: $plugin" "debug"
    done
  fi
  
  # Return sorted list or empty string on failure
  if [ ${#UDS_PLUGIN_EXECUTION_ORDER[@]} -gt 0 ]; then
    local sorted_plugins=$(IFS=,; echo "${UDS_PLUGIN_EXECUTION_ORDER[*]}")
    echo "$sorted_plugins"
    return 0
  else
    # No plugins were successfully sorted
    uds_log "Failed to sort plugins due to dependency issues" "error"
    return 1
  fi
}

# Enhanced helper function for topological sort with better cycle detection
_uds_visit_plugin() {
  local plugin="$1"
  local -n _graph="$2"
  local -n _visited="$3"
  local -n _temp="$4"
  local -n _path="$5"
  
  # Check for circular dependency with path tracking
  if [ "${_temp[$plugin]:-0}" -eq 1 ]; then
    # We've detected a cycle - build the cycle path for better reporting
    local cycle_path="$plugin"
    for p in "${!_path[@]}"; do
      if [ "${_path[$p]}" -eq 1 ]; then
        cycle_path+=" -> $p"
      fi
    done
    
    uds_log "Circular dependency detected: $cycle_path -> $plugin" "error"
    return 1
  fi
  
  # Skip if already visited
  if [ "${_visited[$plugin]:-0}" -eq 1 ]; then
    return 0
  fi
  
  # Mark temporarily and add to current path
  _temp["$plugin"]=1
  _path["$plugin"]=1
  
  # Visit dependencies with enhanced error handling
  if [ -n "${_graph[$plugin]:-}" ]; then
    IFS=',' read -ra DEPS <<< "${_graph[$plugin]}"
    for dep in "${DEPS[@]}"; do
      # Skip empty dependencies (can happen with trailing commas)
      if [ -z "$dep" ]; then
        continue
      fi
      
      # Check if dependency exists in graph
      if [ -z "${_graph[$dep]:-}" ]; then
        uds_log "Warning: Plugin '$plugin' depends on '$dep' which is not available" "warning"
        # Continue anyway - we don't want to fail the entire sort for a missing dependency
        continue
      fi
      
      if ! _uds_visit_plugin "$dep" _graph _visited _temp _path; then
        # Propagate cycle detection upward
        _path["$plugin"]=0
        return 1
      fi
    done
  fi
  
  # Mark as visited
  _visited["$plugin"]=1
  _temp["$plugin"]=0
  _path["$plugin"]=0
  
  # Add to sorted list (reverse order)
  UDS_PLUGIN_EXECUTION_ORDER=("$plugin" "${UDS_PLUGIN_EXECUTION_ORDER[@]}")
  
  return 0
}

# Updated execute hook function with enhanced dependency-ordered execution
uds_execute_hook() {
  local hook_name="$1"
  shift
  
  local hook_key="${hook_name}"
  
  if [ -n "${UDS_PLUGIN_HOOKS[$hook_key]:-}" ]; then
    uds_log "Executing hook: $hook_name" "debug"
    
    # Get all registered hook functions
    local all_hook_functions=()
    IFS=',' read -ra HOOK_FUNCTIONS <<< "${UDS_PLUGIN_HOOKS[$hook_key]}"
    
    # Map hook functions to their plugins
    declare -A hook_plugin_map=()
    for hook_function in "${HOOK_FUNCTIONS[@]}"; do
      # Extract plugin name from function name (assuming format plugin_*_function)
      local plugin_name=$(echo "$hook_function" | sed -n 's/plugin_\([^_]*\)_.*/\1/p')
      
      if [ -n "$plugin_name" ]; then
        hook_plugin_map["$hook_function"]="$plugin_name"
      else
        uds_log "Warning: Could not determine plugin for hook function: $hook_function" "warning"
        hook_plugin_map["$hook_function"]="unknown"
      fi
    done
    
    # Collect all plugins that have hooks for this event
    local plugins_with_hooks=""
    for hook_function in "${HOOK_FUNCTIONS[@]}"; do
      local plugin="${hook_plugin_map[$hook_function]}"
      if [ "$plugin" != "unknown" ]; then
        if [ -n "$plugins_with_hooks" ]; then
          # Only add if not already in the list
          if [[ ! "$plugins_with_hooks" =~ (^|,)"$plugin"(,|$) ]]; then
            plugins_with_hooks="$plugins_with_hooks,$plugin"
          fi
        else
          plugins_with_hooks="$plugin"
        fi
      fi
    done
    
    # Sort plugins by dependency order
    local sorted_plugins=""
    if [ -n "$plugins_with_hooks" ]; then
      sorted_plugins=$(uds_sort_plugins "$plugins_with_hooks")
    fi
    
    if [ -n "$sorted_plugins" ]; then
      uds_log "Executing hook $hook_name in dependency order: $sorted_plugins" "debug"
      
      # Execute hooks in dependency order
      IFS=',' read -ra SORTED_PLUGINS <<< "$sorted_plugins"
      for plugin in "${SORTED_PLUGINS[@]}"; do
        for hook_function in "${HOOK_FUNCTIONS[@]}"; do
          if [ "${hook_plugin_map[$hook_function]}" = "$plugin" ]; then
            uds_log "Executing hook function: $hook_function" "debug"
            if ! "$hook_function" "$@"; then
              uds_log "Hook execution failed: $hook_function" "warning"
            fi
          fi
        done
      done
    else
      # Fallback to unsorted execution if dependency resolution failed
      uds_log "Plugin dependency resolution failed, executing hooks in registration order" "warning"
      for hook_function in "${HOOK_FUNCTIONS[@]}"; do
        uds_log "Executing hook function: $hook_function" "debug"
        if ! "$hook_function" "$@"; then
          uds_log "Hook execution failed: $hook_function" "warning"
        fi
      done
    fi
  else
    uds_log "No hooks registered for: $hook_name" "debug"
  fi
}

# Export module state and functions
export UDS_PLUGIN_LOADED
export -A UDS_PLUGIN_REGISTRY
export -A UDS_PLUGIN_ARGS
export -A UDS_PLUGIN_HOOKS
export -A UDS_PLUGIN_DEPENDENCIES
export -a UDS_PLUGIN_EXECUTION_ORDER
export -f uds_discover_plugins uds_activate_plugins uds_sort_plugins
export -f uds_register_plugin_arg uds_get_plugin_arg 
export -f uds_register_plugin_hook uds_list_hooks
export -f uds_register_plugin_dependency uds_get_dependencies
export -f uds_execute_hook