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

# Set up SSH with an extremely robust key handling approach
if [ -n "$SSH_KEY" ]; then
  log "Setting up SSH with robust key handling..."
  
  # Create SSH directory
  SSH_DIR="/tmp/.ssh"
  mkdir -p "$SSH_DIR"
  chmod 700 "$SSH_DIR"
  
  # Create a unique identifier for debugging
  KEY_ID=$(echo "$SSH_KEY" | md5sum | cut -d' ' -f1 | head -c 8)
  log "Processing SSH key (ID: $KEY_ID)"
  
  # Write key to a file, ensuring proper PEM format
  # Check if key begins with proper SSH key header
  if [[ "$SSH_KEY" == "-----BEGIN"* ]]; then
    log "Key appears to be in PEM format"
    echo "$SSH_KEY" > "$SSH_DIR/id_rsa"
  else
    log "Key doesn't appear to have proper headers, attempting to fix format"
    # Try to detect and fix common issues:
    # 1. Newlines might be escaped or missing
    echo "$SSH_KEY" | sed 's/\\n/\n/g' > "$SSH_DIR/id_rsa"
  fi
  
  chmod 600 "$SSH_DIR/id_rsa"
  
  # Validate the key
  if ! ssh-keygen -l -f "$SSH_DIR/id_rsa" &>/dev/null; then
    log "WARNING: SSH key appears invalid, will try alternative formats"
    
    # Try base64 decode in case it's encoded
    if command -v base64 &>/dev/null; then
      log "Attempting base64 decode of key"
      echo "$SSH_KEY" | base64 -d > "$SSH_DIR/id_rsa.base64" 2>/dev/null || true
      if [ -s "$SSH_DIR/id_rsa.base64" ] && ssh-keygen -l -f "$SSH_DIR/id_rsa.base64" &>/dev/null; then
        log "Base64 decoded key appears valid, using it"
        mv "$SSH_DIR/id_rsa.base64" "$SSH_DIR/id_rsa"
      else
        rm -f "$SSH_DIR/id_rsa.base64"
      fi
    fi

    # Last resort: Use the OpenSSH key directly with the ssh command
    echo "$SSH_KEY" > "$SSH_DIR/raw_key"
    chmod 600 "$SSH_DIR/raw_key"
  fi
  
  # Configure SSH client
  cat > "$SSH_DIR/config" << EOF
Host $HOST
  StrictHostKeyChecking no
  UserKnownHostsFile=/dev/null
  IdentityFile $SSH_DIR/id_rsa
  LogLevel DEBUG
EOF

  chmod 600 "$SSH_DIR/config"
  
  # Create direct command that skips ssh-agent
  SSH_COMMAND="ssh -v -F $SSH_DIR/config -i $SSH_DIR/id_rsa"
  
  # Show key details (without exposing the key) for debugging
  log "Key information:"
  ssh-keygen -l -f "$SSH_DIR/id_rsa" 2>&1 || echo "Could not parse key format"
else
  log "Error: ssh-key is required"
  exit 1
fi

# Create config file from direct inputs - fix environment variable substitution
log "Generating configuration file from inputs..."
cat > "$CONFIG_FILE" << EOF
{
  "command": "${INPUT_COMMAND:-deploy}",
  "app_name": "${APP_NAME}",
  "image": "${INPUT_IMAGE}",
  "tag": "${INPUT_TAG:-latest}",
  "domain": "$(printenv 'INPUT_DOMAIN' || echo '')",
  "route_type": "$(printenv 'INPUT_ROUTE-TYPE' || echo 'path')",
  "route": "$(printenv 'INPUT_ROUTE' || echo '')",
  "port": "${INPUT_PORT:-3000}",
  "ssl": ${INPUT_SSL:-true},
  "ssl_email": "$(printenv 'INPUT_SSL-EMAIL' || echo '')",
  "volumes": "${INPUT_VOLUMES}",
  "env_vars": $(printenv 'INPUT_ENV-VARS' || echo '{}'),
  "persistent": ${INPUT_PERSISTENT:-false},
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

# Validate JSON config before using it
if ! jq . "$CONFIG_FILE" > /dev/null 2>&1; then
  log "ERROR: Generated JSON config is invalid"
  jq . "$CONFIG_FILE" || cat "$CONFIG_FILE"
  exit 1
fi

# Prepare remote deployment command with improved script installation
log "Preparing remote deployment command..."
DEPLOY_CMD=""
WORKING_DIR="${INPUT_WORKING_DIR:-/opt/uds}"

# Improved installation script with better plugin handling
SETUP_CMD="if [ ! -f \"$WORKING_DIR/uds-deploy.sh\" ]; then"
SETUP_CMD+=" echo \"UDS scripts not found, installing...\";"
SETUP_CMD+=" mkdir -p $WORKING_DIR/scripts $WORKING_DIR/plugins;"
SETUP_CMD+=" curl -s -L https://github.com/elijahmont3x/unified-deploy-action/archive/refs/heads/master.tar.gz | tar xz -C /tmp;"
SETUP_CMD+=" cp -r /tmp/unified-deploy-action-master/scripts/* $WORKING_DIR/;"
# Ensure plugin directory structure is correct
SETUP_CMD+=" mkdir -p $WORKING_DIR/plugins;"
SETUP_CMD+=" cp -r /tmp/unified-deploy-action-master/plugins/* $WORKING_DIR/plugins/;"
# Make all scripts executable, including plugin scripts
SETUP_CMD+=" chmod +x $WORKING_DIR/*.sh;"
SETUP_CMD+=" chmod +x $WORKING_DIR/plugins/*.sh 2>/dev/null || true;"
SETUP_CMD+=" rm -rf /tmp/unified-deploy-action-master;"
SETUP_CMD+=" fi"

# Handle different commands
case "${INPUT_COMMAND:-deploy}" in
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

# Execute deployment via SSH using direct key authentication
log "Executing deployment via SSH... (using direct key authentication)"
$SSH_COMMAND "$USERNAME@$HOST" "$DEPLOY_CMD" < "$CONFIG_FILE"

# Clean up
rm -rf "$SSH_DIR"

log "UDS Docker Action completed successfully"
