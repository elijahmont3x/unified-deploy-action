#!/bin/bash
set -eo pipefail

# Function to log with timestamp
log() {
  echo "$(date "+%Y-%m-%d %H:%M:%S") $1"
}

log "UDS Docker Action started"

# Define important paths
SSH_DIR=""
CONFIG_FILE=""

# Setup proper cleanup
cleanup() {
  if [ -n "$SSH_DIR" ] && [ -d "$SSH_DIR" ]; then
    log "Cleaning up SSH files"
    rm -rf "$SSH_DIR" 2>/dev/null || true
  fi
  
  if [ -n "$CONFIG_FILE" ] && [ -f "$CONFIG_FILE" ]; then
    log "Cleaning up temporary config file"
    rm -f "$CONFIG_FILE" 2>/dev/null || true
  fi
}

# Ensure cleanup runs on exit
trap cleanup EXIT

# Function to handle errors
error_exit() {
  log "ERROR: $1"
  # Set failure output for GitHub Actions
  if [ -n "$GITHUB_OUTPUT" ]; then
    echo "status=failure" >> $GITHUB_OUTPUT
    echo "error_message=$1" >> $GITHUB_OUTPUT
  fi
  exit 1
}

# Set up GitHub Actions output
set_output() {
  local name="$1"
  local value="$2"
  if [ -n "$GITHUB_OUTPUT" ]; then
    echo "${name}=${value}" >> $GITHUB_OUTPUT
  else
    log "Warning: GITHUB_OUTPUT not set, cannot set output: ${name}=${value}"
  fi
}

# Function to sanitize values for safe use in commands
sanitize_value() {
  local value="$1"
  local allow_extra_chars="${2:-false}"
  
  if [ -z "$value" ]; then
    echo ""
    return 0
  fi
  
  # Basic alphanumeric and common safe characters
  local safe_pattern="a-zA-Z0-9._-"
  
  # Add additional safe characters if needed (for URLs, paths, etc.)
  if [ "$allow_extra_chars" = "true" ]; then
    safe_pattern="${safe_pattern}/:=,"
  fi
  
  # Use parameter expansion to ensure no subshell is created
  # which prevents command injection attempts
  local sanitized="${value//[^${safe_pattern}]/}"
  
  # Ensure we're not returning an empty string if input wasn't empty
  if [ -n "$value" ] && [ -z "$sanitized" ]; then
    echo "invalid_input"
    return 1
  fi
  
  echo "$sanitized"
}

# Function to get and sanitize input value
get_input() {
  local name="$1"
  local default="$2"
  local is_boolean="${3:-false}"
  
  # Handle hyphenated input names
  local value="$(printenv "INPUT_${name}" || printenv "INPUT_${name//_/-}" || echo "$default")"
  
  # For boolean values, don't sanitize
  if [ "$is_boolean" = "true" ]; then
    echo "$value"
  else
    sanitize_value "$value"
  fi
}

# Validate required inputs
if [ -z "${INPUT_APP_NAME}" ] && [ -z "$(printenv 'INPUT_APP-NAME')" ]; then
  error_exit "app-name is required"
fi

if [ -z "${INPUT_HOST}" ]; then
  error_exit "host is required"
fi

if [ -z "${INPUT_USERNAME}" ]; then
  error_exit "username is required"
fi

if [ -z "${INPUT_SSH_KEY}" ] && [ -z "$(printenv 'INPUT_SSH-KEY')" ]; then
  error_exit "ssh-key is required"
fi

# Set APP_NAME - handle hyphenated input name
APP_NAME="${INPUT_APP_NAME}"
if [ -z "$APP_NAME" ]; then
  APP_NAME=$(printenv 'INPUT_APP-NAME')
fi

# Validate APP_NAME format for safety
if ! [[ "$APP_NAME" =~ ^[a-zA-Z0-9_.-]+$ ]]; then
  error_exit "Invalid app-name format. Use only alphanumeric characters, underscores, periods, and hyphens."
fi

# Access other key variables
HOST="${INPUT_HOST}"
USERNAME="${INPUT_USERNAME}"
SSH_KEY=$(printenv 'INPUT_SSH-KEY')
if [ -z "$SSH_KEY" ]; then
  SSH_KEY="${INPUT_SSH_KEY}"
fi

# Validate HOST format
if ! [[ "$HOST" =~ ^[a-zA-Z0-9._-]+$ ]] && ! [[ "$HOST" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  error_exit "Invalid host format. Use a valid hostname or IP address."
fi

# Validate USERNAME format
if ! [[ "$USERNAME" =~ ^[a-zA-Z0-9_.-]+$ ]]; then
  error_exit "Invalid username format. Use only alphanumeric characters, underscores, periods, and hyphens."
fi

log "Processing inputs: APP_NAME='${APP_NAME}', HOST='${HOST}', USERNAME='${USERNAME}'"

# Enhanced SSH setup with validation and timeouts
log "Setting up SSH..."
SSH_DIR=$(mktemp -d)
if [ $? -ne 0 ]; then
  error_exit "Failed to create temporary SSH directory"
fi

chmod 700 "$SSH_DIR" || error_exit "Failed to set permissions on SSH directory"

# Enhanced SSH key validation
validate_ssh_key() {
  local key="$1"
  local key_file="$2"
  
  # Write key to temporary file for validation
  echo "$key" > "$key_file"
  
  # Check if key starts with proper headers for various key types
  if ! grep -qE '^\-\-\-\-\-BEGIN (RSA|OPENSSH|DSA|EC|PGP) PRIVATE KEY\-\-\-\-\-' "$key_file"; then
    return 1
  fi
  
  # Additional validation using ssh-keygen if available
  if command -v ssh-keygen &>/dev/null; then
    if ! ssh-keygen -l -f "$key_file" &>/dev/null; then
      return 1
    fi
  fi
  
  return 0
}

# Validate SSH key with enhanced checks
if ! validate_ssh_key "$SSH_KEY" "$SSH_DIR/id_rsa.tmp"; then
  error_exit "Invalid SSH key format. Key must be a valid private key."
fi

# Move the validated key to the final location
mv "$SSH_DIR/id_rsa.tmp" "$SSH_DIR/id_rsa" || error_exit "Failed to write SSH key"
chmod 600 "$SSH_DIR/id_rsa" || error_exit "Failed to set permissions on SSH key"

# Configure SSH client with timeouts and failure handling
cat > "$SSH_DIR/config" << EOF || error_exit "Failed to create SSH config"
Host $HOST
  StrictHostKeyChecking no
  UserKnownHostsFile=/dev/null
  IdentityFile $SSH_DIR/id_rsa
  ConnectTimeout 30
  ServerAliveInterval 60
  ServerAliveCountMax 3
  LogLevel ERROR
EOF
chmod 600 "$SSH_DIR/config" || error_exit "Failed to set permissions on SSH config"
SSH_COMMAND="ssh -F $SSH_DIR/config"

# Test SSH connection before proceeding
log "Testing SSH connection..."
if ! $SSH_COMMAND -o ConnectTimeout=10 "$USERNAME@$HOST" "echo 'SSH connection successful'" > /dev/null 2>&1; then
  # Enhanced SSH connection troubleshooting
  log "Checking SSH connection with increased verbosity..."
  $SSH_COMMAND -v -o ConnectTimeout=10 "$USERNAME@$HOST" "echo 'SSH connection test'" > /tmp/ssh_debug.log 2>&1 || true
  
  # Check for common SSH errors
  if grep -q "Connection refused" /tmp/ssh_debug.log; then
    error_exit "Failed to establish SSH connection to $HOST: Connection refused. Please check if SSH service is running."
  elif grep -q "Connection timed out" /tmp/ssh_debug.log; then
    error_exit "Failed to establish SSH connection to $HOST: Connection timed out. Please check network connectivity and firewall rules."
  elif grep -q "Permission denied" /tmp/ssh_debug.log; then
    error_exit "Failed to establish SSH connection to $HOST: Permission denied. Please check SSH credentials."
  elif grep -q "Host key verification failed" /tmp/ssh_debug.log; then
    error_exit "Failed to establish SSH connection to $HOST: Host key verification failed."
  else
    error_exit "Failed to establish SSH connection to $HOST. Please check credentials and network connectivity."
  fi
fi

# Create JSON config with proper handling of complex values
log "Creating configuration file..."
CONFIG_FILE=$(mktemp)
if [ $? -ne 0 ]; then
  error_exit "Failed to create temporary config file"
fi

# Process environment variables into valid JSON
ENV_VARS_JSON="$(printenv 'INPUT_ENV-VARS' || echo '{}')"
if ! echo "$ENV_VARS_JSON" | jq empty 2>/dev/null; then
  log "Warning: env-vars is not valid JSON, using empty object"
  ENV_VARS_JSON="{}"
fi

# Process domain with check for empty value
DOMAIN="$(get_input "DOMAIN" "")"
if [ -z "$DOMAIN" ]; then
  error_exit "domain is required"
fi

# Validate domain format
if ! [[ "$DOMAIN" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
  error_exit "Invalid domain format. Please provide a valid domain name."
fi

# Create the configuration file with sanitized inputs
cat > "$CONFIG_FILE" << EOL || error_exit "Failed to write config file"
{
  "command": "$(get_input "COMMAND" "deploy")",
  "app_name": "${APP_NAME}",
  "image": "$(get_input "IMAGE" "")",
  "tag": "$(get_input "TAG" "latest")",
  "domain": "${DOMAIN}",
  "route_type": "$(get_input "ROUTE_TYPE" "path")",
  "route": "$(get_input "ROUTE" "")",
  "port": "$(get_input "PORT" "3000")",
  "ssl": $(get_input "SSL" "true" "true"),
  "ssl_email": "$(get_input "SSL_EMAIL" "")",
  "ssl_wildcard": $(get_input "SSL_WILDCARD" "false" "true"),
  "ssl_dns_provider": "$(get_input "SSL_DNS_PROVIDER" "")",
  "ssl_dns_credentials": "$(get_input "SSL_DNS_CREDENTIALS" "")",
  "volumes": "$(get_input "VOLUMES" "")",
  "env_vars": $ENV_VARS_JSON,
  "persistent": $(get_input "PERSISTENT" "false" "true"),
  "compose_file": "$(get_input "COMPOSE_FILE" "")",
  "use_profiles": $(get_input "USE_PROFILES" "true" "true"),
  "multi_stage": $(get_input "MULTI_STAGE" "false" "true"),
  "check_dependencies": $(get_input "CHECK_DEPENDENCIES" "false" "true"),
  "health_check": "$(get_input "HEALTH_CHECK" "/health")",
  "health_check_timeout": "$(get_input "HEALTH_CHECK_TIMEOUT" "60")",
  "health_check_type": "$(get_input "HEALTH_CHECK_TYPE" "auto")",
  "health_check_command": "$(get_input "HEALTH_CHECK_COMMAND" "")",
  "port_auto_assign": $(get_input "PORT_AUTO_ASSIGN" "true" "true"),
  "version_tracking": $(get_input "VERSION_TRACKING" "true" "true"),
  "secure_mode": $(get_input "SECURE_MODE" "false" "true"),
  "check_system": $(get_input "CHECK_SYSTEM" "false" "true"),
  "extra_hosts": "$(get_input "EXTRA_HOSTS" "")",
  "plugins": "$(get_input "PLUGINS" "")",
  "pg_migration_enabled": $(get_input "PG_MIGRATION_ENABLED" "false" "true"),
  "pg_connection_string": "$(get_input "PG_CONNECTION_STRING" "")",
  "pg_backup_enabled": $(get_input "PG_BACKUP_ENABLED" "true" "true"),
  "pg_migration_script": "$(get_input "PG_MIGRATION_SCRIPT" "")",
  "telegram_enabled": $(get_input "TELEGRAM_ENABLED" "false" "true"),
  "telegram_bot_token": "$(get_input "TELEGRAM_BOT_TOKEN" "")",
  "telegram_chat_id": "$(get_input "TELEGRAM_CHAT_ID" "")",
  "telegram_notify_level": "$(get_input "TELEGRAM_NOTIFY_LEVEL" "info")",
  "telegram_include_logs": $(get_input "TELEGRAM_INCLUDE_LOGS" "true" "true"),
  "max_log_lines": "$(get_input "MAX_LOG_LINES" "50")",
  "auto_rollback": $(get_input "AUTO_ROLLBACK" "true" "true")
}
EOL

# Validate the JSON is correct
if ! jq empty "$CONFIG_FILE" 2>/dev/null; then
  log "ERROR: Invalid JSON configuration"
  cat "$CONFIG_FILE"
  error_exit "Failed to create valid JSON configuration"
fi

log "Configuration file created successfully"

# Prepare commands for the remote server
WORKING_DIR="$(get_input "WORKING_DIR" "/opt/uds")"
COMMAND="$(get_input "COMMAND" "deploy")"

# Enhanced installation with error handling and progress tracking
SETUP_CMD="set -e; mkdir -p $WORKING_DIR/configs $WORKING_DIR/scripts $WORKING_DIR/plugins"
SETUP_CMD+=" && if [ ! -f $WORKING_DIR/uds-deploy.sh ]; then"
SETUP_CMD+=" echo 'Installing UDS scripts...';"

# Download with better error handling
SETUP_CMD+=" download_url='https://github.com/elijahmont3x/unified-deploy-action/archive/refs/heads/master.tar.gz';"
SETUP_CMD+=" echo 'Downloading UDS scripts...';"
SETUP_CMD+=" if ! curl -s -L \$download_url -o /tmp/uds.tar.gz; then"
SETUP_CMD+="   echo 'Failed to download UDS scripts'; exit 1;"
SETUP_CMD+=" fi;"

SETUP_CMD+=" mkdir -p /tmp/uds-extract;"
SETUP_CMD+=" echo 'Extracting UDS scripts...';"
SETUP_CMD+=" if ! tar xzf /tmp/uds.tar.gz -C /tmp/uds-extract; then"
SETUP_CMD+="   echo 'Failed to extract UDS scripts'; rm -f /tmp/uds.tar.gz; exit 1;"
SETUP_CMD+=" fi;"

# More robust path handling
SETUP_CMD+=" echo 'Installing UDS files...';"
SETUP_CMD+=" find /tmp/uds-extract -name 'scripts' -type d | while read dir; do cp -r \$dir/* $WORKING_DIR/scripts/ 2>/dev/null || true; done;"
SETUP_CMD+=" find /tmp/uds-extract -name 'plugins' -type d | while read dir; do cp -r \$dir/* $WORKING_DIR/plugins/ 2>/dev/null || true; done;"

# Make scripts executable and clean up
SETUP_CMD+=" chmod +x $WORKING_DIR/scripts/*.sh $WORKING_DIR/plugins/*.sh 2>/dev/null || true;"
SETUP_CMD+=" rm -rf /tmp/uds-extract /tmp/uds.tar.gz;"
SETUP_CMD+=" echo 'UDS installation completed successfully';"
SETUP_CMD+=" fi;"

# Create deploy command with better error handling
DEPLOY_CMD="$SETUP_CMD && mkdir -p $WORKING_DIR/logs && cat > $WORKING_DIR/configs/${APP_NAME}_config.json && cd $WORKING_DIR && ./uds-$COMMAND.sh --config=configs/${APP_NAME}_config.json"

# Capture deployment output to extract deployment URL and status
DEPLOY_OUTPUT_FILE=$(mktemp)
log "Executing deployment via SSH..."
if ! $SSH_COMMAND -o ConnectTimeout=30 "$USERNAME@$HOST" "$DEPLOY_CMD" < "$CONFIG_FILE" > "$DEPLOY_OUTPUT_FILE" 2>&1; then
  log "ERROR: Deployment failed on remote server"
  log "Checking for detailed error logs..."
  
  # Display output content
  cat "$DEPLOY_OUTPUT_FILE" || true
  
  # Get more comprehensive error information
  $SSH_COMMAND -o ConnectTimeout=10 "$USERNAME@$HOST" "cat $WORKING_DIR/logs/uds.log 2>/dev/null | tail -n 100" || true
  
  # Check for specific error patterns
  $SSH_COMMAND -o ConnectTimeout=10 "$USERNAME@$HOST" "if [ -f $WORKING_DIR/logs/uds.log ]; then grep -i 'error\|failed\|exception' $WORKING_DIR/logs/uds.log | tail -n 20; fi" || true
  
  # Get Docker container status if applicable
  $SSH_COMMAND -o ConnectTimeout=10 "$USERNAME@$HOST" "if command -v docker > /dev/null; then echo 'Docker container status:'; docker ps -a | grep '$APP_NAME' || echo 'No containers found'; fi" || true
  
  # Set outputs for GitHub Actions
  set_output "status" "failure"
  set_output "deployment_url" ""
  set_output "version" "$(get_input "TAG" "latest")"
  set_output "logs" "$(cat "$DEPLOY_OUTPUT_FILE" | head -n 50)"
  
  error_exit "Deployment failed on remote server"
fi

# Process output to extract URL and version
DEPLOYMENT_URL=""
if grep -q "Application is available at:" "$DEPLOY_OUTPUT_FILE"; then
  DEPLOYMENT_URL=$(grep "Application is available at:" "$DEPLOY_OUTPUT_FILE" | sed 's/.*Application is available at: \(.*\)/\1/')
elif grep -q "https://${DOMAIN}" "$DEPLOY_OUTPUT_FILE"; then
  DEPLOYMENT_URL=$(grep -o "https://${DOMAIN}[^ ]*" "$DEPLOY_OUTPUT_FILE" | head -1)
elif grep -q "http://${DOMAIN}" "$DEPLOY_OUTPUT_FILE"; then
  DEPLOYMENT_URL=$(grep -o "http://${DOMAIN}[^ ]*" "$DEPLOY_OUTPUT_FILE" | head -1)
else
  # Construct URL based on inputs if not found in output
  local ssl=$(get_input "SSL" "true" "true")
  local route_type=$(get_input "ROUTE_TYPE" "path")
  local route=$(get_input "ROUTE" "")
  
  if [ "$ssl" = "true" ]; then
    URL_SCHEME="https"
  else
    URL_SCHEME="http"
  fi
  
  if [ "$route_type" = "subdomain" ] && [ -n "$route" ]; then
    DEPLOYMENT_URL="${URL_SCHEME}://${route}.${DOMAIN}"
  elif [ "$route_type" = "path" ] && [ -n "$route" ]; then
    DEPLOYMENT_URL="${URL_SCHEME}://${DOMAIN}/${route}"
  else
    DEPLOYMENT_URL="${URL_SCHEME}://${DOMAIN}"
  fi
fi

# Extract deployment logs for GitHub Actions output
DEPLOY_LOGS=$(cat "$DEPLOY_OUTPUT_FILE" | tail -n 50)

# Set outputs for GitHub Actions
set_output "status" "success"
set_output "deployment_url" "$DEPLOYMENT_URL"
set_output "version" "$(get_input "TAG" "latest")"
set_output "logs" "$DEPLOY_LOGS"

rm -f "$DEPLOY_OUTPUT_FILE"
log "UDS Docker Action completed successfully"
log "Application deployed to: $DEPLOYMENT_URL"