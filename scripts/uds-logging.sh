#!/bin/bash
#
# uds-logging.sh - Logging functionality for Unified Deployment System
#
# This module provides functions for logging and output formatting

# Avoid loading multiple times
if [ -n "$UDS_LOGGING_LOADED" ]; then
  return 0
fi

# Load dependencies
if [ -z "$UDS_ENV_LOADED" ]; then
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/uds-env.sh"
fi

UDS_LOGGING_LOADED=1

# Color definitions for logs
declare -A UDS_LOG_COLORS=(
  ["debug"]="\033[0;37m"    # Gray
  ["info"]="\033[0;34m"     # Blue
  ["warning"]="\033[0;33m"  # Yellow
  ["error"]="\033[0;31m"    # Red
  ["critical"]="\033[1;31m" # Bold Red
  ["success"]="\033[0;32m"  # Green
)

# Reset color
UDS_COLOR_RESET="\033[0m"

# Check if security module is available for sanitization
_uds_has_security_module() {
  if [ -f "${UDS_BASE_DIR}/uds-security.sh" ]; then
    if [ -z "$UDS_SECURITY_LOADED" ]; then
      source "${UDS_BASE_DIR}/uds-security.sh"
    fi
    return 0
  fi
  return 1
}

# Log a message
uds_log() {
  local message="$1"
  local level="${2:-info}"
  local timestamp
  timestamp=$(date "${UDS_DATE_FORMAT}")
  local color="${UDS_LOG_COLORS[$level]:-${UDS_LOG_COLORS[info]}}"

  # Check if we should sanitize sensitive data
  local sanitized_message="$message"
  if _uds_has_security_module && type uds_sanitize_env_vars &>/dev/null; then
    sanitized_message=$(uds_sanitize_env_vars "$message")
  fi

  # Only log if the level is equal or higher than the current log level
  if [ "${UDS_LOG_LEVELS[$level]:-1}" -ge "${UDS_LOG_LEVELS[$UDS_LOG_LEVEL]:-1}" ]; then
    # Format and print log message
    echo -e "${timestamp} ${color}[${level^^}]${UDS_COLOR_RESET} ${sanitized_message}"

    # Write to log file if logs directory exists
    if [ -d "${UDS_LOGS_DIR}" ]; then
      echo "${timestamp} [${level^^}] ${sanitized_message}" >> "${UDS_LOGS_DIR}/uds.log"
    fi
  fi
}

# Create a log domain for structured logging
uds_create_log_domain() {
  local domain="$1"
  
  # Return a prefixed log function
  eval "uds_log_${domain}() {
    local message=\"\$1\"
    local level=\"\${2:-info}\"
    uds_log \"[$domain] \$message\" \"\$level\"
  }"
  
  export -f "uds_log_${domain}"
}

# Initialize a separate log file for a specific component
uds_init_component_log() {
  local component="$1"
  local log_file="${UDS_LOGS_DIR}/${component}.log"
  
  # Create log file if it doesn't exist
  touch "$log_file"
  
  # Return a component-specific log function
  eval "uds_log_${component}_file() {
    local message=\"\$1\"
    local level=\"\${2:-info}\"
    local timestamp=\$(date \"\${UDS_DATE_FORMAT}\")
    local sanitized_message=\"\$message\"
    
    if _uds_has_security_module && type uds_sanitize_env_vars &>/dev/null; then
      sanitized_message=\$(uds_sanitize_env_vars \"\$message\")
    fi
    
    # Always log to component file
    echo \"\${timestamp} [\${level^^}] \${sanitized_message}\" >> \"$log_file\"
    
    # Also log to main log based on level
    if [ \"\${UDS_LOG_LEVELS[\$level]:-1}\" -ge \"\${UDS_LOG_LEVELS[\$UDS_LOG_LEVEL]:-1}\" ]; then
      uds_log \"[$component] \$message\" \"\$level\"
    fi
  }"
  
  export -f "uds_log_${component}_file"
}

# Log a message with a progress indicator
uds_log_progress() {
  local message="$1"
  local current="$2"
  local total="$3"
  local level="${4:-info}"
  
  # Calculate percentage
  local percentage=0
  if [ "$total" -gt 0 ]; then
    percentage=$((current * 100 / total))
  fi
  
  # Format progress bar
  local bar_length=20
  local filled_length=$((bar_length * current / total))
  
  # Build the bar
  local bar="["
  for ((i=0; i<bar_length; i++)); do
    if [ "$i" -lt "$filled_length" ]; then
      bar+="="
    else
      bar+=" "
    fi
  done
  bar+="]"
  
  # Log the message with progress
  uds_log "${message} ${bar} ${percentage}%" "$level"
}

# Display a spinner for a running process
uds_spinner() {
  local pid=$1
  local delay=0.1
  local spinstr='|/-\'
  
  # Hide cursor
  tput civis
  
  # Show spinner while process is running
  while ps a | awk '{print $1}' | grep -q $pid; do
    local temp=${spinstr#?}
    printf " [%c]  " "$spinstr"
    local spinstr=$temp${spinstr%"$temp"}
    sleep $delay
    printf "\b\b\b\b\b\b"
  done
  
  # Show cursor
  tput cnorm
  printf "    \b\b\b\b"
}

# Format text with ANSI colors for terminal output
uds_format_text() {
  local text="$1"
  local format="$2"
  
  case "$format" in
    bold)
      echo -e "\033[1m${text}\033[0m"
      ;;
    underline)
      echo -e "\033[4m${text}\033[0m"
      ;;
    red)
      echo -e "\033[31m${text}\033[0m"
      ;;
    green)
      echo -e "\033[32m${text}\033[0m"
      ;;
    yellow)
      echo -e "\033[33m${text}\033[0m"
      ;;
    blue)
      echo -e "\033[34m${text}\033[0m"
      ;;
    purple)
      echo -e "\033[35m${text}\033[0m"
      ;;
    cyan)
      echo -e "\033[36m${text}\033[0m"
      ;;
    gray)
      echo -e "\033[37m${text}\033[0m"
      ;;
    *)
      echo "$text"
      ;;
  esac
}

# Export functions
export UDS_LOGGING_LOADED
export -A UDS_LOG_COLORS
export -f uds_log uds_create_log_domain uds_init_component_log
export -f uds_log_progress uds_spinner uds_format_text