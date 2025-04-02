#!/bin/bash
set -e

# Function to log with timestamp
log() {
  echo "$(date "+%Y-%m-%d %H:%M:%S") $1"
}

log "UDS Docker Action started"

# Debug show inputs for troubleshooting
env | grep ^INPUT_ || echo "No INPUT_ variables found"

# Define important paths
CONFIG_FILE="/opt/uds/configs/action-config.json"
SSH_KEY_FILE="/tmp/ssh_key"

# Access variables directly with proper escaping for hyphenated names
# Escape the hyphen properly in shell variable names
APP_NAME="${INPUT_APP_NAME}"
# If not found with underscore, try with direct name
if [ -z "$APP_NAME" ]; then
  APP_NAME=$(printenv 'INPUT_APP-NAME')
fi

HOST="${INPUT_HOST}"
USERNAME="${INPUT_USERNAME}"

# For SSH key, directly access the raw variable
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

# Set up SSH key with focused approach to fix libcrypto error
if [ -n "$SSH_KEY" ]; then
  log "Setting up SSH key..."
  
  # Create SSH directory if it doesn't exist
  mkdir -p ~/.ssh
  chmod 700 ~/.ssh
  
  # Write key directly without any processing
  echo "$SSH_KEY" > ~/.ssh/id_rsa
  chmod 600 ~/.ssh/id_rsa
  
  # Configure SSH to use this key and bypass strict host checking
  cat > ~/.ssh/config << EOF
Host *
  StrictHostKeyChecking no
  UserKnownHostsFile=/dev/null
  IdentityFile ~/.ssh/id_rsa
EOF
  chmod 600 ~/.ssh/config
  
  # Use the fixed path for SSH operations
  SSH_KEY_FILE=~/.ssh/id_rsa
else
  log "Error: ssh-key is required"
  exit 1
fi

# Create config file from direct inputs
log "Generating configuration file from inputs..."
cat > "$CONFIG_FILE" << EOF
{
  "command": "${INPUT_COMMAND:-deploy}",
  "app_name": "${APP_NAME}",
  "image": "${INPUT_IMAGE}",
  "tag": "${INPUT_TAG:-latest}",
  "domain": "${INPUT_DOMAIN}",
  "route_type": "${INPUT_ROUTE-TYPE:-path}",
  "route": "${INPUT_ROUTE}",
  "port": "${INPUT_PORT:-3000}",
  "ssl": ${INPUT_SSL:-true},
  "ssl_email": "${INPUT_SSL-EMAIL}",
  "volumes": "${INPUT_VOLUMES}",
  "env_vars": ${INPUT_ENV-VARS:-{}},
  "persistent": ${INPUT_PERSISTENT:-false},
  "compose_file": "${INPUT_COMPOSE-FILE}",
  "use_profiles": ${INPUT_USE-PROFILES:-true},
  "extra_hosts": "${INPUT_EXTRA-HOSTS}",
  "health_check": "${INPUT_HEALTH-CHECK:-/health}",
  "health_check_timeout": ${INPUT_HEALTH-CHECK-TIMEOUT:-60}",
  "health_check_type": "${INPUT_HEALTH-CHECK-TYPE:-auto}",
  "health_check_command": "${INPUT_HEALTH-CHECK-COMMAND}",
  "port_auto_assign": ${INPUT_PORT-AUTO-ASSIGN:-true},
  "version_tracking": ${INPUT_VERSION-TRACKING:-true},
  "pg_migration_enabled": ${INPUT_PG-MIGRATION-ENABLED:-false},
  "pg_connection_string": "${INPUT_PG-CONNECTION-STRING}",
  "pg_backup_enabled": ${INPUT_PG-BACKUP-ENABLED:-true},
  "pg_migration_script": "${INPUT_PG-MIGRATION-SCRIPT}",
  "telegram_enabled": ${INPUT_TELEGRAM-ENABLED:-false},
  "telegram_bot_token": "${INPUT_TELEGRAM-BOT-TOKEN}",
  "telegram_chat_id": "${INPUT_TELEGRAM-CHAT-ID}",
  "telegram_notify_level": "${INPUT_TELEGRAM-NOTIFY-LEVEL:-info}",
  "telegram_include_logs": ${INPUT_TELEGRAM-INCLUDE-LOGS:-true},
  "max_log_lines": ${INPUT_MAX-LOG-LINES:-100},
  "plugins": "${INPUT_PLUGINS}"
}
EOF

# Prepare remote deployment command
log "Preparing remote deployment command..."
DEPLOY_CMD=""
WORKING_DIR="${INPUT_WORKING_DIR:-/opt/uds}"

# Handle different commands
case "${INPUT_COMMAND:-deploy}" in
  setup)
    DEPLOY_CMD="bash -c 'mkdir -p $WORKING_DIR && cat > $WORKING_DIR/config.json' && cd $WORKING_DIR && ./uds-setup.sh --config=config.json"
    ;;
  cleanup)
    DEPLOY_CMD="bash -c 'mkdir -p $WORKING_DIR && cat > $WORKING_DIR/config.json' && cd $WORKING_DIR && ./uds-cleanup.sh --config=config.json"
    ;;
  *)
    DEPLOY_CMD="bash -c 'mkdir -p $WORKING_DIR && cat > $WORKING_DIR/config.json' && cd $WORKING_DIR && ./uds-deploy.sh --config=config.json"
    ;;
esac

# Execute deployment via SSH using the configured SSH client
log "Executing deployment via SSH..."
ssh "$USERNAME@$HOST" "$DEPLOY_CMD" < "$CONFIG_FILE"

# Clean up
rm -f "$SSH_KEY_FILE"

log "UDS Docker Action completed successfully"
