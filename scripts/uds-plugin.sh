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
  
  IFS=',' read -ra PLUGIN_ARRAY <<< "$plugins_to_activate"
  
  for plugin in "${PLUGIN_ARRAY[@]}"; do
    plugin=$(echo "$plugin" | tr -d ' ')
    
    if [ -n "${UDS_PLUGIN_REGISTRY[$plugin]:-}" ]; then
      local activate_func="plugin_activate_${plugin//-/_}"
      
      if declare -f "$activate_func" > /dev/null; then
        uds_log "Activating plugin: $plugin" "debug"
        "$activate_func"
      fi
    else
      uds_log "Plugin not found: $plugin" "warning"
    fi
  done
}

# Register a plugin argument
uds_register_plugin_arg() {
  local plugin="$1"
  local arg_name="$2"
  local default_value="$3"
  
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
  
  echo "${UDS_PLUGIN_ARGS["${plugin}_${arg_name}"]:-}"
}

# Register a plugin hook
uds_register_plugin_hook() {
  local plugin="$1"
  local hook_name="$2"
  local hook_function="$3"
  
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

# Register a plugin dependency
uds_register_plugin_dependency() {
  local plugin="$1"
  local depends_on="$2"
  
  # Initialize dependency array if it doesn't exist
  if [ -z "${UDS_PLUGIN_DEPENDENCIES[$plugin]:-}" ]; then
    UDS_PLUGIN_DEPENDENCIES["$plugin"]=""
  fi
  
  # Add the dependency
  if [ -n "${UDS_PLUGIN_DEPENDENCIES[$plugin]}" ]; then
    UDS_PLUGIN_DEPENDENCIES["$plugin"]="${UDS_PLUGIN_DEPENDENCIES[$plugin]},${depends_on}"
  else
    UDS_PLUGIN_DEPENDENCIES["$plugin"]="$depends_on"
  fi
  
  uds_log "Registered dependency: $plugin depends on $depends_on" "debug"
}

# Sort plugins in dependency order using topological sort
uds_sort_plugins() {
  local plugin_list="$1"
  
  # Skip if no plugins specified
  if [ -z "$plugin_list" ]; then
    return 0
  fi
  
  # Split comma-separated list
  IFS=',' read -ra PLUGINS_ARRAY <<< "$plugin_list"
  
  # Build dependency graph
  declare -A graph=()
  declare -A visited=()
  declare -A temp_mark=()
  
  for plugin in "${PLUGINS_ARRAY[@]}"; do
    if [ -n "${UDS_PLUGIN_DEPENDENCIES[$plugin]:-}" ]; then
      IFS=',' read -ra DEPS <<< "${UDS_PLUGIN_DEPENDENCIES[$plugin]}"
      graph["$plugin"]="${UDS_PLUGIN_DEPENDENCIES[$plugin]}"
    else
      graph["$plugin"]=""
    fi
    visited["$plugin"]=0
  done
  
  # Reset execution order
  UDS_PLUGIN_EXECUTION_ORDER=()
  
  # Topological sort
  for plugin in "${!graph[@]}"; do
    if [ "${visited[$plugin]:-0}" -eq 0 ]; then
      _uds_visit_plugin "$plugin" graph visited temp_mark
    fi
  done
  
  # Return sorted list
  local sorted_plugins=$(IFS=,; echo "${UDS_PLUGIN_EXECUTION_ORDER[*]}")
  echo "$sorted_plugins"
}

# Helper function for topological sort
_uds_visit_plugin() {
  local plugin="$1"
  local -n _graph="$2"
  local -n _visited="$3"
  local -n _temp="$4"
  
  # Check for circular dependency
  if [ "${_temp[$plugin]:-0}" -eq 1 ]; then
    uds_log "Circular dependency detected involving plugin: $plugin" "error"
    return 1
  fi
  
  # Skip if already visited
  if [ "${_visited[$plugin]:-0}" -eq 1 ]; then
    return 0
  fi
  
  # Mark temporarily
  _temp["$plugin"]=1
  
  # Visit dependencies
  if [ -n "${_graph[$plugin]:-}" ]; then
    IFS=',' read -ra DEPS <<< "${_graph[$plugin]}"
    for dep in "${DEPS[@]}"; do
      if [ -n "$dep" ]; then
        _uds_visit_plugin "$dep" _graph _visited _temp
      fi
    done
  fi
  
  # Mark as visited
  _visited["$plugin"]=1
  _temp["$plugin"]=0
  
  # Add to sorted list (reverse order)
  UDS_PLUGIN_EXECUTION_ORDER=("$plugin" "${UDS_PLUGIN_EXECUTION_ORDER[@]}")
}

# Updated execute hook function with dependency-ordered execution
uds_execute_hook() {
  local hook_name="$1"
  shift
  
  local hook_key="${hook_name}"
  
  if [ -n "${UDS_PLUGIN_HOOKS[$hook_key]:-}" ]; then
    # Sort plugins by dependency order and then execute hooks
    local sorted_plugins=$(uds_sort_plugins "$PLUGINS")
    
    if [ -n "$sorted_plugins" ]; then
      uds_log "Executing hook $hook_name in dependency order: $sorted_plugins" "debug"
      
      # First, collect all hook functions
      local all_hook_functions=()
      IFS=',' read -ra HOOK_FUNCTIONS <<< "${UDS_PLUGIN_HOOKS[$hook_key]}"
      
      # Map hook functions to their plugins
      declare -A hook_plugin_map=()
      for hook_function in "${HOOK_FUNCTIONS[@]}"; do
        # Extract plugin name from function name (assuming format plugin_*_function)
        local plugin_name=$(echo "$hook_function" | sed -n 's/plugin_\([^_]*\)_.*/\1/p')
        hook_plugin_map["$hook_function"]="$plugin_name"
      done
      
      # Execute hooks in dependency order
      IFS=',' read -ra SORTED_PLUGINS <<< "$sorted_plugins"
      for plugin in "${SORTED_PLUGINS[@]}"; do
        for hook_function in "${HOOK_FUNCTIONS[@]}"; do
          if [ "${hook_plugin_map[$hook_function]}" = "$plugin" ]; then
            uds_log "Executing hook: $hook_function for $hook_name" "debug"
            if ! "$hook_function" "$@"; then
              uds_log "Hook execution failed: $hook_function" "warning"
            fi
          fi
        done
      done
    else
      # Fallback to unsorted execution if sorting fails
      uds_log "Executing hook $hook_name (unsorted)" "debug"
      IFS=',' read -ra HOOK_FUNCTIONS <<< "${UDS_PLUGIN_HOOKS[$hook_key]}"
      for hook_function in "${HOOK_FUNCTIONS[@]}"; do
        uds_log "Executing hook: $hook_function for $hook_name" "debug"
        if ! "$hook_function" "$@"; then
          uds_log "Hook execution failed: $hook_function" "warning"
        fi
      done
    fi
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
export -f uds_register_plugin_dependency uds_execute_hook