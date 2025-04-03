#!/bin/bash
#
# uds-env.sh - Environment setup for Unified Deployment System
#
# This module defines core environment variables and basic utilities used by all other modules

# Set strict error handling
set -eo pipefail

# Avoid loading multiple times
if [ -n "$UDS_ENV_LOADED" ]; then
  return 0
fi
UDS_ENV_LOADED=1

# Determine base directory - works even if this script is sourced from different locations
if [ -z "${UDS_BASE_DIR:-}" ]; then
  UDS_BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

# Core system constants
UDS_VERSION="1.1.0"
UDS_PLUGINS_DIR="${UDS_BASE_DIR}/plugins"
UDS_CONFIGS_DIR="${UDS_BASE_DIR}/configs"
UDS_LOGS_DIR="${UDS_BASE_DIR}/logs"
UDS_CERTS_DIR="${UDS_BASE_DIR}/certs"
UDS_NGINX_DIR="${UDS_BASE_DIR}/nginx"
UDS_REGISTRY_FILE="${UDS_BASE_DIR}/service-registry.json"

# Core environmental variables
UDS_TIME_ZONE="${TZ:-UTC}"
UDS_DATE_FORMAT="+%Y-%m-%d %H:%M:%S"
UDS_DOCKER_COMPOSE_CMD=$(command -v docker-compose || echo "docker compose")

# Log levels
declare -A UDS_LOG_LEVELS=(
  ["debug"]=0
  ["info"]=1
  ["warning"]=2
  ["error"]=3
  ["critical"]=4
  ["success"]=5
)

# Current log level
UDS_LOG_LEVEL="${UDS_LOG_LEVEL:-info}"

# Create required directories
mkdir -p "${UDS_CONFIGS_DIR}" "${UDS_LOGS_DIR}" "${UDS_CERTS_DIR}" "${UDS_NGINX_DIR}"

# Ensure registry file exists
if [ ! -f "${UDS_REGISTRY_FILE}" ]; then
  echo '{"services":{}}' > "${UDS_REGISTRY_FILE}"
  chmod 600 "${UDS_REGISTRY_FILE}"
fi

# Helper function to load other modules
uds_load_module() {
  local module="$1"
  local module_path="${UDS_BASE_DIR}/${module}"
  
  if [ -f "$module_path" ]; then
    source "$module_path"
    return 0
  else
    echo "ERROR: Failed to load module: $module_path not found"
    return 1
  fi
}

# Utility function for checking requirements
uds_check_requirements() {
  local requirements=("$@")
  local missing=()
  
  for cmd in "${requirements[@]}"; do
    if ! command -v "$cmd" &>/dev/null; then
      missing+=("$cmd")
    fi
  done
  
  if [ ${#missing[@]} -gt 0 ]; then
    echo "Missing required tools: ${missing[*]}"
    return 1
  fi
  
  return 0
}

# Export environment variables for use by other modules
export UDS_ENV_LOADED UDS_BASE_DIR UDS_VERSION UDS_PLUGINS_DIR UDS_CONFIGS_DIR
export UDS_LOGS_DIR UDS_CERTS_DIR UDS_NGINX_DIR UDS_REGISTRY_FILE
export UDS_TIME_ZONE UDS_DATE_FORMAT UDS_DOCKER_COMPOSE_CMD
export UDS_LOG_LEVEL
export -A UDS_LOG_LEVELS

# Export functions
export -f uds_load_module uds_check_requirements