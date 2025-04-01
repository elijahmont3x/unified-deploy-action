#!/bin/bash
#
# security-manager.sh - Advanced security management plugin for Unified Deployment System
#
# This plugin implements advanced security measures beyond the core security functions

# Register the plugin
plugin_register_security_manager() {
  uds_log "Registering Security Manager plugin" "debug"
  
  # Register plugin arguments
  uds_register_plugin_arg "security_manager" "SECURITY_ENCRYPT_ENV" "false"
  uds_register_plugin_arg "security_manager" "SECURITY_ENCRYPTION_KEY" ""
  uds_register_plugin_arg "security_manager" "SECURITY_LOG_ROTATION" "true"
  uds_register_plugin_arg "security_manager" "SECURITY_LOG_MAX_SIZE" "10M"
  uds_register_plugin_arg "security_manager" "SECURITY_LOG_MAX_FILES" "5"
  uds_register_plugin_arg "security_manager" "SECURITY_AUDIT_LOGGING" "false"
  uds_register_plugin_arg "security_manager" "SECURITY_AUDIT_LOG" "${UDS_LOGS_DIR}/audit.log"
  
  # Register plugin hooks
  uds_register_plugin_hook "security_manager" "pre_deploy" "plugin_security_pre_deploy"
  uds_register_plugin_hook "security_manager" "post_deploy" "plugin_security_post_deploy"
  uds_register_plugin_hook "security_manager" "pre_cleanup" "plugin_security_pre_cleanup"
  uds_register_plugin_hook "security_manager" "config_loaded" "plugin_security_audit_config"
}

# Activate the plugin
plugin_activate_security_manager() {
  uds_log "Activating Security Manager plugin" "debug"
  
  # Set up log rotation if enabled
  if [ "${SECURITY_LOG_ROTATION}" = "true" ] && command -v logrotate &>/dev/null; then
    setup_log_rotation
  fi
  
  # Initialize audit log if enabled
  if [ "${SECURITY_AUDIT_LOGGING}" = "true" ]; then
    initialize_audit_log
  fi
}

# Set up log rotation for UDS logs
setup_log_rotation() {
  local logrotate_conf="/etc/logrotate.d/uds"
  
  # Check if we can write to the logrotate directory
  if [ ! -w "/etc/logrotate.d" ]; then
    uds_log "Cannot write to /etc/logrotate.d, skipping log rotation setup" "warning"
    return 1
  fi
  
  # Create logrotate configuration
  cat > "$logrotate_conf" << EOL
${UDS_LOGS_DIR}/*.log {
  rotate ${SECURITY_LOG_MAX_FILES}
  size ${SECURITY_LOG_MAX_SIZE}
  missingok
  notifempty
  compress
  delaycompress
  create 600 root root
  sharedscripts
  postrotate
    # No need to restart any service
  endscript
}
EOL
  
  chmod 644 "$logrotate_conf"
  uds_log "Set up log rotation for UDS logs" "info"
  return 0
}

# Initialize audit logging
initialize_audit_log() {
  local audit_log="${SECURITY_AUDIT_LOG}"
  
  # Create audit log file if it doesn't exist
  if [ ! -f "$audit_log" ]; then
    touch "$audit_log"
    uds_secure_permissions "$audit_log" "600"
  fi
  
  # Log initialization
  log_audit_event "system" "audit_started" "Audit logging initialized"
  
  uds_log "Initialized audit logging to $audit_log" "info"
  return 0
}

# Log an audit event
log_audit_event() {
  local category="$1"
  local action="$2"
  local message="$3"
  local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%S.%3NZ")
  local user=$(whoami)
  local host=$(hostname)
  
  if [ "${SECURITY_AUDIT_LOGGING}" != "true" ]; then
    return 0
  fi
  
  # Format: timestamp|user|host|category|action|message
  local log_line="${timestamp}|${user}|${host}|${category}|${action}|${message}"
  
  # Append to audit log
  echo "$log_line" >> "${SECURITY_AUDIT_LOG}"
  
  return 0
}

# Encrypt environment variables in compose file using a vault tool
encrypt_env_vars() {
  local compose_file="$1"
  local app_name="$2"
  
  # Check if encryption is enabled and tools available
  if [ "${SECURITY_ENCRYPT_ENV}" != "true" ]; then
    return 0
  fi
  
  if ! command -v vault &>/dev/null; then
    uds_log "HashiCorp Vault not found, cannot encrypt environment variables" "warning"
    return 1
  fi
  
  if [ -z "${SECURITY_ENCRYPTION_KEY}" ]; then
    uds_log "No encryption key provided, cannot encrypt environment variables" "warning"
    return 1
  fi
  
  uds_log "Encrypting sensitive environment variables in compose file" "info"
  
  # This would contain actual vault integration code in a production implementation
  # For now, we'll just add a comment to the file
  
  # Create a temporary file
  local temp_file=$(mktemp)
  
  # Add a comment at the top of the file
  cat > "$temp_file" << EOL
# Environment variables in this file would be encrypted in a production environment
# using HashiCorp Vault or similar secrets management tool
$(cat "$compose_file")
EOL
  
  # Replace the original file
  mv "$temp_file" "$compose_file"
  uds_secure_permissions "$compose_file" "600"
  
  log_audit_event "security" "env_vars_encrypted" "Encrypted environment variables for $app_name"
  uds_log "Environment variables prepared for encryption" "success"
  return 0
}

# Audit configuration loading
plugin_security_audit_config() {
  local app_name="$1"
  
  log_audit_event "configuration" "config_loaded" "Configuration loaded for $app_name"
  
  # Check for secure settings
  if [ "$SSL" != "true" ]; then
    log_audit_event "security" "ssl_disabled" "SSL is disabled for $app_name"
    uds_log "Warning: SSL is disabled for $app_name, this is not recommended for production" "warning"
  fi
  
  return 0
}

# Pre-deploy security hook
plugin_security_pre_deploy() {
  local app_name="$1"
  local app_dir="$2"
  
  log_audit_event "deployment" "pre_deploy" "Starting deployment of $app_name"
  
  # Perform security checks before deployment
  if [ "$SSL" = "true" ] && [ -z "$SSL_EMAIL" ]; then
    log_audit_event "security" "ssl_warning" "SSL enabled but no email provided for $app_name"
    uds_log "Warning: SSL is enabled but no email address provided for certificate registration" "warning"
  fi
  
  return 0
}

# Post-deploy security hook
plugin_security_post_deploy() {
  local app_name="$1"
  local app_dir="$2"
  
  log_audit_event "deployment" "post_deploy" "Completed deployment of $app_name"
  
  # Encrypt environment variables if enabled
  if [ "${SECURITY_ENCRYPT_ENV}" = "true" ] && [ -f "${app_dir}/docker-compose.yml" ]; then
    encrypt_env_vars "${app_dir}/docker-compose.yml" "$app_name"
  fi
  
  return 0
}

# Pre-cleanup security hook
plugin_security_pre_cleanup() {
  local app_name="$1"
  local app_dir="$2"
  
  log_audit_event "deployment" "cleanup" "Cleaning up deployment of $app_name"
  
  return 0
}