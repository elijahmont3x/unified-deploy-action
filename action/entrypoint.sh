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
  exit 1
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

# Access other key variables
HOST="${INPUT_HOST}"
USERNAME="${INPUT_USERNAME}"
SSH_KEY=$(printenv 'INPUT_SSH-KEY')
if [ -z "$SSH_KEY" ]; then
  SSH_KEY="${INPUT_SSH_KEY}"
fi

log "Processing inputs: APP_NAME='${APP_NAME}', HOST='${HOST}', USERNAME='${USERNAME}'"

# Enhanced SSH setup with validation and timeouts
log "Setting up SSH..."
SSH_DIR=$(mktemp -d)
if [ $? -ne 0 ]; then
  error_exit "Failed to create temporary SSH directory"
fi

chmod 700 "$SSH_DIR" || error_exit "Failed to set permissions on SSH directory"

# Validate SSH key format before writing
if ! echo "$SSH_KEY" | grep -q "BEGIN.*PRIVATE KEY"; then
  error_exit "Invalid SSH key format. Key must be in PEM format starting with -----BEGIN PRIVATE KEY-----"
fi

echo "$SSH_KEY" > "$SSH_DIR/id_rsa" || error_exit "Failed to write SSH key"
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
EOF
chmod 600 "$SSH_DIR/config" || error_exit "Failed to set permissions on SSH config"
SSH_COMMAND="ssh -F $SSH_DIR/config"

# Test SSH connection before proceeding
log "Testing SSH connection..."
if ! $SSH_COMMAND -o ConnectTimeout=10 "$USERNAME@$HOST" "echo 'SSH connection successful'" > /dev/null 2>&1; then
  error_exit "Failed to establish SSH connection to $HOST. Please check credentials and network connectivity."
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

# Create the basic config structure with common fields
cat > "$CONFIG_FILE" << EOF || error_exit "Failed to write config file"
{
  "command": "$(printenv 'INPUT_COMMAND' || echo 'deploy')",
  "app_name": "$APP_NAME",
  "image": "$(printenv 'INPUT_IMAGE' || echo '')",
  "tag": "$(printenv 'INPUT_TAG' || echo 'latest')",
  "domain": "$(printenv 'INPUT_DOMAIN' || echo '')",
  "route_type": "$(printenv 'INPUT_ROUTE-TYPE' || echo 'path')",
  "route": "$(printenv 'INPUT_ROUTE' || echo '')",
  "port": "$(printenv 'INPUT_PORT' || echo '3000')",
  "ssl": $(printenv 'INPUT_SSL' || echo 'true'),
  "ssl_email": "$(printenv 'INPUT_SSL-EMAIL' || echo '')",
  "ssl_wildcard": $(printenv 'INPUT_SSL-WILDCARD' || echo 'false'),
  "ssl_dns_provider": "$(printenv 'INPUT_SSL-DNS-PROVIDER' || echo '')",
  "ssl_dns_credentials": "$(printenv 'INPUT_SSL-DNS-CREDENTIALS' || echo '')",
  "volumes": "$(printenv 'INPUT_VOLUMES' || echo '')",
  "env_vars": $ENV_VARS_JSON,
  "persistent": $(printenv 'INPUT_PERSISTENT' || echo 'false'),
  "compose_file": "$(printenv 'INPUT_COMPOSE-FILE' || echo '')",
  "use_profiles": $(printenv 'INPUT_USE-PROFILES' || echo 'true'),
  "multi_stage": $(printenv 'INPUT_MULTI-STAGE' || echo 'false'),
  "check_dependencies": $(printenv 'INPUT_CHECK-DEPENDENCIES' || echo 'false'),
  "health_check": "$(printenv 'INPUT_HEALTH-CHECK' || echo '/health')",
  "health_check_timeout": "$(printenv 'INPUT_HEALTH-CHECK-TIMEOUT' || echo '60')",
  "health_check_type": "$(printenv 'INPUT_HEALTH-CHECK-TYPE' || echo 'auto')",
  "health_check_command": "$(printenv 'INPUT_HEALTH-CHECK-COMMAND' || echo '')",
  "port_auto_assign": $(printenv 'INPUT_PORT-AUTO-ASSIGN' || echo 'true'),
  "version_tracking": $(printenv 'INPUT_VERSION-TRACKING' || echo 'true'),
  "secure_mode": $(printenv 'INPUT_SECURE-MODE' || echo 'false'),
  "check_system": $(printenv 'INPUT_CHECK-SYSTEM' || echo 'false'),
  "extra_hosts": "$(printenv 'INPUT_EXTRA-HOSTS' || echo '')",
  "plugins": "$(printenv 'INPUT_PLUGINS' || echo '')",
  "pg_migration_enabled": $(printenv 'INPUT_PG-MIGRATION-ENABLED' || echo 'false'),
  "pg_connection_string": "$(printenv 'INPUT_PG-CONNECTION-STRING' || echo '')",
  "pg_backup_enabled": $(printenv 'INPUT_PG-BACKUP-ENABLED' || echo 'true'),
  "pg_migration_script": "$(printenv 'INPUT_PG-MIGRATION-SCRIPT' || echo '')",
  "telegram_enabled": $(printenv 'INPUT_TELEGRAM-ENABLED' || echo 'false'),
  "telegram_bot_token": "$(printenv 'INPUT_TELEGRAM-BOT-TOKEN' || echo '')",
  "telegram_chat_id": "$(printenv 'INPUT_TELEGRAM-CHAT-ID' || echo '')",
  "telegram_notify_level": "$(printenv 'INPUT_TELEGRAM-NOTIFY-LEVEL' || echo 'info')",
  "telegram_include_logs": $(printenv 'INPUT_TELEGRAM-INCLUDE-LOGS' || echo 'true'),
  "max_log_lines": "$(printenv 'INPUT_MAX-LOG-LINES' || echo '50')"
}
EOF

# Validate the JSON is correct
if ! jq empty "$CONFIG_FILE" 2>/dev/null; then
  log "ERROR: Invalid JSON configuration"
  cat "$CONFIG_FILE"
  exit 1
fi

log "Configuration file created successfully"

# Prepare commands for the remote server
WORKING_DIR="$(printenv 'INPUT_WORKING-DIR' || echo '/opt/uds')"
COMMAND="$(printenv 'INPUT_COMMAND' || echo 'deploy')"

# Enhanced installation with error handling and progress tracking
SETUP_CMD="set -e; mkdir -p $WORKING_DIR/configs"
SETUP_CMD+=" && if [ ! -f $WORKING_DIR/uds-deploy.sh ]; then"
SETUP_CMD+=" echo 'Installing UDS scripts...';"

# Download with fallback URLs and better error handling
SETUP_CMD+=" download_url='https://github.com/elijahmont3x/unified-deploy-action/archive/refs/heads/master.tar.gz';"
SETUP_CMD+=" fallback_url='https://github.com/elijahmont3x/unified-deploy-action/archive/refs/heads/main.tar.gz';"
SETUP_CMD+=" echo 'Downloading UDS scripts from primary URL...';"
SETUP_CMD+=" if ! curl -s -L \$download_url -o /tmp/uds.tar.gz; then"
SETUP_CMD+="   echo 'Primary URL failed, trying fallback URL...';"
SETUP_CMD+="   if ! curl -s -L \$fallback_url -o /tmp/uds.tar.gz; then"
SETUP_CMD+="     echo 'Failed to download UDS scripts from both URLs'; exit 1;"
SETUP_CMD+="   fi;"
SETUP_CMD+=" fi;"

SETUP_CMD+=" mkdir -p /tmp/uds-extract $WORKING_DIR/scripts $WORKING_DIR/plugins;"
SETUP_CMD+=" echo 'Extracting UDS scripts...';"
SETUP_CMD+=" if ! tar xzf /tmp/uds.tar.gz -C /tmp/uds-extract; then"
SETUP_CMD+="   echo 'Failed to extract UDS scripts'; rm -f /tmp/uds.tar.gz; exit 1;"
SETUP_CMD+=" fi;"

# More robust path handling
SETUP_CMD+=" echo 'Installing UDS files...';"
SETUP_CMD+=" if [ -d /tmp/uds-extract/*/scripts ]; then"
SETUP_CMD+="   cp -r /tmp/uds-extract/*/scripts/* $WORKING_DIR/scripts/ 2>/dev/null || true;"
SETUP_CMD+="   cp -r /tmp/uds-extract/*/plugins/* $WORKING_DIR/plugins/ 2>/dev/null || true;"
SETUP_CMD+=" elif [ -d /tmp/uds-extract/*/*/scripts ]; then"
SETUP_CMD+="   cp -r /tmp/uds-extract/*/*/scripts/* $WORKING_DIR/scripts/ 2>/dev/null || true;"
SETUP_CMD+="   cp -r /tmp/uds-extract/*/*/plugins/* $WORKING_DIR/plugins/ 2>/dev/null || true;"
SETUP_CMD+=" else"
SETUP_CMD+="   find /tmp/uds-extract -name 'scripts' -type d | while read dir; do cp -r \$dir/* $WORKING_DIR/scripts/ 2>/dev/null || true; done;"
SETUP_CMD+="   find /tmp/uds-extract -name 'plugins' -type d | while read dir; do cp -r \$dir/* $WORKING_DIR/plugins/ 2>/dev/null || true; done;"
SETUP_CMD+=" fi;"

# Copy core files to main directory for backwards compatibility
SETUP_CMD+=" cp $WORKING_DIR/scripts/*.sh $WORKING_DIR/ 2>/dev/null || true;"
SETUP_CMD+=" chmod +x $WORKING_DIR/*.sh $WORKING_DIR/scripts/*.sh $WORKING_DIR/plugins/*.sh 2>/dev/null || true;"
SETUP_CMD+=" rm -rf /tmp/uds-extract /tmp/uds.tar.gz;"
SETUP_CMD+=" echo 'UDS installation completed successfully';"
SETUP_CMD+=" fi;"

# Create deploy command with better error handling
DEPLOY_CMD="$SETUP_CMD && cat > $WORKING_DIR/configs/config.json && cd $WORKING_DIR && ./uds-$COMMAND.sh --config=configs/config.json"

log "Executing deployment via SSH..."
if ! $SSH_COMMAND -o ConnectTimeout=30 "$USERNAME@$HOST" "$DEPLOY_CMD" < "$CONFIG_FILE"; then
  log "ERROR: Deployment failed on remote server"
  log "Checking for detailed error logs..."
  
  # Get more comprehensive error information
  $SSH_COMMAND -o ConnectTimeout=10 "$USERNAME@$HOST" "cat $WORKING_DIR/logs/uds.log 2>/dev/null | tail -n 100" || true
  
  # Check for specific error patterns
  $SSH_COMMAND -o ConnectTimeout=10 "$USERNAME@$HOST" "if [ -f $WORKING_DIR/logs/uds.log ]; then grep -i 'error\|failed\|exception' $WORKING_DIR/logs/uds.log | tail -n 20; fi" || true
  
  # Get Docker container status if applicable
  $SSH_COMMAND -o ConnectTimeout=10 "$USERNAME@$HOST" "if command -v docker > /dev/null; then echo 'Docker container status:'; docker ps -a | grep '$APP_NAME' || echo 'No containers found'; fi" || true
  
  error_exit "Deployment failed on remote server"
fi

log "UDS Docker Action completed successfully"