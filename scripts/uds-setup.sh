#!/bin/bash
#
# uds-setup.sh - Setup script for Unified Deployment System
#
# This script handles initial setup of the deployment environment

set -eo pipefail

# Define UDS base directory (updated for consistent variable naming)
UDS_BASE_DIR="${UDS_BASE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"

# Function to install UDS if not already installed
# This is the single source of truth for UDS installation
setup_uds() {
  local uds_repo="${UDS_REPO:-https://github.com/elijahmont3x/unified-deployment-action.git}"
  local uds_version="${UDS_VERSION:-v1}" # Replace with the desired tag or commit hash
  local target_dir="${1:-$UDS_BASE_DIR}"

  # Create target directory if it doesn't exist
  mkdir -p "$target_dir"

  if [ ! -f "$target_dir/uds-core.sh" ]; then
    echo "Installing Unified Deployment System..."

    # Create a temporary directory for cloning
    local temp_dir=$(mktemp -d)
    
    # Clone the repository with error handling
    if ! git clone --branch "$uds_version" "$uds_repo" "$temp_dir"; then
      echo "Failed to clone UDS repository from $uds_repo"
      rm -rf "$temp_dir"
      return 1
    fi

    # Copy the necessary files
    cp -r "$temp_dir/scripts/"* "$target_dir/"
    mkdir -p "$target_dir/plugins"
    cp -r "$temp_dir/plugins/"* "$target_dir/plugins/"

    # Clean up
    rm -rf "$temp_dir"

    # Make scripts executable
    chmod +x "$target_dir"/*.sh
    
    echo "UDS installed successfully to $target_dir"
    return 0
  else
    echo "UDS is already installed at $target_dir"
    return 0
  fi
}

# Load core module if available
if [ -f "$UDS_BASE_DIR/uds-core.sh" ]; then
  source "$UDS_BASE_DIR/uds-core.sh"
else
  # If core module is not available, install UDS first
  setup_uds "$UDS_BASE_DIR"
  source "$UDS_BASE_DIR/uds-core.sh"
fi

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
  --check-system           Perform system checks before setup
  --secure-mode            Enable enhanced security features
  --log-level=LEVEL        Set log level (debug, info, warning, error)
  --dry-run                Show what would be done without actually doing it
  --help                   Show this help message

EXAMPLES:
  # Set up the environment
  ./uds-setup.sh --config=my-app-config.json

  # Set up and install dependencies
  ./uds-setup.sh --config=my-app-config.json --install-deps

  # Set up with enhanced security
  ./uds-setup.sh --config=my-app-config.json --secure-mode
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
      --check-system)
        CHECK_SYSTEM=true
        shift
        ;;
      --secure-mode)
        SECURE_MODE=true
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

# Basic system requirement check (focused on setup concerns only)
uds_check_system() {
  uds_log "Checking basic system requirements..." "info"
  
  # Check disk space (essential for installation)
  local required_space=500 # 500MB minimum
  local available_space=$(df -m "${UDS_BASE_DIR}" | awk 'NR==2 {print $4}')
  
  if [ "${available_space}" -lt "${required_space}" ]; then
    uds_log "Insufficient disk space: ${available_space}MB available, ${required_space}MB required" "error"
    return 1
  fi
  
  # Only check if Docker daemon is responsive (essential)
  if ! docker info &> /dev/null; then
    uds_log "Docker is not running or not available" "error"
    return 1
  fi
  
  uds_log "Basic system requirements satisfied" "success"
  return 0
}

# Install system dependencies with enhanced checks
uds_install_dependencies() {
  uds_log "Installing system dependencies" "info"
  
  if [ "${DRY_RUN:-false}" = "true" ]; then
    uds_log "DRY RUN: Would install dependencies" "info"
    return 0
  fi

  # Check for essential commands
  local REQUIRED_COMMANDS=("curl" "jq" "openssl" "git")
  local MISSING_COMMANDS=()

  for cmd in "${REQUIRED_COMMANDS[@]}"; do
    if ! command -v "$cmd" &> /dev/null; then
      MISSING_COMMANDS+=("$cmd")
    fi
  done

  if [ ${#MISSING_COMMANDS[@]} -gt 0 ]; then
    uds_log "Missing required commands: ${MISSING_COMMANDS[*]}" "warning"
  
    # Detect package manager
    if command -v apt-get &> /dev/null; then
      # Debian/Ubuntu
      uds_log "Detected apt package manager" "info"
      apt-get update
      apt-get install -y curl jq openssl git nginx certbot python3-certbot-nginx
    elif command -v yum &> /dev/null; then
      # CentOS/RHEL
      uds_log "Detected yum package manager" "info"
      yum -y update
      yum -y install curl jq openssl git nginx certbot python3-certbot-nginx
    elif command -v dnf &> /dev/null; then
      # Fedora
      uds_log "Detected dnf package manager" "info"
      dnf -y update
      dnf -y install curl jq openssl git nginx certbot python3-certbot-nginx
    elif command -v apk &> /dev/null; then
      # Alpine
      uds_log "Detected apk package manager" "info"
      apk update
      apk add curl jq openssl git nginx certbot
    else
      uds_log "No supported package manager found. Please install dependencies manually." "warning"
      return 1
    fi
    
    # Verify installation
    local STILL_MISSING=()
    for cmd in "${MISSING_COMMANDS[@]}"; do
      if ! command -v "$cmd" &> /dev/null; then
        STILL_MISSING+=("$cmd")
      fi
    done
    
    if [ ${#STILL_MISSING[@]} -gt 0 ]; then
      uds_log "Failed to install: ${STILL_MISSING[*]}" "error"
      return 1
    fi
  fi
  
  # Check if Docker is installed
  if ! command -v docker &> /dev/null; then
    uds_log "Docker not installed. Installing..." "info"
    curl -fsSL https://get.docker.com | sh
    
    # Check Docker installation
    if ! command -v docker &> /dev/null; then
      uds_log "Failed to install Docker" "error"
      return 1
    fi
    
    # Start Docker service
    systemctl enable docker || service docker start || true
  fi
  
  # Check Docker is running
  if ! docker info &> /dev/null; then
    uds_log "Docker is not running, attempting to start..." "warning"
    systemctl start docker || service docker start || true
    
    # Check again
    if ! docker info &> /dev/null; then
      uds_log "Failed to start Docker" "error"
      return 1
    fi
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
    
    # Verify Docker Compose installation
    if ! $UDS_DOCKER_COMPOSE_CMD version &> /dev/null; then
      uds_log "Failed to install Docker Compose" "error"
      return 1
    fi
  fi
  
  # Add verification step for installed dependencies
  local VERIFY_COMMANDS=("docker" "curl" "jq" "openssl" "docker-compose" "git")
  local MISSING_AFTER=()
  
  for cmd in "${VERIFY_COMMANDS[@]}"; do
    # Special case for docker-compose (might be docker compose)
    if [ "$cmd" = "docker-compose" ]; then
      if ! $UDS_DOCKER_COMPOSE_CMD version &>/dev/null; then
        MISSING_AFTER+=("$cmd")
      fi
    elif ! command -v "$cmd" &>/dev/null; then
      MISSING_AFTER+=("$cmd")
    fi
  done
  
  if [ ${#MISSING_AFTER[@]} -gt 0 ]; then
    uds_log "Failed to install or verify: ${MISSING_AFTER[*]}" "warning"
    uds_log "You may need to install these manually to use all UDS features" "warning"
  else
    uds_log "All required dependencies installed successfully" "success"
  fi
  
  return 0
}

# Set up the system - modified to work with plugins
uds_setup_system() {
  uds_log "Setting up Unified Deployment System" "info"
  
  if [ "${DRY_RUN:-false}" = "true" ]; then
    uds_log "DRY RUN: Would set up the system" "info"
    return 0
  fi
  
  # Create required directories
  mkdir -p "${UDS_CONFIGS_DIR}" "${UDS_LOGS_DIR}" "${UDS_CERTS_DIR}" "${UDS_NGINX_DIR}" "${PERSISTENCE_DATA_DIR:-${UDS_BASE_DIR}/data}"
  
  # Apply basic security permissions
  chmod 700 "${UDS_CONFIGS_DIR}" "${UDS_LOGS_DIR}" "${UDS_CERTS_DIR}"
  chmod 755 "${UDS_NGINX_DIR}"
  
  # Execute pre-setup hooks - this will trigger plugin-specific setup 
  uds_execute_hook "pre_setup" "$APP_NAME"
  
  # Set up application directory if app name is provided
  if [ -n "${APP_NAME:-}" ]; then
    mkdir -p "$APP_DIR"
    chmod 755 "$APP_DIR"
  fi
  
  # Execute post-setup hooks
  uds_execute_hook "post_setup" "$APP_NAME" "$APP_DIR"
  
  uds_log "System setup completed successfully" "success"
  return 0
}

# Main setup function with improved flow
uds_do_setup() {
  # Parse command-line arguments
  uds_parse_args "$@"
  
  # Check system first if requested (before loading config)
  if [ "${CHECK_SYSTEM:-false}" = "true" ]; then
    uds_check_system || {
      uds_log "System check failed - please resolve issues before continuing" "error"
      return 1
    }
  fi
  
  # Load configuration (activates plugins)
  uds_load_config "$CONFIG_FILE"
  
  # Execute hook after configuration is loaded
  uds_execute_hook "config_loaded" "$APP_NAME"
  
  # Install dependencies if requested
  if [ "${INSTALL_DEPS:-false}" = "true" ]; then
    uds_install_dependencies || {
      uds_log "Failed to install dependencies" "error"
      return 1
    }
  fi
  
  # Set up the system
  uds_setup_system || {
    uds_log "System setup failed" "error"
    return 1
  }
  
  uds_log "UDS setup completed successfully!" "success"
  return 0
}

# Execute setup if being run directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  uds_do_setup "$@"
  exit $?
fi