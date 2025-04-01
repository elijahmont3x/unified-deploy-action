#!/bin/bash
set -e

# Function to log with timestamp
log() {
  echo "$(date "+%Y-%m-%d %H:%M:%S") $1"
}

log "UDS Docker Action started"

# Normalize input parameters - convert all INPUT_ variables 
# from GitHub Actions hyphenated format to proper variables
declare -A params
for var in $(env | grep ^INPUT_ | cut -d= -f1); do
  # Convert INPUT_NAME-WITH-HYPHENS to NAME_WITH-HYPHENS
  name=$(echo "$var" | sed 's/^INPUT_//')
  # Convert hyphens to underscores for shell variable compliance
  clean_name=$(echo "$name" | tr '-' '_')
  # Get the value
  eval "value=\${$var}"
  # Store normalized name and value
  params["$clean_name"]="$value"
  # Export for other scripts
  export "$clean_name"="$value"
done

# Get key parameters with proper fallbacks
CONFIG_FILE="/opt/uds/configs/action-config.json"
SSH_KEY_FILE="/tmp/ssh_key"
COMMAND="${params[COMMAND]:-deploy}"
APP_NAME="${params[APP_NAME]}"
HOST="${params[HOST]}"
USERNAME="${params[USERNAME]}"

# --- Debug Block Start ---
log "DEBUG: APP_NAME='${APP_NAME}', HOST='${HOST}', USERNAME='${USERNAME}', SSH_KEY length=${#params[SSH_KEY]}"
# --- Debug Block End ---

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

# Set up SSH key using printf to preserve newlines
if [ -n "${params[SSH_KEY]}" ]; then
  printf '%s\n' "${params[SSH_KEY]}" > "$SSH_KEY_FILE"
  chmod 600 "$SSH_KEY_FILE"
else
  log "Error: ssh-key is required"
  exit 1
fi

# Create config file from inputs
log "Generating configuration file from inputs..."
cat > "$CONFIG_FILE" << EOF
{
  "command": "$COMMAND",
  "app_name": "$APP_NAME",
  "image": "${params[IMAGE]}",
  "tag": "${params[TAG]:-latest}",
  "domain": "${params[DOMAIN]}",
  "route_type": "${params[ROUTE_TYPE]:-path}",
  "route": "${params[ROUTE]}",
  "port": "${params[PORT]:-3000}",
  "ssl": ${params[SSL]:-true},
  "ssl_email": "${params[SSL_EMAIL]}",
  "volumes": "${params[VOLUMES]}",
  "env_vars": ${params[ENV_VARS]:-{}},
  "persistent": ${params[PERSISTENT]:-false},
  "compose_file": "${params[COMPOSE_FILE]}",
  "use_profiles": ${params[USE_PROFILES]:-true},
  "extra_hosts": "${params[EXTRA_HOSTS]}",
  "health_check": "${params[HEALTH_CHECK]:-/health}",
  "health_check_timeout": ${params[HEALTH_CHECK_TIMEOUT]:-60},
  "health_check_type": "${params[HEALTH_CHECK_TYPE]:-auto}",
  "health_check_command": "${params[HEALTH_CHECK_COMMAND]}",
  "port_auto_assign": ${params[PORT_AUTO_ASSIGN]:-true},
  "version_tracking": ${params[VERSION_TRACKING]:-true},
  "pg_migration_enabled": ${params[PG_MIGRATION_ENABLED]:-false},
  "pg_connection_string": "${params[PG_CONNECTION_STRING]}",
  "pg_backup_enabled": ${params[PG_BACKUP_ENABLED]:-true},
  "pg_migration_script": "${params[PG_MIGRATION_SCRIPT]}",
  "telegram_enabled": ${params[TELEGRAM_ENABLED]:-false},
  "telegram_bot_token": "${params[TELEGRAM_BOT_TOKEN]}",
  "telegram_chat_id": "${params[TELEGRAM_CHAT_ID]}",
  "telegram_notify_level": "${params[TELEGRAM_NOTIFY_LEVEL]:-info}",
  "telegram_include_logs": ${params[TELEGRAM_INCLUDE_LOGS]:-true},
  "max_log_lines": ${params[MAX_LOG_LINES]:-100},
  "plugins": "${params[PLUGINS]}"
}
EOF

# Prepare remote deployment command
log "Preparing remote deployment command..."
DEPLOY_CMD=""
WORKING_DIR="${params[WORKING_DIR]:-/opt/uds}"

# Handle different commands
case "$COMMAND" in
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
