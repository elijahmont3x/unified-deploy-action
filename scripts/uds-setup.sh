#!/bin/bash
#
# uds-setup.sh - Setup script for Unified Deployment System
#
# This script handles initial setup of the deployment environment

set -eo pipefail

# Define UDS base directory
UDS_BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Function to install UDS if not already installed
setup_uds() {
  local uds_repo="${UDS_REPO:-https://github.com/elijahmont3x/unified-deploy-action.git}"
  local uds_version="${UDS_VERSION:-master}"
  local target_dir="${1:-$UDS_BASE_DIR}"

  # Create target directory if it doesn't exist
  mkdir -p "$target_dir"

  if [ ! -f "$target_dir/scripts/uds-env.sh" ]; then  # Changed path to look for uds-env.sh instead of uds-core.sh
    echo "Installing Unified Deployment System..."

    # Create a temporary directory for cloning
    local temp_dir=$(mktemp -d)
    
    # Attempt to clone the repository
    if [ -n "${GIT_TOKEN:-}" ]; then
      # Use token if provided
      local auth_repo="https://${GIT_TOKEN}@github.com/elijahmont3x/unified-deploy-action.git"
      if ! git clone --branch "$uds_version" "$auth_repo" "$temp_dir" 2>/dev/null; then
        echo "Failed to clone UDS repository with token. Falling back to public URL."
        if ! git clone --branch "$uds_version" "$uds_repo" "$temp_dir"; then
          echo "Failed to clone UDS repository"
          rm -rf "$temp_dir"
          return 1
        fi
      fi
    else
      # Try public URL
      if ! git clone --branch "$uds_version" "$uds_repo" "$temp_dir"; then
        echo "Failed to clone UDS repository"
        rm -rf "$temp_dir"
        return 1
      fi
    fi

    # Copy the necessary files
    mkdir -p "$target_dir/scripts" "$target_dir/plugins"
    
    # Check if specific directories exist and copy content
    if [ -d "$temp_dir/scripts" ]; then
      cp -r "$temp_dir/scripts/"* "$target_dir/scripts/" 2>/dev/null || true
    fi
    
    if [ -d "$temp_dir/plugins" ]; then
      cp -r "$temp_dir/plugins/"* "$target_dir/plugins/" 2>/dev/null || true
    fi

    # Make scripts executable
    find "$target_dir" -name "*.sh" -exec chmod +x {} \; 2>/dev/null || true

    # Clean up
    rm -rf "$temp_dir"
    
    echo "UDS installed successfully to $target_dir"
    return 0
  else
    echo "UDS is already installed at $target_dir"
    return 0
  fi
}

# Load essential modules if available, otherwise install them first
if [ -f "$UDS_BASE_DIR/scripts/uds-env.sh" ]; then
  source "$UDS_BASE_DIR/scripts/uds-env.sh"
  source "$UDS_BASE_DIR/scripts/uds-logging.sh"
  source "$UDS_BASE_DIR/scripts/uds-security.sh"
else
  # If modules are not available, install UDS first
  setup_uds "$UDS_BASE_DIR"
  
  # Try loading again after installation
  if [ -f "$UDS_BASE_DIR/scripts/uds-env.sh" ]; then
    source "$UDS_BASE_DIR/scripts/uds-env.sh"
    source "$UDS_BASE_DIR/scripts/uds-logging.sh"
    source "$UDS_BASE_DIR/scripts/uds-security.sh"
  else
    echo "ERROR: Failed to load or install UDS essential modules"
    exit 1
  fi
fi

# Load additional required modules
uds_load_module "uds-plugin.sh"       # For plugin functionality
uds_load_module "uds-docker.sh"       # For Docker operations
uds_load_module "uds-service.sh"      # For service registry

# Log execution start
uds_log "Loading UDS setup modules..." "debug"

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
  --uds-repo=URL           URL to UDS repository
  --uds-version=VERSION    Version or branch to use
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
  # Initialize variables with defaults
  INSTALL_DEPS=false
  CHECK_SYSTEM=false
  SECURE_MODE=false
  DRY_RUN=false
  CONFIG_FILE=""
  
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
      --uds-repo=*)
        UDS_REPO="${1#*=}"
        shift
        ;;
      --uds-version=*)
        UDS_VERSION="${1#*=}"
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
  if [ -z "${CONFIG_FILE}" ]; then
    uds_log "Missing required parameter: --config" "error"
    uds_show_help
    exit 1
  fi
  
  # Validate config file exists
  if [ ! -f "${CONFIG_FILE}" ]; then
    uds_log "Configuration file not found: ${CONFIG_FILE}" "error"
    exit 1
  fi
  
  # Export variables for use in other functions
  export INSTALL_DEPS CHECK_SYSTEM SECURE_MODE DRY_RUN UDS_REPO UDS_VERSION CONFIG_FILE
}

# Load configuration from a JSON file
uds_load_config() {
  local config_file="$1"
  
  # Use centralized config loading utility
  if ! uds_init_config "$config_file"; then
    uds_log "Failed to load configuration from $config_file" "error"
    return 1
  fi
  
  return 0
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
  
  # Check for essential commands
  local required_cmds=("curl" "mkdir" "chmod")
  local missing_cmds=()
  
  for cmd in "${required_cmds[@]}"; do
    if ! command -v "$cmd" &>/dev/null; then
      missing_cmds+=("$cmd")
    fi
  done
  
  if [ ${#missing_cmds[@]} -gt 0 ]; then
    uds_log "Missing essential commands: ${missing_cmds[*]}" "error"
    return 1
  fi
  
  # Only check if Docker daemon is responsive (essential)
  if ! docker info &>/dev/null; then
    uds_log "Docker is not running or not available" "warning"
    if [ "${INSTALL_DEPS}" = "true" ]; then
      uds_log "Will attempt to install Docker during dependency installation" "info"
    else
      uds_log "Docker is required for deployment. Use --install-deps to attempt installation." "error"
      return 1
    fi
  fi
  
  uds_log "Basic system requirements satisfied" "success"
  return 0
}

# Install system dependencies with enhanced checks
uds_install_dependencies() {
  uds_log "Installing system dependencies" "info"
  
  if [ "${DRY_RUN}" = "true" ]; then
    uds_log "DRY RUN: Would install dependencies" "info"
    return 0
  fi

  # Check for essential commands
  local REQUIRED_COMMANDS=("curl" "jq" "openssl" "git")
  local MISSING_COMMANDS=()

  for cmd in "${REQUIRED_COMMANDS[@]}"; do
    if ! command -v "$cmd" &>/dev/null; then
      MISSING_COMMANDS+=("$cmd")
    fi
  done

  if [ ${#MISSING_COMMANDS[@]} -gt 0 ]; then
    uds_log "Missing required commands: ${MISSING_COMMANDS[*]}" "warning"
  
    # Detect package manager
    if command -v apt-get &>/dev/null; then
      # Debian/Ubuntu
      uds_log "Detected apt package manager" "info"
      apt-get update
      apt-get install -y curl jq openssl git nginx certbot python3-certbot-nginx
    elif command -v yum &>/dev/null; then
      # CentOS/RHEL
      uds_log "Detected yum package manager" "info"
      yum -y update
      yum -y install curl jq openssl git nginx certbot python3-certbot-nginx
    elif command -v dnf &>/dev/null; then
      # Fedora
      uds_log "Detected dnf package manager" "info"
      dnf -y update
      dnf -y install curl jq openssl git nginx certbot python3-certbot-nginx
    elif command -v apk &>/dev/null; then
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
      if ! command -v "$cmd" &>/dev/null; then
        STILL_MISSING+=("$cmd")
      fi
    done
    
    if [ ${#STILL_MISSING[@]} -gt 0 ]; then
      uds_log "Failed to install: ${STILL_MISSING[*]}" "error"
      return 1
    fi
  fi
  
  # Check if Docker is installed
  if ! command -v docker &>/dev/null; then
    uds_log "Docker not installed. Installing..." "info"
    curl -fsSL https://get.docker.com | sh
    
    # Check Docker installation
    if ! command -v docker &>/dev/null; then
      uds_log "Failed to install Docker" "error"
      return 1
    fi
    
    # Start Docker service
    systemctl enable docker 2>/dev/null || service docker start 2>/dev/null || true
  fi
  
  # Check Docker is running
  if ! docker info &>/dev/null; then
    uds_log "Docker is not running, attempting to start..." "warning"
    systemctl start docker 2>/dev/null || service docker start 2>/dev/null || true
    
    # Check again
    if ! docker info &>/dev/null; then
      uds_log "Failed to start Docker" "error"
      uds_log "Please start Docker manually and try again" "error"
      return 1
    fi
  fi
  
  # Check if Docker Compose is installed
  if ! command -v docker-compose &>/dev/null && ! docker compose version &>/dev/null; then
    uds_log "Docker Compose not installed. Installing..." "info"
    
    # Install Docker Compose plugin or standalone based on Docker version
    if docker --version | grep -q "20\.[1-9][0-9]"; then
      # Docker 20.10+, use plugin
      if command -v apt-get &>/dev/null; then
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
    if ! $UDS_DOCKER_COMPOSE_CMD version &>/dev/null; then
      uds_log "Failed to install Docker Compose" "error"
      return 1
    fi
  fi
  
  # Add verification step for installed dependencies
  local VERIFY_COMMANDS=("docker" "curl" "jq" "openssl" "git")
  local MISSING_AFTER=()
  
  for cmd in "${VERIFY_COMMANDS[@]}"; do
    if ! command -v "$cmd" &>/dev/null; then
      MISSING_AFTER+=("$cmd")
    fi
  done
  
  # Special check for docker-compose (might be docker compose)
  if ! command -v docker-compose &>/dev/null && ! docker compose version &>/dev/null; then
    MISSING_AFTER+=("docker-compose")
  fi
  
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
  
  if [ "${DRY_RUN}" = "true" ]; then
    uds_log "DRY RUN: Would set up the system" "info"
    return 0
  fi
  
  # Create required directories
  mkdir -p "${UDS_CONFIGS_DIR}" "${UDS_LOGS_DIR}" "${UDS_CERTS_DIR}" "${UDS_NGINX_DIR}"
  
  # Create additional directories as needed
  if [ -n "${PERSISTENCE_DATA_DIR}" ]; then
    mkdir -p "${PERSISTENCE_DATA_DIR}"
  else
    mkdir -p "${UDS_BASE_DIR}/data"
    export PERSISTENCE_DATA_DIR="${UDS_BASE_DIR}/data"
  fi
  
  # Apply basic security permissions
  chmod 700 "${UDS_CONFIGS_DIR}" "${UDS_LOGS_DIR}" "${UDS_CERTS_DIR}"
  chmod 755 "${UDS_NGINX_DIR}"
  
  # Apply enhanced security if in secure mode
  if [ "${SECURE_MODE}" = "true" ]; then
    uds_log "Setting up enhanced security features" "info"
    
    # Tighten permissions further
    find "${UDS_CERTS_DIR}" -type f -exec chmod 600 {} \; 2>/dev/null || true
    find "${UDS_CONFIGS_DIR}" -type f -exec chmod 600 {} \; 2>/dev/null || true
    
    # Create log rotation configuration
    if command -v logrotate &>/dev/null; then
      uds_log "Setting up log rotation" "info"
      
      local logrotate_conf="/etc/logrotate.d/uds"
      cat > "$logrotate_conf" << EOL || true
${UDS_LOGS_DIR}/*.log {
  rotate 5
  size 10M
  missingok
  notifempty
  compress
  delaycompress
  create 600 root root
  sharedscripts
}
EOL
      chmod 644 "$logrotate_conf" 2>/dev/null || true
    fi
  fi
  
  # Execute pre-setup hooks - this will trigger plugin-specific setup
  uds_execute_hook "pre_setup" "$APP_NAME"
  
  # Set up application directory if app name is provided
  if [ -n "${APP_NAME}" ]; then
    mkdir -p "$APP_DIR"
    chmod 755 "$APP_DIR"
  fi
  
  # Initialize service registry if it doesn't exist
  if [ ! -f "${UDS_REGISTRY_FILE}" ]; then
    echo '{"services":{}}' > "${UDS_REGISTRY_FILE}"
    chmod 600 "${UDS_REGISTRY_FILE}"
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
  if [ "${CHECK_SYSTEM}" = "true" ]; then
    uds_check_system || {
      uds_log "System check failed - please resolve issues before continuing" "error"
      return 1
    }
  fi
  
  # Load configuration (activates plugins)
  uds_load_config "$CONFIG_FILE" || {
    uds_log "Failed to load configuration from ${CONFIG_FILE}" "error"
    return 1
  fi
  
  # Execute hook after configuration is loaded
  uds_execute_hook "config_loaded" "$APP_NAME"
  
  # Install dependencies if requested
  if [ "${INSTALL_DEPS}" = "true" ]; then
    uds_install_dependencies || {
      uds_log "Failed to install dependencies" "error"
      return 1
    }
  fi
  
  # Set up the system
  uds_setup_system || {
    uds_log "System setup failed" "error"
    return 1
  fi
  
  uds_log "UDS setup completed successfully!" "success"
  return 0
}

# Execute setup if being run directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  uds_do_setup "$@"
  exit $?
fi