#!/bin/bash
# uds-utils.sh - Common utility functions for the UDS system

# Exit on error by default (can be disabled)
set -e

# Default error level for logging
UDS_ERROR_LEVEL=${UDS_ERROR_LEVEL:-"ERROR"}

# Enable/disable exit on error
UDS_EXIT_ON_ERROR=${UDS_EXIT_ON_ERROR:-1}

# Set default exit code
UDS_DEFAULT_ERROR_EXIT_CODE=${UDS_DEFAULT_ERROR_EXIT_CODE:-1}

# Verify if a directory exists and is writable
# Usage: is_dir_writable /path/to/dir
is_dir_writable() {
    local dir="$1"
    
    if [ ! -d "$dir" ]; then
        return 1
    fi
    
    if [ ! -w "$dir" ]; then
        return 1
    fi
    
    return 0
}

# Create a directory if it doesn't exist
# Usage: ensure_dir /path/to/dir
ensure_dir() {
    local dir="$1"
    
    if [ ! -d "$dir" ]; then
        mkdir -p "$dir" || return 1
    fi
    
    return 0
}

# Check if a command exists
# Usage: command_exists git
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Join array elements with a delimiter
# Usage: join_by , "${array[@]}"
join_by() {
    local delimiter="$1"
    shift
    local first="$1"
    shift
    printf "%s" "$first" "${@/#/$delimiter}"
}

# Trim whitespace from a string
# Usage: trimmed=$(trim "  string with spaces  ")
trim() {
    local var="$*"
    # Remove leading whitespace
    var="${var#"${var%%[![:space:]]*}"}"
    # Remove trailing whitespace
    var="${var%"${var##*[![:space:]]}"}"
    echo "$var"
}

# Get the absolute path of a file
# Usage: abs_path=$(get_abs_path "./relative/path")
get_abs_path() {
    local path="$1"
    local dir
    
    # Handle empty input
    if [ -z "$path" ]; then
        return 1
    fi
    
    # If it's already absolute, just normalize it
    if [[ "$path" = /* ]]; then
        dir=$(cd "$(dirname "$path")" && pwd -P 2>/dev/null)
        if [ $? -ne 0 ]; then
            return 1
        fi
        echo "${dir}/$(basename "$path")"
        return 0
    fi
    
    # Convert relative to absolute
    dir=$(cd "$(dirname "$path")" && pwd -P 2>/dev/null)
    if [ $? -ne 0 ]; then
        return 1
    fi
    echo "${dir}/$(basename "$path")"
    return 0
}

# Check if a string contains another string
# Usage: if string_contains "$haystack" "$needle"; then
string_contains() {
    local haystack="$1"
    local needle="$2"
    
    [[ "$haystack" == *"$needle"* ]]
    return $?
}

# Generate a random string of specified length
# Usage: random_str=$(random_string 16)
random_string() {
    local length="${1:-32}"
    LC_ALL=C tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c "$length"
}

# Get timestamp in ISO 8601 format
# Usage: timestamp=$(get_timestamp)
get_timestamp() {
    date -u +"%Y-%m-%dT%H:%M:%SZ"
}

# Log an error message and optionally exit
# Usage: log_error "Something went wrong" [exit_code]
log_error() {
    local message="$1"
    local exit_code="${2:-$UDS_DEFAULT_ERROR_EXIT_CODE}"
    
    echo "[${UDS_ERROR_LEVEL}] $(get_timestamp) - $message" >&2
    
    if [ "$UDS_EXIT_ON_ERROR" -eq 1 ]; then
        exit "$exit_code"
    fi
    
    return "$exit_code"
}

# Log a warning message (does not exit)
# Usage: log_warning "This is a warning"
log_warning() {
    local message="$1"
    local prev_level="$UDS_ERROR_LEVEL"
    
    UDS_ERROR_LEVEL="WARNING"
    UDS_EXIT_ON_ERROR=0
    
    log_error "$message" 0
    
    # Restore previous settings
    UDS_ERROR_LEVEL="$prev_level"
    UDS_EXIT_ON_ERROR=1
    
    return 0
}

# Log an informational message (verbose mode only)
# Usage: log_info "Processing file..."
log_info() {
    local message="$1"
    
    # Only show info messages in verbose mode
    if [ "${VERBOSE:-0}" -eq 1 ]; then
        echo "[INFO] $(get_timestamp) - $message"
    fi
    
    return 0
}

# Log a debug message (verbose debug mode only)
# Usage: log_debug "Variable value: $var"
log_debug() {
    local message="$1"
    
    # Only show debug messages in verbose debug mode
    if [ "${VERBOSE:-0}" -eq 1 ] && [ "${DEBUG:-0}" -eq 1 ]; then
        echo "[DEBUG] $(get_timestamp) - $message"
    fi
    
    return 0
}

# Assert that a condition is true, log error and exit if not
# Usage: assert_true "$count -gt 0" "Count must be greater than zero"
assert_true() {
    local condition="$1"
    local message="$2"
    local exit_code="${3:-$UDS_DEFAULT_ERROR_EXIT_CODE}"
    
    if ! eval "[ $condition ]"; then
        log_error "Assertion failed [$condition]: $message" "$exit_code"
        return "$exit_code"
    fi
    
    return 0
}

# Set up error handling for the script
# Usage: setup_error_handling
setup_error_handling() {
    # Exit on error
    set -e
    
    # Exit on unset variables
    set -u
    
    # Fail if any command in a pipe fails
    set -o pipefail
    
    # Trap errors
    trap 'log_error "Command failed with exit code $? at line $LINENO"' ERR
}