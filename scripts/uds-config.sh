#!/bin/bash
# uds-config.sh - Configuration loading utilities for the UDS system

# Avoid loading multiple times
if [ -n "$UDS_CONFIG_LOADED" ]; then
  return 0
fi
UDS_CONFIG_LOADED=1

# Ensure jq is available for JSON parsing
require_jq() {
    if ! command -v jq >/dev/null 2>&1; then
        echo "Error: jq is required for JSON processing but not found in PATH" >&2
        echo "Please install jq using your package manager before continuing" >&2
        return 1
    fi
    return 0
}

# Load configuration from a JSON file
# Usage: load_config_file /path/to/config.json
load_config_file() {
    local config_file="$1"
    
    # Verify input
    if [ -z "$config_file" ]; then
        echo "Error: No configuration file specified" >&2
        return 1
    fi
    
    if [ ! -f "$config_file" ]; then
        echo "Error: Configuration file not found: $config_file" >&2
        return 1
    fi
    
    # Ensure jq is available - this is a hard requirement
    if ! require_jq; then
        return 1
    fi
    
    # Validate JSON syntax
    if ! jq empty "$config_file" 2>/dev/null; then
        echo "Error: Invalid JSON in configuration file: $config_file" >&2
        return 1
    fi
    
    return 0
}

# Get a string value from a JSON configuration file
# Usage: get_config_string /path/to/config.json '.path.to.value' 'default'
get_config_string() {
    local config_file="$1"
    local json_path="$2"
    local default_value="${3:-}"
    
    # Skip validation if we've already validated
    if [ "$UDS_CONFIG_VALIDATED" != "true" ]; then
        # Ensure configuration file is valid
        if ! load_config_file "$config_file" >/dev/null 2>&1; then
            echo "$default_value"
            return 1
        fi
    fi
    
    # Get value with jq
    local value=$(jq -r "$json_path // \"$default_value\"" "$config_file" 2>/dev/null)
    local ret=$?
    
    # Handle jq error or null/empty values
    if [ $ret -ne 0 ] || [ "$value" = "null" ] || [ -z "$value" ]; then
        echo "$default_value"
    else
        echo "$value"
    fi
    
    return 0
}

# Get a boolean value from a JSON configuration file
# Usage: get_config_boolean /path/to/config.json '.path.to.value' 'default'
get_config_boolean() {
    local config_file="$1"
    local json_path="$2"
    local default_value="${3:-false}"
    
    # Skip validation if we've already validated
    if [ "$UDS_CONFIG_VALIDATED" != "true" ]; then
        # Ensure configuration file is valid
        if ! load_config_file "$config_file" >/dev/null 2>&1; then
            echo "$default_value"
            return 1
        fi
    fi
    
    # Get value with jq and ensure it's a boolean
    local value=$(jq -r "$json_path // $default_value" "$config_file" 2>/dev/null)
    local ret=$?
    
    # Handle jq error
    if [ $ret -ne 0 ]; then
        echo "$default_value"
        return 0
    fi
    
    # Convert to lowercase for comparison
    value=$(echo "$value" | tr '[:upper:]' '[:lower:]')
    
    # Return standardized boolean value
    if [ "$value" = "true" ] || [ "$value" = "1" ] || [ "$value" = "yes" ]; then
        echo "true"
    else
        echo "false"
    fi
    
    return 0
}

# Get a numeric value from a JSON configuration file
# Usage: get_config_number /path/to/config.json '.path.to.value' 'default'
get_config_number() {
    local config_file="$1"
    local json_path="$2"
    local default_value="${3:-0}"
    
    # Skip validation if we've already validated
    if [ "$UDS_CONFIG_VALIDATED" != "true" ]; then
        # Ensure configuration file is valid
        if ! load_config_file "$config_file" >/dev/null 2>&1; then
            echo "$default_value"
            return 1
        fi
    fi
    
    # Get value with jq
    local value=$(jq -r "$json_path // $default_value" "$config_file" 2>/dev/null)
    local ret=$?
    
    # Handle jq error
    if [ $ret -ne 0 ]; then
        echo "$default_value"
        return 0
    fi
    
    # Check if numeric
    if [[ "$value" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        echo "$value"
    else
        echo "$default_value"
    fi
    
    return 0
}

# Get an array value from a JSON configuration file as a space-separated string
# Usage: get_config_array /path/to/config.json '.path.to.array' 'default'
get_config_array() {
    local config_file="$1"
    local json_path="$2"
    local default_value="${3:-}"
    
    # Skip validation if we've already validated
    if [ "$UDS_CONFIG_VALIDATED" != "true" ]; then
        # Ensure configuration file is valid
        if ! load_config_file "$config_file" >/dev/null 2>&1; then
            echo "$default_value"
            return 1
        fi
    fi
    
    # Get value with jq, converting array to space-separated string
    local value=$(jq -r "$json_path // [] | if type == \"array\" then .[] else . end" "$config_file" 2>/dev/null | tr '\n' ' ')
    local ret=$?
    
    # Handle jq error
    if [ $ret -ne 0 ]; then
        echo "$default_value"
        return 0
    fi
    
    # Check if empty
    if [ -z "$value" ] || [ "$value" = " " ]; then
        echo "$default_value"
    else
        echo "$value"
    fi
    
    return 0
}

# Get an object value from a JSON configuration file
# Usage: get_config_object /path/to/config.json '.path.to.object' '{}'
get_config_object() {
    local config_file="$1"
    local json_path="$2"
    local default_value="${3:-{}}"
    
    # Skip validation if we've already validated
    if [ "$UDS_CONFIG_VALIDATED" != "true" ]; then
        # Ensure configuration file is valid
        if ! load_config_file "$config_file" >/dev/null 2>&1; then
            echo "$default_value"
            return 1
        fi
    fi
    
    # Get value with jq, preserving JSON formatting
    local value=$(jq -c "$json_path // $default_value" "$config_file" 2>/dev/null)
    local ret=$?
    
    # Handle jq error
    if [ $ret -ne 0 ]; then
        echo "$default_value"
        return 0
    fi
    
    # Check if null
    if [ "$value" = "null" ]; then
        echo "$default_value"
    else
        echo "$value"
    fi
    
    return 0
}

# Centralized configuration loading function that all scripts can use
# Usage: uds_load_common_config /path/to/config.json
uds_load_common_config() {
    local config_file="$1"
    
    # Validate configuration file once
    if ! load_config_file "$config_file"; then
        [ -n "${UDS_LOG_LOADED:-}" ] && uds_log "Failed to load configuration from $config_file" "error"
        return 1
    fi
    
    # Mark as validated to avoid redundant checks
    export UDS_CONFIG_VALIDATED=true
    
    [ -n "${UDS_LOG_LOADED:-}" ] && uds_log "Loading configuration from $config_file" "info"
    
    # Load common configuration values
    APP_NAME=$(get_config_string "$config_file" '.app_name' "")
    COMMAND=$(get_config_string "$config_file" '.command' "deploy")
    # Variables below are used in external scripts like uds-deploy.sh and uds-rollback.sh
    # shellcheck disable=SC2034
    IMAGE=$(get_config_string "$config_file" '.image' "")
    # shellcheck disable=SC2034
    TAG=$(get_config_string "$config_file" '.tag' "latest")
    DOMAIN=$(get_config_string "$config_file" '.domain' "")
    ROUTE_TYPE=$(get_config_string "$config_file" '.route_type' "path")
    ROUTE=$(get_config_string "$config_file" '.route' "")
    PORT=$(get_config_string "$config_file" '.port' "3000")
    SSL=$(get_config_boolean "$config_file" '.ssl' "true")
    SSL_EMAIL=$(get_config_string "$config_file" '.ssl_email' "")
    ENV_VARS=$(get_config_string "$config_file" '.env_vars' "{}")
    VOLUMES=$(get_config_string "$config_file" '.volumes' "")
    PERSISTENT=$(get_config_boolean "$config_file" '.persistent' "false")
    COMPOSE_FILE=$(get_config_string "$config_file" '.compose_file' "")
    USE_PROFILES=$(get_config_boolean "$config_file" '.use_profiles' "true")
    MULTI_STAGE=$(get_config_boolean "$config_file" '.multi_stage' "false")
    CHECK_DEPENDENCIES=$(get_config_boolean "$config_file" '.check_dependencies' "false")
    HEALTH_CHECK=$(get_config_string "$config_file" '.health_check' "/health")
    HEALTH_CHECK_TYPE=$(get_config_string "$config_file" '.health_check_type' "auto")
    # This variable is used by health check functions in uds-health.sh and uds-dependency.sh
    # shellcheck disable=SC2034
    HEALTH_CHECK_TIMEOUT=$(get_config_number "$config_file" '.health_check_timeout' "60")
    # shellcheck disable=SC2034
    HEALTH_CHECK_COMMAND=$(get_config_string "$config_file" '.health_check_command' "")
    PORT_AUTO_ASSIGN=$(get_config_boolean "$config_file" '.port_auto_assign' "true")
    VERSION_TRACKING=$(get_config_boolean "$config_file" '.version_tracking' "true")
    PLUGINS=$(get_config_string "$config_file" '.plugins' "")
    
    # Set APP_DIR based on APP_NAME
    APP_DIR="${UDS_BASE_DIR}/${APP_NAME}"
    
    # Export all the variables
    export APP_NAME COMMAND IMAGE TAG DOMAIN ROUTE_TYPE ROUTE PORT SSL SSL_EMAIL 
    export ENV_VARS VOLUMES PERSISTENT COMPOSE_FILE USE_PROFILES MULTI_STAGE CHECK_DEPENDENCIES
    export HEALTH_CHECK HEALTH_CHECK_TYPE HEALTH_CHECK_TIMEOUT HEALTH_CHECK_COMMAND 
    export PORT_AUTO_ASSIGN VERSION_TRACKING APP_DIR PLUGINS
    
    return 0
}

# Standard function for all scripts to load config and initialize plugins
# Usage: uds_init_config /path/to/config.json
uds_init_config() {
    local config_file="$1"
    
    # Use centralized config loading utility
    if ! uds_load_common_config "$config_file"; then
        return 1
    fi

    # Log configuration loading if logging module is available
    [ -n "${UDS_LOG_LOADED:-}" ] && uds_log "Configuration loaded successfully" "debug"
    
    # Check if plugin module is available
    if type uds_discover_plugins >/dev/null 2>&1; then
        # Load and discover plugins
        uds_discover_plugins
        
        # Activate configured plugins
        if [ -n "$PLUGINS" ]; then
            [ -n "${UDS_LOG_LOADED:-}" ] && uds_log "Activating plugins: $PLUGINS" "debug"
            uds_activate_plugins "$PLUGINS"
        fi
        
        # Execute hook if hook system is available
        if type uds_execute_hook >/dev/null 2>&1; then
            uds_execute_hook "config_loaded" "$APP_NAME"
        fi
    else
        [ -n "${UDS_LOG_LOADED:-}" ] && uds_log "Plugin system not available, skipping plugin activation" "debug"
    fi
    
    return 0
}

# Export functions and state
export UDS_CONFIG_LOADED
export -f require_jq load_config_file uds_load_common_config uds_init_config
export -f get_config_string get_config_boolean get_config_number
export -f get_config_array get_config_object