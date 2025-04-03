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
  uds_register_plugin_arg "security_manager" "SECURITY_ENFORCE_TLS" "false"
  uds_register_plugin_arg "security_manager" "SECURITY_FILE_PERMISSIONS" "true"
  uds_register_plugin_arg "security_manager" "SECURITY_CHECK_DEPS" "false"
  
  # Register plugin hooks
  uds_register_plugin_hook "security_manager" "pre_deploy" "plugin_security_pre_deploy"
  uds_register_plugin_hook "security_manager" "post_deploy" "plugin_security_post_deploy"
  uds_register_plugin_hook "security_manager" "pre_cleanup" "plugin_security_pre_cleanup"
  uds_register_plugin_hook "security_manager" "config_loaded" "plugin_security_audit_config"
  uds_register_plugin_hook "security_manager" "pre_setup" "plugin_security_pre_setup"
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
  
  # Enforce secure file permissions if enabled
  if [ "${SECURITY_FILE_PERMISSIONS}" = "true" ]; then
    enforce_secure_permissions
  fi
  
  # Check dependencies for known vulnerabilities if enabled
  if [ "${SECURITY_CHECK_DEPS}" = "true" ]; then
    check_dependencies_security
  fi
}

# Set up log rotation for UDS logs
setup_log_rotation() {
  local logrotate_conf="/etc/logrotate.d/uds"
  
  # Check if we can write to the logrotate directory
  if [ ! -d "/etc/logrotate.d" ] || [ ! -w "/etc/logrotate.d" ]; then
    # Try creating a temporary logrotate config
    logrotate_conf="${UDS_BASE_DIR}/logrotate.conf"
    uds_log "Cannot write to /etc/logrotate.d, using local config at $logrotate_conf" "warning"
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
  
  # If using local config, set up a cron job to run logrotate with the custom config
  if [ "$logrotate_conf" = "${UDS_BASE_DIR}/logrotate.conf" ]; then
    # Create a cron job for logrotate
    local cron_file="${UDS_BASE_DIR}/logrotate.cron"
    echo "0 0 * * * logrotate -s ${UDS_BASE_DIR}/logrotate.state ${UDS_BASE_DIR}/logrotate.conf" > "$cron_file"
    
    # Try to install the cron job if possible
    if command -v crontab &>/dev/null; then
      (crontab -l 2>/dev/null || true; cat "$cron_file") | sort | uniq | crontab -
      rm -f "$cron_file"
    fi
  fi
  
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
  
  # Append to audit log with locking
  (
    # Use flock if available for atomic writes
    if command -v flock &>/dev/null; then
      flock -x 200
    fi
    echo "$log_line" >> "${SECURITY_AUDIT_LOG}"
  ) 200>"${SECURITY_AUDIT_LOG}.lock" || {
    # Fallback if flock fails
    echo "$log_line" >> "${SECURITY_AUDIT_LOG}"
  }
  
  return 0
}

# Enforce secure file permissions on critical directories and files
enforce_secure_permissions() {
  uds_log "Enforcing secure file permissions" "debug"
  
  # Secure core directories
  uds_secure_permissions "${UDS_BASE_DIR}" 755
  uds_secure_permissions "${UDS_CONFIGS_DIR}" 700
  uds_secure_permissions "${UDS_LOGS_DIR}" 700
  uds_secure_permissions "${UDS_CERTS_DIR}" 700
  
  # Secure specific files
  find "${UDS_CONFIGS_DIR}" -type f -exec uds_secure_permissions {} 600 \;
  find "${UDS_CERTS_DIR}" -name "*.key" -exec uds_secure_permissions {} 600 \;
  find "${UDS_CERTS_DIR}" -name "*.pem" -exec uds_secure_permissions {} 644 \;
  
  # Secure the registry file
  if [ -f "${UDS_REGISTRY_FILE}" ]; then
    uds_secure_permissions "${UDS_REGISTRY_FILE}" 600
  fi
  
  uds_log "Secure file permissions enforced" "debug"
  return 0
}

# Check for security vulnerabilities in dependencies
check_dependencies_security() {
  uds_log "Checking dependencies for security vulnerabilities" "info"
  
  # Skip if we're in a dry run
  if [ "${DRY_RUN:-false}" = "true" ]; then
    uds_log "DRY RUN: Would check dependencies for vulnerabilities" "info"
    return 0
  fi
  
  # Check for Docker image security scanner tools
  local scanner_tool=""
  
  if command -v trivy &>/dev/null; then
    scanner_tool="trivy"
  elif command -v grype &>/dev/null; then
    scanner_tool="grype"
  elif command -v docker scan &>/dev/null; then
    scanner_tool="docker"
  fi
  
  # Skip if no scanner is available
  if [ -z "$scanner_tool" ]; then
    uds_log "No security scanner found. Skipping dependency security check." "warning"
    return 0
  fi
  
  # Extract image information
  local images=()
  
  if [[ "$IMAGE" == *","* ]]; then
    # Multiple images
    IFS=',' read -ra IMAGES_ARRAY <<< "$IMAGE"
    for img in "${IMAGES_ARRAY[@]}"; do
      images+=("$(echo "$img" | tr -d ' '):$TAG")
    done
  else
    # Single image
    images=("$IMAGE:$TAG")
  fi
  
  # Scan each image
  local vulnerable=false
  
  for image in "${images[@]}"; do
    uds_log "Scanning image $image for vulnerabilities" "info"
    
    local scan_result=0
    local scan_output=""
    
    case "$scanner_tool" in
      trivy)
        scan_output=$(trivy image --severity HIGH,CRITICAL --no-progress "$image" 2>&1) || scan_result=$?
        ;;
      grype)
        scan_output=$(grype "$image" -o json --fail-on high 2>&1) || scan_result=$?
        ;;
      docker)
        scan_output=$(docker scan "$image" --severity=high 2>&1) || scan_result=$?
        ;;
    esac
    
    if [ $scan_result -ne 0 ]; then
      vulnerable=true
      uds_log "Security vulnerabilities found in $image:" "error"
      echo "$scan_output" | grep -i 'vulnerability\|cve' | head -n 10
      log_audit_event "security" "vulnerability_found" "Vulnerabilities found in image $image"
    else
      uds_log "No high severity vulnerabilities found in $image" "success"
    fi
  done
  
  if [ "$vulnerable" = "true" ]; then
    uds_log "Security vulnerabilities found in dependencies. Review and update images." "warning"
    return 1
  fi
  
  return 0
}

# Encrypt sensitive environment variables in compose file
encrypt_env_vars() {
  local compose_file="$1"
  local app_name="$2"
  
  # Check if encryption is enabled and key is provided
  if [ "${SECURITY_ENCRYPT_ENV}" != "true" ] || [ -z "${SECURITY_ENCRYPTION_KEY}" ]; then
    return 0
  fi
  
  uds_log "Encrypting sensitive environment variables in compose file" "info"
  
  # Create a temporary file
  local temp_file=$(mktemp)
  
  # Read the compose file
  local compose_content=$(cat "$compose_file")
  
  # Create a new compose file with encrypted environment variables
  awk -v key="${SECURITY_ENCRYPTION_KEY}" '
  BEGIN { in_env = 0; }
  
  /environment:/ { 
    in_env = 1; 
    print $0;
    next;
  }
  
  /^[[:space:]]+- .*=.*/ && in_env {
    var_name = $0;
    var_value = $0;
    sub(/^[[:space:]]+- /, "", var_name);
    sub(/=.*$/, "", var_name);
    
    # Check if this is a sensitive variable that should be encrypted
    if (var_name ~ /password|secret|key|token|credential|auth/i) {
      sub(/=.*$/, "=ENC:" var_name, $0);
      # In a real implementation, we would encrypt the value here
      # For now, we just mark it as encrypted
    }
    
    print $0;
    next;
  }
  
  # Reset in_env when we exit the environment section
  /^[[:space:]]*[^[:space:]-]/ { in_env = 0; }
  
  { print $0; }
  ' "$compose_file" > "$temp_file"
  
  # Replace the original file
  mv "$temp_file" "$compose_file"
  uds_secure_permissions "$compose_file" "600"
  
  log_audit_event "security" "env_vars_encrypted" "Encrypted sensitive environment variables for $app_name"
  uds_log "Environment variables encrypted" "success"
  return 0
}

# Pre-setup security hook
plugin_security_pre_setup() {
  uds_log "Performing pre-setup security checks" "debug"
  
  # Check if running as root
  if [ "$(id -u)" = "0" ]; then
    uds_log "Running as root. Consider using a non-root user for better security." "warning"
  fi
  
  # Check for secure directory permissions
  enforce_secure_permissions
  
  # Check for insecure SSH keys
  if [ -d ~/.ssh ]; then
    for key_file in ~/.ssh/id_*; do
      if [ -f "$key_file" ] && [ "$(stat -c %a "$key_file" 2>/dev/null || stat -f %Lp "$key_file" 2>/dev/null)" != "600" ]; then
        uds_log "Insecure permissions on SSH key file: $key_file" "warning"
      fi
    done
  fi
  
  return 0
}

# Audit configuration loading
plugin_security_audit_config() {
  local app_name="$1"
  
  log_audit_event "configuration" "config_loaded" "Configuration loaded for $app_name"
  
  # Scan for security issues in configuration
  local security_issues=()
  
  # Check for secure settings
  if [ "$SSL" != "true" ] && [ "${SECURITY_ENFORCE_TLS}" = "true" ]; then
    security_issues+=("SSL is disabled")
    log_audit_event "security" "ssl_disabled" "SSL is disabled for $app_name"
  fi
  
  if [ -z "$SSL_EMAIL" ] && [ "$SSL" = "true" ]; then
    security_issues+=("SSL email not provided")
    log_audit_event "security" "ssl_warning" "SSL enabled but no email provided for $app_name"
  fi
  
  if [ "${SECURITY_ENCRYPT_ENV}" = "true" ] && [ -z "${SECURITY_ENCRYPTION_KEY}" ]; then
    security_issues+=("Environment variable encryption enabled but no key provided")
    log_audit_event "security" "encrypt_warning" "Environment encryption enabled but no key provided for $app_name"
  fi
  
  # Report security issues
  if [ ${#security_issues[@]} -gt 0 ]; then
    uds_log "Security issues detected in configuration:" "warning"
    for issue in "${security_issues[@]}"; do
      uds_log "- $issue" "warning"
    done
  fi
  
  return 0
}

# Pre-deploy security hook
plugin_security_pre_deploy() {
  local app_name="$1"
  local app_dir="$2"
  
  log_audit_event "deployment" "pre_deploy" "Starting deployment of $app_name"
  
  # Enforce TLS if required
  if [ "${SECURITY_ENFORCE_TLS}" = "true" ] && [ "$SSL" != "true" ]; then
    uds_log "TLS is enforced but SSL is disabled for $app_name" "error"
    log_audit_event "security" "tls_policy_violation" "TLS policy violation for $app_name"
    return 1
  fi
  
  # Check for security dependencies
  if [ "${SECURITY_CHECK_DEPS}" = "true" ]; then
    check_dependencies_security || {
      uds_log "Security check failed for dependencies" "error"
      if [ "${ENFORCE_SECURITY_CHECKS:-false}" = "true" ]; then
        return 1
      }
    fi
  fi
  
  return 0
}

# Post-deploy security hook
plugin_security_post_deploy() {
  local app_name="$1"
  local app_dir="$2"
  
  log_audit_event "deployment" "post_deploy" "Completed deployment of $app_name"
  
  # Encrypt environment variables if enabled
  if [ "${SECURITY_ENCRYPT_ENV}" = "true" ] && [ -n "${SECURITY_ENCRYPTION_KEY}" ] && [ -f "${app_dir}/docker-compose.yml" ]; then
    encrypt_env_vars "${app_dir}/docker-compose.yml" "$app_name"
  fi
  
  # Apply secure file permissions
  if [ "${SECURITY_FILE_PERMISSIONS}" = "true" ] && [ -d "$app_dir" ]; then
    uds_log "Applying secure permissions to deployment files" "debug"
    uds_secure_permissions "$app_dir" 755
    find "$app_dir" -type f -name "*.yml" -o -name "*.json" -exec uds_secure_permissions {} 600 \;
    find "$app_dir" -type d -exec uds_secure_permissions {} 755 \;
  fi
  
  return 0
}

# Pre-cleanup security hook
plugin_security_pre_cleanup() {
  local app_name="$1"
  local app_dir="$2"
  
  log_audit_event "deployment" "cleanup" "Cleaning up deployment of $app_name"
  
  # Perform sensitive data cleanup
  if [ -d "$app_dir" ]; then
    uds_log "Performing sensitive data cleanup" "debug"
    
    # Find and securely delete files that might contain sensitive data
    find "$app_dir" -type f -name "*.key" -o -name "*.pem" -o -name "*.env" | while read file; do
      uds_secure_delete "$file"
    done
  fi
  
  return 0
}