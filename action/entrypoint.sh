#!/bin/bash
set -eo pipefail

# Function to log with timestamp
log() {
  echo "$(date "+%Y-%m-%d %H:%M:%S") $1"
}

log "UDS Docker Action started"

cleanup() {
  # Define important paths
  CONFIG_FILE="/opt/uds/configs/action-config.json"
  rm -rf "$SSH_DIR" || true
}

# Validate required inputs
if [ -z "${INPUT_APP_NAME}" ] && [ -z "$(printenv 'INPUT_APP-NAME')" ]; then
  log "Error: app-name is required"
  exit 1
fi

if [ -z "${INPUT_HOST}" ]; then
  log "Error: host is required"
  exit 1
fi

if [ -z "${INPUT_USERNAME}" ]; then
  log "Error: username is required"
  exit 1
fi

if [ -z "${INPUT_SSH_KEY}" ] && [ -z "$(printenv 'INPUT_SSH-KEY')" ]; then
  log "Error: ssh-key is required"
  exit 1
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
SSH_DIR="/tmp/.ssh"
mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"

# Validate SSH key format before writing
if ! echo "$SSH_KEY" | grep -q "BEGIN.*PRIVATE KEY"; then
  log "Error: Invalid SSH key format. Key must be in PEM format starting with -----BEGIN PRIVATE KEY-----"
  exit 1
fi

echo "$SSH_KEY" > "$SSH_DIR/id_rsa"
chmod 600 "$SSH_DIR/id_rsa"

# Configure SSH client with timeouts and failure handling
cat > "$SSH_DIR/config" << EOF
Host $HOST
  StrictHostKeyChecking no
  UserKnownHostsFile=/dev/null
  IdentityFile $SSH_DIR/id_rsa
  ConnectTimeout 30
  ServerAliveInterval 60
  ServerAliveCountMax 3
EOF
chmod 600 "$SSH_DIR/config"
SSH_COMMAND="ssh -F $SSH_DIR/config"

# Create JSON config with proper handling of complex values
log "Creating configuration file..."

# Process environment variables into valid JSON
ENV_VARS_JSON="$(printenv 'INPUT_ENV-VARS' || echo '{}')"
if ! echo "$ENV_VARS_JSON" | jq empty 2>/dev/null; then
  log "Warning: env-vars is not valid JSON, using empty object"
  ENV_VARS_JSON="{}"
fi

# Create the basic config structure with common fields
cat > "$CONFIG_FILE" << EOF
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
  "health_check_timeout": $(printenv 'INPUT_HEALTH-CHECK-TIMEOUT' || echo '60'),
  "health_check_type": "$(printenv 'INPUT_HEALTH-CHECK-TYPE' || echo 'auto')",
  "health_check_command": "$(printenv 'INPUT_HEALTH-CHECK-COMMAND' || echo '')",
  "port_auto_assign": $(printenv 'INPUT_PORT-AUTO-ASSIGN' || echo 'true'),
  "version_tracking": $(printenv 'INPUT_VERSION-TRACKING' || echo 'true'),
  "secure_mode": $(printenv 'INPUT_SECURE-MODE' || echo 'false'),
  "check_system": $(printenv 'INPUT_CHECK-SYSTEM' || echo 'false'),
  "extra_hosts": "$(printenv 'INPUT_EXTRA-HOSTS' || echo '')",
  "plugins": "$(printenv 'INPUT_PLUGINS' || echo '')"
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

# Enhanced installation with error handling
SETUP_CMD="set -e; mkdir -p $WORKING_DIR/configs && if [ ! -f $WORKING_DIR/uds-deploy.sh ]; then"
SETUP_CMD+=" echo 'Installing UDS scripts...';"
# Keeping the master branch for development as requested
SETUP_CMD+=" if ! curl -s -L https://github.com/elijahmont3x/unified-deploy-action/archive/refs/heads/master.tar.gz -o /tmp/uds.tar.gz; then"
SETUP_CMD+="   echo 'Failed to download UDS scripts'; exit 1;"
SETUP_CMD+=" fi;"
SETUP_CMD+=" mkdir -p /tmp/uds-extract $WORKING_DIR/scripts $WORKING_DIR/plugins;"
SETUP_CMD+=" if ! tar xzf /tmp/uds.tar.gz -C /tmp/uds-extract; then"
SETUP_CMD+="   echo 'Failed to extract UDS scripts'; exit 1;"
SETUP_CMD+=" fi;"
SETUP_CMD+=" cp -r /tmp/uds-extract/*/{scripts,plugins}/* $WORKING_DIR/ 2>/dev/null || cp -r /tmp/uds-extract/*/*/{scripts,plugins}/* $WORKING_DIR/;"
SETUP_CMD+=" chmod +x $WORKING_DIR/*.sh;"
SETUP_CMD+=" rm -rf /tmp/uds-extract /tmp/uds.tar.gz;"
SETUP_CMD+=" echo 'UDS installation completed successfully';"
SETUP_CMD+=" fi;"

DEPLOY_CMD="$SETUP_CMD && cat > $WORKING_DIR/configs/config.json && cd $WORKING_DIR && ./uds-$COMMAND.sh --config=configs/config.json"

log "Executing deployment via SSH..."
if ! $SSH_COMMAND -o ConnectTimeout=30 "$USERNAME@$HOST" "$DEPLOY_CMD" < "$CONFIG_FILE"; then
  log "ERROR: Deployment failed on remote server"
  log "Checking for detailed error logs..."
  $SSH_COMMAND -o ConnectTimeout=10 "$USERNAME@$HOST" "cat $WORKING_DIR/logs/uds.log 2>/dev/null | tail -n 50" || true
  exit 1
fi

# Clean up
rm -rf "$SSH_DIR"

log "UDS Docker Action completed successfully"
