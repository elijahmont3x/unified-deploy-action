#!/bin/bash
set -e

# Function to log with timestamp
log() {
  echo "$(date "+%Y-%m-%d %H:%M:%S") $1"
}

log "UDS Docker Action started"

# Define important paths
CONFIG_FILE="/opt/uds/configs/action-config.json"
SSH_KEY_FILE="/tmp/ssh_key"

# Get variables directly from GitHub Actions environment
APP_NAME="${INPUT_APP_NAME}"
HOST="${INPUT_HOST}"
USERNAME="${INPUT_USERNAME}"
SSH_KEY="${INPUT_SSH_KEY}"

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

# Set up SSH key
if [ -n "$SSH_KEY" ]; then
  # Write key with exact formatting preserved
  echo "$SSH_KEY" > "$SSH_KEY_FILE"
  chmod 600 "$SSH_KEY_FILE"
else
  log "Error: ssh-key is required"
  exit 1
fi

# Create config file from direct inputs
log "Generating configuration file from inputs..."
cat > "$CONFIG_FILE" << EOF
{
  "command": "${INPUT_COMMAND:-deploy}",
  "app_name": "$APP_NAME",
  "image": "${INPUT_IMAGE}",
  "tag": "${INPUT_TAG:-latest}",
  "domain": "${INPUT_DOMAIN}",
  "route_type": "${INPUT_ROUTE_TYPE:-path}",
  "route": "${INPUT_ROUTE}",
  "port": "${INPUT_PORT:-3000}",
  "ssl": ${INPUT_SSL:-true},
  "ssl_email": "${INPUT_SSL_EMAIL}",
  "volumes": "${INPUT_VOLUMES}",
  "env_vars": ${INPUT_ENV_VARS:-{}},
  "persistent": ${INPUT_PERSISTENT:-false},
  "compose_file": "${INPUT_COMPOSE_FILE}",
  "use_profiles": ${INPUT_USE_PROFILES:-true},
  "extra_hosts": "${INPUT_EXTRA_HOSTS}",
  "health_check": "${INPUT_HEALTH_CHECK:-/health}",
  "health_check_timeout": "${INPUT_HEALTH_CHECK_TIMEOUT:-60}",
  "health_check_type": "${INPUT_HEALTH_CHECK_TYPE:-auto}",
  "health_check_command": "${INPUT_HEALTH_CHECK_COMMAND}",
  "port_auto_assign": ${INPUT_PORT_AUTO_ASSIGN:-true},
  "version_tracking": ${INPUT_VERSION_TRACKING:-true},
  "pg_migration_enabled": ${INPUT_PG_MIGRATION_ENABLED:-false},
  "pg_connection_string": "${INPUT_PG_CONNECTION_STRING}",
  "pg_backup_enabled": ${INPUT_PG_BACKUP_ENABLED:-true},
  "pg_migration_script": "${INPUT_PG_MIGRATION_SCRIPT}",
  "telegram_enabled": ${INPUT_TELEGRAM_ENABLED:-false},
  "telegram_bot_token": "${INPUT_TELEGRAM_BOT_TOKEN}",
  "telegram_chat_id": "${INPUT_TELEGRAM_CHAT_ID}",
  "telegram_notify_level": "${INPUT_TELEGRAM_NOTIFY_LEVEL:-info}",
  "telegram_include_logs": ${INPUT_TELEGRAM_INCLUDE_LOGS:-true},
  "max_log_lines": ${INPUT_MAX_LOG_LINES:-100},
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

# Execute deployment via SSH
log "Executing deployment via SSH..."
ssh -o StrictHostKeyChecking=no -i "$SSH_KEY_FILE" "$USERNAME@$HOST" "$DEPLOY_CMD" < "$CONFIG_FILE"

# Clean up
rm -f "$SSH_KEY_FILE"

log "UDS Docker Action completed successfully"
