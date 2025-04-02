#!/bin/bash
set -e

# Function to log with timestamp
log() {
  echo "$(date "+%Y-%m-%d %H:%M:%S") $1"
}

log "UDS Docker Action started"

# Define important paths
CONFIG_FILE="/opt/uds/configs/action-config.json"

# Access variables directly with proper escaping for hyphenated names
APP_NAME=$(printenv 'INPUT_APP-NAME')
HOST="${INPUT_HOST}"
USERNAME="${INPUT_USERNAME}"
SSH_KEY=$(printenv 'INPUT_SSH-KEY')

log "Processing inputs: APP_NAME='${APP_NAME}', HOST='${HOST}', USERNAME='${USERNAME}', SSH_KEY length=${#SSH_KEY}"

# Validate required inputs
if [ -z "$APP_NAME" ]; then
  log "Error: app-name is required"
  exit 1
fi

if [ -z "$HOST" ]; then
  log "Error: host is required"
  exit 1
fi

if [ -z "$USERNAME" ]; then
  log "Error: username is required"
  exit 1
fi

# Set up SSH with clean approach
if [ -n "$SSH_KEY" ]; then
  log "Setting up SSH..."
  
  # Create SSH directory
  SSH_DIR="/tmp/.ssh"
  mkdir -p "$SSH_DIR"
  chmod 700 "$SSH_DIR"
  
  # Write key to file
  printf "%s" "$SSH_KEY" > "$SSH_DIR/id_rsa"
  chmod 600 "$SSH_DIR/id_rsa"
  
  # Configure SSH client
  cat > "$SSH_DIR/config" << EOF
Host $HOST
  StrictHostKeyChecking no
  UserKnownHostsFile=/dev/null
  IdentityFile $SSH_DIR/id_rsa
EOF
  chmod 600 "$SSH_DIR/config"
  
  # Set SSH command
  SSH_COMMAND="ssh -F $SSH_DIR/config"
else
  log "Error: ssh-key is required"
  exit 1
fi

# Process environment variables for config
log "Processing configuration parameters..."
ENV_VARS_JSON=$(printenv 'INPUT_ENV-VARS' 2>/dev/null || echo '{}')
if ! echo "$ENV_VARS_JSON" | jq . &>/dev/null; then
  log "Warning: env_vars is not valid JSON, using empty object"
  ENV_VARS_JSON="{}"
fi

# Create clean config file
log "Generating configuration file..."
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
  "volumes": "$(printenv 'INPUT_VOLUMES' || echo '')",
  "env_vars": $ENV_VARS_JSON,
  "persistent": $(printenv 'INPUT_PERSISTENT' || echo 'false'),
  "compose_file": "$(printenv 'INPUT_COMPOSE-FILE' || echo '')",
  "use_profiles": $(printenv 'INPUT_USE-PROFILES' || echo 'true'),
  "extra_hosts": "$(printenv 'INPUT_EXTRA-HOSTS' || echo '')",
  "health_check": "$(printenv 'INPUT_HEALTH-CHECK' || echo '/health')",
  "health_check_timeout": $(printenv 'INPUT_HEALTH-CHECK-TIMEOUT' || echo '60'),
  "health_check_type": "$(printenv 'INPUT_HEALTH-CHECK-TYPE' || echo 'auto')",
  "health_check_command": "$(printenv 'INPUT_HEALTH-CHECK-COMMAND' || echo '')",
  "port_auto_assign": $(printenv 'INPUT_PORT-AUTO-ASSIGN' || echo 'true'),
  "version_tracking": $(printenv 'INPUT_VERSION-TRACKING' || echo 'true'),
  "pg_migration_enabled": $(printenv 'INPUT_PG-MIGRATION-ENABLED' || echo 'false'),
  "pg_connection_string": "$(printenv 'INPUT_PG-CONNECTION-STRING' || echo '')",
  "pg_backup_enabled": $(printenv 'INPUT_PG-BACKUP-ENABLED' || echo 'true'),
  "pg_migration_script": "$(printenv 'INPUT_PG-MIGRATION-SCRIPT' || echo '')",
  "telegram_enabled": $(printenv 'INPUT_TELEGRAM-ENABLED' || echo 'false'),
  "telegram_bot_token": "$(printenv 'INPUT_TELEGRAM-BOT-TOKEN' || echo '')",
  "telegram_chat_id": "$(printenv 'INPUT_TELEGRAM-CHAT-ID' || echo '')",
  "telegram_notify_level": "$(printenv 'INPUT_TELEGRAM-NOTIFY-LEVEL' || echo 'info')",
  "telegram_include_logs": $(printenv 'INPUT_TELEGRAM-INCLUDE-LOGS' || echo 'true'),
  "max_log_lines": $(printenv 'INPUT_MAX-LOG-LINES' || echo '100'),
  "plugins": "$(printenv 'INPUT_PLUGINS' || echo '')"
}
EOF

# Validate config
if ! jq . "$CONFIG_FILE" > /dev/null 2>&1; then
  log "ERROR: Generated JSON config is invalid"
  cat "$CONFIG_FILE"
  exit 1
fi

# Prepare remote deployment command
log "Preparing remote deployment command..."
WORKING_DIR="$(printenv 'INPUT_WORKING-DIR' || echo '/opt/uds')"

# Setup scripts on remote server if needed
SETUP_CMD="if [ ! -f \"$WORKING_DIR/uds-deploy.sh\" ]; then"
SETUP_CMD+=" echo \"Installing UDS scripts...\";"
SETUP_CMD+=" mkdir -p $WORKING_DIR/scripts $WORKING_DIR/plugins;"
SETUP_CMD+=" curl -s -L https://github.com/elijahmont3x/unified-deploy-action/archive/refs/heads/master.tar.gz | tar xz -C /tmp;"
SETUP_CMD+=" cp -r /tmp/unified-deploy-action-master/scripts/* $WORKING_DIR/;"
SETUP_CMD+=" cp -r /tmp/unified-deploy-action-master/plugins/* $WORKING_DIR/plugins/;"
SETUP_CMD+=" chmod +x $WORKING_DIR/*.sh $WORKING_DIR/plugins/*.sh 2>/dev/null || true;"
SETUP_CMD+=" rm -rf /tmp/unified-deploy-action-master;"
SETUP_CMD+=" fi"

# Handle different commands
case "$(printenv 'INPUT_COMMAND' || echo 'deploy')" in
  setup)
    DEPLOY_CMD="bash -c '$SETUP_CMD && mkdir -p $WORKING_DIR && cat > $WORKING_DIR/config.json' && cd $WORKING_DIR && ./uds-setup.sh --config=config.json"
    ;;
  cleanup)
    DEPLOY_CMD="bash -c '$SETUP_CMD && mkdir -p $WORKING_DIR && cat > $WORKING_DIR/config.json' && cd $WORKING_DIR && ./uds-cleanup.sh --config=config.json"
    ;;
  *)
    DEPLOY_CMD="bash -c '$SETUP_CMD && mkdir -p $WORKING_DIR && cat > $WORKING_DIR/config.json' && cd $WORKING_DIR && ./uds-deploy.sh --config=config.json"
    ;;
esac

# Execute deployment via SSH
log "Executing deployment via SSH..."
$SSH_COMMAND "$USERNAME@$HOST" "$DEPLOY_CMD" < "$CONFIG_FILE"

# Clean up
rm -rf "$SSH_DIR"

log "UDS Docker Action completed successfully"
