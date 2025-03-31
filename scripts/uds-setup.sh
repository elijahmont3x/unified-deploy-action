#!/bin/bash
#
# uds-setup.sh - Setup script for Unified Deployment System
#
# This script handles initial setup of the deployment environment

set -eo pipefail

# Get script directory and load core module
UDS_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$UDS_SCRIPT_DIR/uds-core.sh"

# Ensure UDS is installed
setup_uds() {
  local uds_repo="https://github.com/your-org/unified-deployment-system.git"
  local uds_version="v1.0.0" # Replace with the desired tag or commit hash

  if [ ! -f "./uds-core.sh" ]; then
    uds_log "Installing Unified Deployment System..." "info"

    # Clone the repository
    git clone --branch "$uds_version" "$uds_repo" ./uds-temp

    # Copy the necessary files
    cp -r ./uds-temp/scripts/* ./
    cp -r ./uds-temp/plugins ./

    # Clean up
    rm -rf ./uds-temp

    # Make scripts executable
    chmod +x ./*.sh
    
    uds_log "UDS installed successfully" "success"
  fi
}

# Call the setup function
setup_uds

# Display help information
uds_show_help() {
  cat << EOL
=================================================================
Unified Deployment System - Setup Script
=================================================================

USAGE:
  ./uds-setup.sh [OPTIONS]

REQUIRED OPTIONS:
  --config=FILE            Path to configuration JSON file

ADDITIONAL OPTIONS:
  --install-deps           Install system dependencies
  --log-level=LEVEL        Set log level (debug, info, warning, error)
  --dry-run                Show what would be done without actually doing it
  --help                   Show this help message

EXAMPLES:
  # Set up the environment
  ./uds-setup.sh --config=my-app-config.json

  # Set up and install dependencies
  ./uds-setup.sh --config=my-app-config.json --install-deps

=================================================================
EOL
}

# Parse command-line arguments
uds_parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --config=*)
        CONFIG_FILE="${1#*=}"
        shift
        ;;
      --install-deps)
        INSTALL_DEPS=true
        shift
        ;;
      --log-level=*)
        UDS_LOG_LEVEL="${1#*=}"
        shift
        ;;
      --dry-run)
        DRY_RUN=true
        shift
        ;;
      --help)
        uds_show_help
        exit 0
        ;;
      *)
        uds_log "Unknown option: $1" "error"
        uds_show_help
        exit 1
        ;;
    esac
  done

  # Validate required parameters
  if [ -z "${CONFIG_FILE:-}" ]; then
    uds_log "Missing required parameter: --config" "error"
    uds_show_help
    exit 1
  fi
}

# Install system dependencies
uds_install_dependencies() {
  uds_log "Installing system dependencies" "info"
  
  if [ "${DRY_RUN:-false}" = "true" ]; then
    uds_log "DRY RUN: Would install dependencies" "info"
    return 0
  fi
  
  # Detect package manager
  if command -v apt-get &> /dev/null; then
    # Debian/Ubuntu
    uds_log "Detected apt package manager" "info"
    apt-get update
    apt-get install -y curl jq openssl nginx certbot python3-certbot-nginx
  elif command -v yum &> /dev/null; then
    # CentOS/RHEL
    uds_log "Detected yum package manager" "info"
    yum -y update
    yum -y install curl jq openssl nginx certbot python3-certbot-nginx
  elif command -v dnf &> /dev/null; then
    # Fedora
    uds_log "Detected dnf package manager" "info"
    dnf -y update
    dnf -y install curl jq openssl nginx certbot python3-certbot-nginx
  elif command -v apk &> /dev/null; then
    # Alpine
    uds_log "Detected apk package manager" "info"
    apk update
    apk add curl jq openssl nginx certbot
  else
    uds_log "No supported package manager found. Please install dependencies manually." "warning"
    return 1
  fi
  
  # Check if Docker is installed
  if ! command -v docker &> /dev/null; then
    uds_log "Docker not installed. Installing..." "info"
    curl -fsSL https://get.docker.com | sh
  fi
  
  # Check if Docker Compose is installed
  if ! command -v docker-compose &> /dev/null && ! docker compose version &> /dev/null; then
    uds_log "Docker Compose not installed. Installing..." "info"
    
    # Install Docker Compose plugin or standalone based on Docker version
    if docker --version | grep -q "20\.[1-9][0-9]"; then
      # Docker 20.10+, use plugin
      if command -v apt-get &> /dev/null; then
        apt-get install -y docker-compose-plugin
      else
        mkdir -p ~/.docker/cli-plugins/
        curl -SL https://github.com/docker/compose/releases/download/v2.12.2/docker-compose-linux-x86_64 -o ~/.docker/cli-plugins/docker-compose
        chmod +x ~/.docker/cli-plugins/docker-compose
      fi
    else
      # Older Docker, use standalone
      curl -L "https://github.com/docker/compose/releases/download/v2.12.2/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
      chmod +x /usr/local/bin/docker-compose
    fi
  fi
  
  uds_log "Dependencies installed successfully" "success"
  return 0
}

# Set up the system
uds_setup_system() {
  uds_log "Setting up Unified Deployment System" "info"
  
  if [ "${DRY_RUN:-false}" = "true" ]; then
    uds_log "DRY RUN: Would set up the system" "info"
    return 0
  fi
  
  # Create required directories
  mkdir -p "${UDS_NGINX_DIR}" "${UDS_CERTS_DIR}" "${UDS_LOGS_DIR}" "${PERSISTENCE_DATA_DIR:-${UDS_BASE_DIR}/data}"
  
  # Execute pre-setup hooks
  uds_execute_hook "pre_setup" "$APP_NAME"
  
  # Set up Nginx
  if type "plugin_route_setup_nginx_container" &>/dev/null; then
    uds_log "Setting up Nginx proxy container" "info"
    plugin_route_setup_nginx_container
  fi
  
  # Set up SSL if enabled
  if [ "$SSL" = "true" ] && [ -n "$SSL_EMAIL" ]; then
    if type "plugin_ssl_setup_auto_renewal" &>/dev/null; then
      uds_log "Setting up SSL auto-renewal" "info"
      plugin_ssl_setup_auto_renewal
    fi
  fi
  
  # Set up application directory
  mkdir -p "$APP_DIR"
  
  # Execute post-setup hooks
  uds_execute_hook "post_setup" "$APP_NAME" "$APP_DIR"
  
  uds_log "System setup completed successfully" "success"
  return 0
}

# Main setup function
uds_do_setup() {
  # Parse command-line arguments
  uds_parse_args "$@"
  
  # Load configuration
  uds_load_config "$CONFIG_FILE"
  
  # Install dependencies if requested
  if [ "${INSTALL_DEPS:-false}" = "true" ]; then
    uds_install_dependencies
  fi
  
  # Set up the system
  uds_setup_system
  
  return $?
}

# Execute setup if being run directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  uds_do_setup "$@"
  exit $?
fi