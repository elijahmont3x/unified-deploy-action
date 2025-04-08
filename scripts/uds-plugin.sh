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

# Enhanced plugin registry with dependency visualization and cycle detection
declare -A UDS_PLUGIN_REGISTRY=()  # All registered plugins
declare -A UDS_PLUGIN_ARGS=()      # Plugin arguments
declare -A UDS_PLUGIN_HOOKS=()     # Plugin hooks
declare -A UDS_PLUGIN_DEPENDENCIES=() # Plugin dependencies
declare -a UDS_PLUGIN_EXECUTION_ORDER=() # Ordered list of plugins for execution
declare -A UDS_CIRCULAR_DEPENDENCY_DETAIL=() # Detailed info about circular dependencies

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
  UDS_PLUGIN_ARGS=()
  UDS_PLUGIN_HOOKS=()
  UDS_PLUGIN_DEPENDENCIES=()
  UDS_CIRCULAR_DEPENDENCY_DETAIL=()
  
  # Find and source plugin files
  local plugins_found=0
  
  # Look for *.sh files directly in the plugins directory
  for plugin_file in "$plugin_dir"/*.sh; do
    # Skip if no plugins match the pattern (handle empty directories)
    if [[ ! -f "$plugin_file" ]]; then
      continue
    fi
    
    plugins_found=$((plugins_found + 1))
    uds_log "Loading plugin: $(basename "$plugin_file")" "debug"
    
    # Source the plugin file with error handling
    if ! source "$plugin_file"; then
      uds_log "Error sourcing plugin: $(basename "$plugin_file")" "error"
      continue
    fi
    
    # Extract plugin name from filename
    local plugin_name=$(basename "$plugin_file" .sh)
    local register_func="plugin_register_${plugin_name//-/_}"
    
    # Add debug output
    uds_log "Looking for registration function: $register_func in plugin $(basename $plugin_file)" "debug"
    declare -F | grep -q "$register_func" && uds_log "Found function!" "debug" || uds_log "Function not found" "debug"
    
    # Check if registration function exists and call it
    if declare -f "$register_func" > /dev/null; then
      uds_log "Registering plugin: $plugin_name" "debug"
      if ! "$register_func"; then
        uds_log "Failed to register plugin: $plugin_name" "error"
        continue
      fi
      
      # Mark plugin as registered
      UDS_PLUGIN_REGISTRY["$plugin_name"]=1
    else
      uds_log "Plugin registration function not found: $register_func" "warning"
    fi
  done
  
  if [ $plugins_found -eq 0 ]; then
    uds_log "No plugins found in: $plugin_dir" "warning"
  else
    uds_log "Found and processed $plugins_found plugins, registered ${#UDS_PLUGIN_REGISTRY[@]}" "debug"
    
    # Verify plugin dependencies
    uds_verify_plugin_dependencies
  fi
  
  return 0
}

# Verify all plugin dependencies
uds_verify_plugin_dependencies() {
  local missing_deps=0
  local circular_deps=0
  
  # Check for missing dependencies
  for plugin in "${!UDS_PLUGIN_REGISTRY[@]}"; do
    local deps="${UDS_PLUGIN_DEPENDENCIES[$plugin]:-}"
    
    if [ -n "$deps" ]; then
      IFS=',' read -ra DEPS_ARRAY <<< "$deps"
      
      for dep in "${DEPS_ARRAY[@]}"; do
        # Skip empty deps (can happen with trailing commas)
        if [ -z "$dep" ]; then
          continue
        fi
        
        # Extract dependency name (remove optional flag if present)
        local dep_name="${dep%%:*}"
        local is_optional=false
        if [[ "$dep" == *":optional"* ]]; then
          is_optional=true
        fi
        
        # Check if dependency exists
        if [ -z "${UDS_PLUGIN_REGISTRY[$dep_name]:-}" ]; then
          if [ "$is_optional" = "true" ]; then
            uds_log "Optional dependency '$dep_name' for plugin '$plugin' is not available" "info"
          else
            uds_log "Required dependency '$dep_name' for plugin '$plugin' is not available" "warning"
            missing_deps=$((missing_deps + 1))
          fi
        fi
      done
    fi
  done
  
  # Check for circular dependencies using a test sort
  uds_plugin_has_circular_deps || true
  
  # Count circular dependencies
  for plugin in "${!UDS_CIRCULAR_DEPENDENCY_DETAIL[@]}"; do
    circular_deps=$((circular_deps + 1))
  done
  
  # Report findings
  if [ $missing_deps -gt 0 ] || [ $circular_deps -gt 0 ]; then
    uds_log "Plugin dependency verification found $missing_deps missing and $circular_deps circular dependencies" "warning"
    
    # Show details of circular dependencies
    if [ $circular_deps -gt 0 ]; then
      uds_log "Circular dependency details:" "warning"
      for plugin in "${!UDS_CIRCULAR_DEPENDENCY_DETAIL[@]}"; do
        uds_log " - ${UDS_CIRCULAR_DEPENDENCY_DETAIL[$plugin]}" "warning"
      done
      
      uds_log "Suggestions to resolve circular dependencies:" "info"
      uds_log " 1. Identify which dependency is not essential and mark it as optional" "info"
      uds_log " 2. Refactor plugins to eliminate the circular dependency" "info"
      uds_log " 3. Merge plugins that have circular dependencies into a single plugin" "info"
    fi
  else
    uds_log "Plugin dependencies verified successfully" "debug"
  fi
}

# Check if plugins have circular dependencies
uds_plugin_has_circular_deps() {
  # Reset circular dependency details
  UDS_CIRCULAR_DEPENDENCY_DETAIL=()
  
  # Build a temporary graph for the test
  declare -A test_graph=()
  for plugin in "${!UDS_PLUGIN_REGISTRY[@]}"; do
    test_graph["$plugin"]="${UDS_PLUGIN_DEPENDENCIES[$plugin]:-}"
  done
  
  # Check each plugin
  for plugin in "${!test_graph[@]}"; do
    # Skip already checked plugins with circular deps
    if [ -n "${UDS_CIRCULAR_DEPENDENCY_DETAIL[$plugin]:-}" ]; then
      continue
    fi
    
    # Reset visit tracking for each starting plugin
    declare -A tested_visited=()
    declare -A tested_path=()  # Track current exploration path
    declare -a path_stack=()   # Stack to track the exploration path
    
    # Test for circular dependencies
    if ! _uds_test_plugin_deps "$plugin" test_graph tested_visited tested_path path_stack; then
      # If this returns false, a circular dependency was found
      # Detailed info is already stored in UDS_CIRCULAR_DEPENDENCY_DETAIL
      return 1
    fi
  done
  
  # No circular dependencies found
  return 0
}

# Helper for checking circular dependencies
_uds_test_plugin_deps() {
  local plugin="$1"
  # Pass array references by name, not by reference
  local graph_name="$2"
  local visited_name="$3"
  local path_name="$4"
  local stack_name="$5"
  
  # Use indirect references to avoid circular references
  local -n _graph="$graph_name"
  local -n _visited="$visited_name"
  local -n _path="$path_name"
  local -n _stack="$stack_name"
  
  # If already in path, we found a cycle
  if [ "${_path[$plugin]:-0}" -eq 1 ]; then
    # Build cycle path for diagnostic output
    local cycle_index=-1
    for ((i=0; i<${#_stack[@]}; i++)); do
      if [ "${_stack[$i]}" = "$plugin" ]; then
        cycle_index=$i
        break
      fi
    done
    
    if [ $cycle_index -ge 0 ]; then
      # Extract the cycle from the stack
      local cycle_path="$plugin"
      for ((i=cycle_index+1; i<${#_stack[@]}; i++)); do
        cycle_path+=" -> ${_stack[$i]}"
      done
      cycle_path+=" -> $plugin"
      
      # Store detailed info about the cycle
      local plugins_in_cycle=()
      IFS=' -> ' read -ra plugins_in_cycle <<< "$cycle_path"
      for p in "${plugins_in_cycle[@]}"; do
        if [ "$p" != "" ]; then  # Skip empty strings
          UDS_CIRCULAR_DEPENDENCY_DETAIL["$p"]="$cycle_path"
        fi
      done
    else
      # Fallback if cycle detection mechanism fails
      UDS_CIRCULAR_DEPENDENCY_DETAIL["$plugin"]="Circular dependency involving plugin: $plugin"
    fi
    
    return 1
  fi
  
  # If already fully visited, no cycle through this node
  if [ "${_visited[$plugin]:-0}" -eq 1 ]; then
    return 0
  fi
  
  # Mark as in current path and add to stack
  _path["$plugin"]=1
  _stack+=("$plugin")
  
  # Process dependencies
  if [ -n "${_graph[$plugin]:-}" ]; then
    IFS=',' read -ra DEPS <<< "${_graph[$plugin]}"
    for dep in "${DEPS[@]}"; do
      # Skip empty dependencies (can happen with trailing commas)
      if [ -z "$dep" ]; then
        continue
      fi
      
      # Extract dependency name (strip optional flag if present)
      local dep_name="${dep%%:*}"
      
      # Skip if dependency doesn't exist in graph
      if [ -z "${_graph[$dep_name]:-}" ]; then
        continue
      fi
      
      # Recursively check this dependency
      if ! _uds_test_plugin_deps "$dep_name" _graph _visited _path _stack; then
        # Propagate cycle detection upward
        # Already removed from path below
        return 1
      fi
    done
  fi
  
  # Mark as fully visited
  _visited["$plugin"]=1
  
  # Remove from current path
  _path["$plugin"]=0
  
  # Remove from stack (pop the last element)
  unset "_stack[${#_stack[@]}-1]"
  
  return 0
}

# Activate specific plugins with better dependency handling
uds_activate_plugins() {
  local plugins_to_activate="$1"
  
  if [ -z "$plugins_to_activate" ]; then
    return 0
  fi
  
  uds_log "Preparing to activate plugins: $plugins_to_activate" "debug"
  
  # Convert comma-separated list to array
  local plugin_array=()
  IFS=',' read -ra plugin_array <<< "$plugins_to_activate"
  
  # Verify plugins exist
  local missing_count=0
  local valid_plugins=""
  
  for plugin in "${plugin_array[@]}"; do
    # Remove any whitespace
    plugin=$(echo "$plugin" | tr -d ' ')
    
    if [ -n "$plugin" ]; then
      if [ -n "${UDS_PLUGIN_REGISTRY[$plugin]:-}" ]; then
        # Add to valid plugins list
        if [ -n "$valid_plugins" ]; then
          valid_plugins="$valid_plugins,$plugin"
        else
          valid_plugins="$plugin"
        fi
      else
        uds_log "Plugin not found: $plugin" "warning"
        missing_count=$((missing_count + 1))
      fi
    fi
  done
  
  if [ $missing_count -gt 0 ]; then
    uds_log "$missing_count plugins not found in registry" "warning"
  fi
  
  # Skip if no valid plugins
  if [ -z "$valid_plugins" ]; then
    uds_log "No valid plugins to activate" "warning"
    return 0
  fi
  
  # Sort plugins by dependency order
  local sorted_plugins=$(uds_sort_plugins "$valid_plugins")
  
  if [ -n "$sorted_plugins" ]; then
    uds_log "Activating plugins in dependency order: $sorted_plugins" "debug"
    
    IFS=',' read -ra PLUGIN_ARRAY <<< "$sorted_plugins"
    
    for plugin in "${PLUGIN_ARRAY[@]}"; do
      local activate_func="plugin_activate_${plugin//-/_}"
      
      if declare -f "$activate_func" > /dev/null; then
        uds_log "Activating plugin: $plugin" "debug"
        if ! "$activate_func"; then
          uds_log "Failed to activate plugin: $plugin" "warning"
        fi
      else
        uds_log "Activation function not found for plugin: $plugin" "debug"
        # Not an error - some plugins might not need an activation function
      fi
    done
  else
    # Handle the case where sorting failed (likely due to circular dependencies)
    uds_log "Plugin dependency resolution failed. Activating plugins in original order." "warning"
    
    # Show circular dependencies if detected
    if [ ${#UDS_CIRCULAR_DEPENDENCY_DETAIL[@]} -gt 0 ]; then
      uds_log "Circular dependencies detected:" "warning"
      for plugin in "${!UDS_CIRCULAR_DEPENDENCY_DETAIL[@]}"; do
        uds_log " - ${UDS_CIRCULAR_DEPENDENCY_DETAIL[$plugin]}" "warning"
      done
    fi
    
    # Activate in the order specified by the user, skipping plugins involved in circles
    IFS=',' read -ra PLUGIN_ARRAY <<< "$valid_plugins"
    
    for plugin in "${PLUGIN_ARRAY[@]}"]; do
      # Skip plugins involved in circular dependencies
      if [ -n "${UDS_CIRCULAR_DEPENDENCY_DETAIL[$plugin]:-}" ]; then
        uds_log "Skipping plugin in circular dependency: $plugin" "warning"
        continue
      fi
      
      local activate_func="plugin_activate_${plugin//-/_}"
      
      if declare -f "$activate_func" > /dev/null; then
        uds_log "Activating plugin: $plugin" "debug"
        if ! "$activate_func"; then
          uds_log "Failed to activate plugin: $plugin" "warning"
        fi
      fi
    done
  fi
  
  return 0
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
    eval "export $arg_name"
  fi
  
  return 0
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
  return 0
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
  
  return 0
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
  local is_optional="${3:-false}"
  
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
    if [ "$is_optional" = "true" ]; then
      uds_log "Optional dependency '$depends_on' for plugin '$plugin' is not currently registered" "debug"
    else
      uds_log "Warning: Plugin '$plugin' depends on unregistered plugin '$depends_on'" "warning"
    fi
    # Continue anyway as the dependency might be registered later
  fi
  
  # Initialize dependency array if it doesn't exist
  if [ -z "${UDS_PLUGIN_DEPENDENCIES[$plugin]:-}" ]; then
    UDS_PLUGIN_DEPENDENCIES["$plugin"]=""
  fi
  
  # Format dependency with optional flag if needed
  local dep_entry="$depends_on"
  if [ "$is_optional" = "true" ]; then
    dep_entry="${dep_entry}:optional"
  fi
  
  # Add the dependency if not already present
  if [[ ! "${UDS_PLUGIN_DEPENDENCIES[$plugin]}" =~ (^|,)"$depends_on"(,|$) ]] && [[ ! "${UDS_PLUGIN_DEPENDENCIES[$plugin]}" =~ (^|,)"$depends_on":optional(,|$) ]]; then
    # Add to dependency list
    if [ -n "${UDS_PLUGIN_DEPENDENCIES[$plugin]}" ]; then
      UDS_PLUGIN_DEPENDENCIES["$plugin"]="${UDS_PLUGIN_DEPENDENCIES[$plugin]},${dep_entry}"
    else
      UDS_PLUGIN_DEPENDENCIES["$plugin"]="$dep_entry"
    fi
    
    uds_log "Registered dependency: $plugin depends on $depends_on (optional: $is_optional)" "debug"
    
    # Check for potential circular dependency
    if uds_has_dependency "$depends_on" "$plugin"; then
      uds_log "Warning: Potential circular dependency between $plugin and $depends_on" "warning"
      
      # Build and store the dependency path
      local cycle_path="$plugin -> $depends_on -> $plugin"
      UDS_CIRCULAR_DEPENDENCY_DETAIL["$plugin"]="$cycle_path"
      UDS_CIRCULAR_DEPENDENCY_DETAIL["$depends_on"]="$cycle_path"
    fi
  fi
  
  return 0
}

# Get dependencies for a plugin
uds_get_dependencies() {
  local plugin="$1"
  local include_optional="${2:-true}"
  
  if [ -z "$plugin" ]; then
    return 0
  fi
  
  # Return raw dependencies if including optional
  if [ "$include_optional" = "true" ]; then
    echo "${UDS_PLUGIN_DEPENDENCIES[$plugin]:-}"
    return 0
  fi
  
  # Filter out optional dependencies
  local deps="${UDS_PLUGIN_DEPENDENCIES[$plugin]:-}"
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

# Check if a plugin has dependency on another plugin (direct or indirect)
uds_has_dependency() {
  local plugin="$1"
  local dependency="$2"
  local visited=()
  
  _uds_check_dependency "$plugin" "$dependency" visited
}

# Helper function for checking dependencies (recursive)
_uds_check_dependency() {
  local plugin="$1"
  local dependency="$2"
  local -n _visited="$3"
  
  # Check if already visited to avoid cycles
  for v in "${_visited[@]}"; do
    if [ "$v" = "$plugin" ]; then
      return 1
    fi
  done
  
  # Add to visited
  _visited+=("$plugin")
  
  # Extract dependencies from the plugin
  local deps="${UDS_PLUGIN_DEPENDENCIES[$plugin]:-}"
  if [ -n "$deps" ]; then
    IFS=',' read -ra DEPS_ARRAY <<< "$deps"
    
    for dep in "${DEPS_ARRAY[@]}"; do
      # Skip empty deps (can happen with trailing commas)
      if [ -z "$dep" ]; then
        continue
      fi
      
      # Extract dependency name (strip optional flag if present)
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

# Sort plugins in dependency order with enhanced cycle detection
uds_sort_plugins() {
  local plugin_list="$1"
  
  # Skip if no plugins specified
  if [ -z "$plugin_list" ]; then
    return 0
  fi
  
  # Reset results
  UDS_PLUGIN_EXECUTION_ORDER=()
  
  # Check for circular dependencies first
  if uds_plugin_has_circular_deps; then
    uds_log "No circular dependencies detected, proceeding with topological sort" "debug"
  else
    uds_log "Circular dependencies detected, topological sort may not produce optimal results" "warning"
  fi
  
  # Split comma-separated list
  IFS=',' read -ra PLUGINS_ARRAY <<< "$plugin_list"
  
  # Build dependency graph, skipping plugins with circular dependencies
  declare -A graph=()
  declare -A visited=()
  declare -A temp_mark=()
  
  for plugin in "${PLUGINS_ARRAY[@]}"; do
    # Skip invalid plugin names
    if [ -z "$plugin" ]; then
      continue
    fi
    
    # Store dependencies in the graph
    graph["$plugin"]="$(uds_get_dependencies "$plugin" true)"
    
    # Initialize visit tracking
    visited["$plugin"]=0
    temp_mark["$plugin"]=0
  done
  
  # Topological sort with cycle handling
  for plugin in "${!graph[@]}"; do
    if [ "${visited[$plugin]:-0}" -eq 0 ]; then
      if ! _uds_visit_plugin "$plugin" graph visited temp_mark; then
        # Cycle detected
        uds_log "Skipping circular dependency involving $plugin" "warning"
        # Continue with other plugins
      fi
    fi
  done
  
  # Handle the case where circular dependencies were detected
  if [ ${#UDS_CIRCULAR_DEPENDENCY_DETAIL[@]} -gt 0 ]; then
    uds_log "Warning: ${#UDS_CIRCULAR_DEPENDENCY_DETAIL[@]} circular dependencies affect plugin ordering" "warning"
    
    # Check if any plugins with circular dependencies are missing from the execution order
    local missing_circulars=()
    for plugin in "${!UDS_CIRCULAR_DEPENDENCY_DETAIL[@]}"; do
      local found=false
      for ordered_plugin in "${UDS_PLUGIN_EXECUTION_ORDER[@]}"; do
        if [ "$ordered_plugin" = "$plugin" ]; then
          found=true
          break
        fi
      done
      
      if [ "$found" = "false" ]; then
        missing_circulars+=("$plugin")
      fi
    done
    
    # Add missing plugins at the end (better than nothing)
    if [ ${#missing_circulars[@]} -gt 0 ]; then
      uds_log "Adding ${#missing_circulars[@]} plugins with unresolved circular dependencies at the end" "info"
      for plugin in "${missing_circulars[@]}"; do
        UDS_PLUGIN_EXECUTION_ORDER+=("$plugin")
      done
    fi
  fi
  
  # Return sorted list or empty string on complete failure
  if [ ${#UDS_PLUGIN_EXECUTION_ORDER[@]} -gt 0 ]; then
    local sorted_plugins=$(IFS=,; echo "${UDS_PLUGIN_EXECUTION_ORDER[*]}")
    echo "$sorted_plugins"
    return 0
  else
    # No plugins were successfully sorted
    uds_log "Failed to sort plugins due to severe dependency issues" "error"
    return 1
  fi
}

# Enhanced helper function for topological sort with better cycle handling
_uds_visit_plugin() {
  local plugin="$1"
  local -n _graph="$2"
  local -n _visited="$3"
  local -n _temp="$4"
  
  # Skip plugins with known circular dependencies
  if [ -n "${UDS_CIRCULAR_DEPENDENCY_DETAIL[$plugin]:-}" ]; then
    # Mark as visited to prevent revisiting
    _visited["$plugin"]=1
    return 0
  fi
  
  # Check for circular dependency
  if [ "${_temp[$plugin]:-0}" -eq 1 ]; then
    # We've detected a cycle - but details should already be in UDS_CIRCULAR_DEPENDENCY_DETAIL
    # from previous run of uds_plugin_has_circular_deps
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
      # Skip empty dependencies (can happen with trailing commas)
      if [ -z "$dep" ]; then
        continue
      fi
      
      # Extract dependency name (strip optional flag if present)
      local dep_name="${dep%%:*}"
      local is_optional=false
      if [[ "$dep" == *":optional"* ]]; then
        is_optional=true
      fi
      
      # Skip if dependency doesn't exist in graph
      if [ -z "${_graph[$dep_name]:-}" ]; then
        continue
      fi
      
      # If dependency has circular dependency and is optional, we can skip it
      if [ -n "${UDS_CIRCULAR_DEPENDENCY_DETAIL[$dep_name]:-}" ] && [ "$is_optional" = "true" ]; then
        uds_log "Skipping optional dependency $dep_name with circular dependency" "debug"
        continue
      fi
      
      # Visit recursively, handling error return
      if ! _uds_visit_plugin "$dep_name" _graph _visited _temp; then
        # Propagate cycle detection upward, but mark this plugin as having a circular dep first
        if [ -z "${UDS_CIRCULAR_DEPENDENCY_DETAIL[$plugin]:-}" ]; then
          # This is a fallback if we somehow detect a cycle here that wasn't caught earlier
          UDS_CIRCULAR_DEPENDENCY_DETAIL["$plugin"]="Circular dependency involving $plugin and $dep_name"
        fi
        
        # Remove temporary mark
        _temp["$plugin"]=0
        return 1
      fi
    done
  fi
  
  # Mark as visited
  _visited["$plugin"]=1
  _temp["$plugin"]=0
  
  # Add to sorted list (in reverse order)
  UDS_PLUGIN_EXECUTION_ORDER=("$plugin" "${UDS_PLUGIN_EXECUTION_ORDER[@]}")
  
  return 0
}

# Enhanced execute hook function with retry and better error reporting
uds_execute_hook() {
  local hook_name="$1"
  shift
  local max_attempts="${UDS_HOOK_MAX_ATTEMPTS:-1}"  # Default to 1 attempt unless configured
  local hook_key="${hook_name}"
  
  if [ -z "${UDS_PLUGIN_HOOKS[$hook_key]:-}" ]; then
    uds_log "No hooks registered for: $hook_name" "debug"
    return 0
  fi
  
  uds_log "Executing hook: $hook_name" "debug"
  
  # Get all registered hook functions
  local all_hook_functions=()
  IFS=',' read -ra HOOK_FUNCTIONS <<< "${UDS_PLUGIN_HOOKS[$hook_key]}"
  
  # Map hook functions to their plugins for dependency-ordered execution
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
  local sorted_success=false
  
  if [ -n "$plugins_with_hooks" ]; then
    sorted_plugins=$(uds_sort_plugins "$plugins_with_hooks")
    if [ -n "$sorted_plugins" ]; then
      sorted_success=true
    fi
  fi
  
  # Track execution results
  local hook_errors=0
  local executed_hooks=0
  local success_hooks=0
  
  if [ "$sorted_success" = "true" ]; then
    uds_log "Executing hook $hook_name in dependency order: $sorted_plugins" "debug"
    
    # Execute hooks in dependency order
    IFS=',' read -ra SORTED_PLUGINS <<< "$sorted_plugins"
    for plugin in "${SORTED_PLUGINS[@]}"; do
      for hook_function in "${HOOK_FUNCTIONS[@]}"; do
        if [ "${hook_plugin_map[$hook_function]}" = "$plugin" ]; then
          executed_hooks=$((executed_hooks + 1))
          uds_log "Executing hook function: $hook_function" "debug"
          
          # Execute with retry logic if configured
          local attempt=1
          local success=false
          
          while [ $attempt -le "$max_attempts" ]; do
            # Only show retry message after first attempt
            if [ $attempt -gt 1 ]; then
              uds_log "Retry $attempt/$max_attempts for hook function: $hook_function" "info"
            fi
            
            # Execute hook with improved error handling
            if "$hook_function" "$@"; then
              success=true
              success_hooks=$((success_hooks + 1))
              break
            else
              local exit_code=$?
              
              if [ $attempt -lt "$max_attempts" ]; then
                uds_log "Hook function failed with exit code $exit_code, will retry" "warning"
                # Log specific error if available
                if [ -n "${FUNCNAME[0]:-}" ]; then
                  uds_log "Function call: ${FUNCNAME[0]}:$LINENO in ${BASH_SOURCE[1]:-unknown}" "debug"
                fi
                sleep 1  # Brief delay before retry
              else
                uds_log "Hook function $hook_function failed after $max_attempts attempts with exit code $exit_code" "error"
                hook_errors=$((hook_errors + 1))
              fi
            fi
            
            attempt=$((attempt + 1))
          done
        fi
      done
    done
  else
    # Fallback to unsorted execution if dependency resolution failed
    uds_log "Plugin dependency resolution failed, executing hooks in registration order" "warning"
    
    for hook_function in "${HOOK_FUNCTIONS[@]}"; do
      executed_hooks=$((executed_hooks + 1))
      uds_log "Executing hook function: $hook_function" "debug"
      
      # Execute with retry logic if configured
      local attempt=1
      local success=false
      
      while [ $attempt -le "$max_attempts" ]; do
        # Only show retry message after first attempt
        if [ $attempt -gt 1 ]; then
          uds_log "Retry $attempt/$max_attempts for hook function: $hook_function" "info"
        fi
        
        # Execute hook with improved error handling
        if "$hook_function" "$@"; then
          success=true
          success_hooks=$((success_hooks + 1))
          break
        else
          local exit_code=$?
          
          if [ $attempt -lt "$max_attempts" ]; then
            uds_log "Hook function failed with exit code $exit_code, will retry" "warning"
            # Log more detailed error information
            uds_log "Failed function: $hook_function, arguments: $*" "debug"
            sleep 1  # Brief delay before retry
          else
            uds_log "Hook function $hook_function failed after $max_attempts attempts with exit code $exit_code" "error"
            hook_errors=$((hook_errors + 1))
          fi
        fi
        
        attempt=$((attempt + 1))
      done
    done
  fi
  
  # Log execution summary
  if [ $hook_errors -gt 0 ]; then
    uds_log "Hook '$hook_name' completed with $hook_errors errors ($success_hooks/$executed_hooks successful)" "warning"
  else
    uds_log "Hook '$hook_name' completed successfully ($executed_hooks hooks executed)" "debug"
  fi
  
  # Return failure if any hooks failed
  if [ $hook_errors -gt 0 ]; then
    return 1
  fi
  
  return 0
}

# Get the names of all registered plugins
# shellcheck disable=SC2120
uds_list_plugins() {
  local include_details="${1:-false}"
  
  if [ "$include_details" = "true" ]; then
    # Return detailed information as JSON
    local json_output="{"
    local first=true
    
    for plugin in "${!UDS_PLUGIN_REGISTRY[@]}"; do
      # Add comma separator if not first item
      if [ "$first" = "true" ]; then
        first=false
      else
        json_output="${json_output},"
      fi
      
      # Get plugin details
      local deps="${UDS_PLUGIN_DEPENDENCIES[$plugin]:-}"
      local has_circular=$([ -n "${UDS_CIRCULAR_DEPENDENCY_DETAIL[$plugin]:-}" ] && echo "true" || echo "false")
      
      # Add plugin entry
      json_output="${json_output}\"${plugin}\": {\"dependencies\": \"${deps}\", \"has_circular_dependency\": ${has_circular}}"
    done
    
    json_output="${json_output}}"
    echo "$json_output"
  else
    # Return simple list of plugin names
    for plugin in "${!UDS_PLUGIN_REGISTRY[@]}"; do
      echo "$plugin"
    done
  fi
}

# Visualize plugin dependencies as an ASCII tree
uds_visualize_plugin_deps() {
  local start_plugin="$1"  # Optional starting plugin
  
  # If no plugin specified, visualize all plugins
  if [ -z "$start_plugin" ]; then
    echo "Plugin Dependency Graph"
    echo "======================="
    
    # Get all plugins in sorted order if possible
    local all_plugins=$(uds_list_plugins | tr '\n' ',' | sed 's/,$//')
    local sorted_plugins=$(uds_sort_plugins "$all_plugins" 2>/dev/null || echo "$all_plugins")
    
    IFS=',' read -ra PLUGIN_ARRAY <<< "$sorted_plugins"
    for plugin in "${PLUGIN_ARRAY[@]}"; do
      echo ""
      _uds_visualize_plugin_tree "$plugin" "" "" 0
    done
  else
    echo "Dependency Tree for Plugin: $start_plugin"
    echo "==============================================="
    _uds_visualize_plugin_tree "$start_plugin" "" "" 0
  fi
}

# Helper function to visualize plugin dependency tree
_uds_visualize_plugin_tree() {
  local plugin="$1"
  local prefix="$2"
  local visited_path="$3"  # Comma-separated path of visited plugins
  local depth="$4"
  
  # Skip if too deep to prevent huge output
  if [ "$depth" -gt 10 ]; then
    echo "${prefix}└── ..."
    return
  fi
  
  # Check if this plugin is registered
  local status=""
  if [ -z "${UDS_PLUGIN_REGISTRY[$plugin]:-}" ]; then
    status=" [MISSING]"
  fi
  
  # Check if this plugin has circular dependencies
  if [ -n "${UDS_CIRCULAR_DEPENDENCY_DETAIL[$plugin]:-}" ]; then
    status="${status} [CIRCULAR]"
  fi
  
  # Check if already visited in current path (indicates cycle)
  if [[ "$visited_path" == *",${plugin},"* ]]; then
    echo "${prefix}└── ${plugin}${status} [CYCLE]"
    return
  fi
  
  # Display plugin
  echo "${prefix}└── ${plugin}${status}"
  
  # Update visited path for cycle detection
  visited_path="${visited_path},${plugin},"
  
  # Get dependencies
  local deps="${UDS_PLUGIN_DEPENDENCIES[$plugin]:-}"
  if [ -n "$deps" ]; then
    IFS=',' read -ra DEPS_ARRAY <<< "$deps"
    local i=0
    local count=${#DEPS_ARRAY[@]}
    
    for dep in "${DEPS_ARRAY[@]}"; do
      i=$((i+1))
      
      # Skip empty dependencies
      if [ -z "$dep" ]; then
        continue
      fi
      
      # Extract dependency name and optional flag
      local dep_name="${dep%%:*}"
      local is_optional=false
      if [[ "$dep" == *":optional"* ]]; then
        is_optional=true
      fi
      
      # Determine prefix for next level
      local next_prefix="${prefix}    "
      
      # Optional dependency indicator
      local opt_indicator=""
      if [ "$is_optional" = "true" ]; then
        opt_indicator=" [OPTIONAL]"
      fi
      
      # Recursively visualize dependency
      _uds_visualize_plugin_tree "${dep_name}" "${next_prefix}" "${visited_path}" $((depth+1))
    done
  fi
}

# Export module state and functions
export UDS_PLUGIN_LOADED
export -A UDS_PLUGIN_REGISTRY
export -A UDS_PLUGIN_ARGS
export -A UDS_PLUGIN_HOOKS
export -A UDS_PLUGIN_DEPENDENCIES
export -a UDS_PLUGIN_EXECUTION_ORDER
export -A UDS_CIRCULAR_DEPENDENCY_DETAIL

export -f uds_discover_plugins uds_activate_plugins uds_sort_plugins
export -f uds_register_plugin_arg uds_get_plugin_arg 
export -f uds_register_plugin_hook uds_list_hooks
export -f uds_register_plugin_dependency uds_get_dependencies
export -f uds_execute_hook uds_has_dependency
export -f uds_list_plugins uds_visualize_plugin_deps
export -f uds_verify_plugin_dependencies uds_plugin_has_circular_deps