#!/bin/bash
#
# telegram-notifier.sh - Telegram notification plugin for Unified Deployment System
#
# This plugin sends deployment notifications to Telegram

# Register the plugin
plugin_register_telegram_notifier() {
  uds_log "Registering Telegram Notifier plugin" "debug"
  
  # Register plugin arguments
  uds_register_plugin_arg "telegram_notifier" "TELEGRAM_ENABLED" "false"
  uds_register_plugin_arg "telegram_notifier" "TELEGRAM_BOT_TOKEN" ""
  uds_register_plugin_arg "telegram_notifier" "TELEGRAM_CHAT_ID" ""
  uds_register_plugin_arg "telegram_notifier" "TELEGRAM_NOTIFY_LEVEL" "info" # debug, info, warning, error
  uds_register_plugin_arg "telegram_notifier" "TELEGRAM_INCLUDE_LOGS" "true"
  
  # Register plugin hooks
  uds_register_plugin_hook "telegram_notifier" "pre_deploy" "plugin_telegram_notify_deploy_start"
  uds_register_plugin_hook "telegram_notifier" "post_deploy" "plugin_telegram_notify_deploy_success"
  uds_register_plugin_hook "telegram_notifier" "health_check_failed" "plugin_telegram_notify_health_check_failed"
  uds_register_plugin_hook "telegram_notifier" "post_cutover" "plugin_telegram_notify_cutover"
  uds_register_plugin_hook "telegram_notifier" "post_cleanup" "plugin_telegram_notify_cleanup"
}

# Activate the plugin
plugin_activate_telegram_notifier() {
  uds_log "Activating Telegram Notifier plugin" "debug"
  
  # Validate required configuration
  if [ "${TELEGRAM_ENABLED}" = "true" ]; then
    if [ -z "${TELEGRAM_BOT_TOKEN}" ] || [ -z "${TELEGRAM_CHAT_ID}" ]; then
      uds_log "Telegram notifications enabled but missing bot token or chat ID" "warning"
      TELEGRAM_ENABLED="false"
    else
      uds_log "Telegram notifications enabled" "info"
    fi
  fi
}

# Send a message to Telegram
plugin_telegram_send_message() {
  local message="$1"
  local level="${2:-info}"
  
  # Check if notifications are enabled and meet the minimum level
  if [ "${TELEGRAM_ENABLED}" != "true" ]; then
    return 0
  fi
  
  # Check notification level
  local levels=("debug" "info" "warning" "error")
  local current_level_index=1  # Default to info
  local min_level_index=1      # Default to info
  
  # Find the current level index
  for i in "${!levels[@]}"; do
    if [ "${levels[$i]}" = "$level" ]; then
      current_level_index=$i
    fi
    if [ "${levels[$i]}" = "${TELEGRAM_NOTIFY_LEVEL}" ]; then
      min_level_index=$i
    fi
  done
  
  # Skip if level is below minimum
  if [ $current_level_index -lt $min_level_index ]; then
    return 0
  fi
  
  # Add emoji based on level
  local emoji=""
  case "$level" in
    debug) emoji="🔍" ;;
    info) emoji="ℹ️" ;;
    warning) emoji="⚠️" ;;
    error) emoji="🚨" ;;
    success) emoji="✅" ;;
    *) emoji="ℹ️" ;;
  esac
  
  # Format message with emoji and app name
  local formatted_message="${emoji} *${APP_NAME}*: ${message}"
  
  # Sanitize the message to protect sensitive data
  local sanitized_message=$(uds_sanitize_env_vars "$formatted_message")
  
  # Send message to Telegram
  uds_log "Sending Telegram notification: $sanitized_message" "debug"
  
  # Create temporary file for error output
  local tmp_error=$(mktemp)
  
  # Use curl to send the message with better error handling
  curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    -d "chat_id=${TELEGRAM_CHAT_ID}" \
    -d "text=${sanitized_message}" \
    -d "parse_mode=Markdown" \
    -m 10 \
    -w "%{http_code}" \
    2>"$tmp_error" > /tmp/telegram_response
  
  local http_code=$(cat /tmp/telegram_response)
  
  if [ $? -ne 0 ] || [ "$http_code" != "200" ]; then
    local error_msg=$(cat "$tmp_error")
    local api_error=$(cat /tmp/telegram_response | grep -o '"description":"[^"]*"' | cut -d'"' -f4)
    
    if [ -n "$api_error" ]; then
      uds_log "Failed to send Telegram notification: API error - $api_error" "warning"
    else
      uds_log "Failed to send Telegram notification: $error_msg (HTTP code: $http_code)" "warning"
    fi
    
    rm -f "$tmp_error" /tmp/telegram_response
    return 1
  fi
  
  rm -f "$tmp_error" /tmp/telegram_response
  return 0
}

# Notification hooks
plugin_telegram_notify_deploy_start() {
  local app_name="$1"
  plugin_telegram_send_message "Deployment started for version ${TAG:-latest}" "info"
  return 0
}

plugin_telegram_notify_deploy_success() {
  local app_name="$1"
  local app_dir="$2"
  
  # Get deployment URL
  local url_scheme="http"
  if [ "$SSL" = "true" ]; then
    url_scheme="https"
  fi
  
  local access_url=""
  if [ "$ROUTE_TYPE" = "subdomain" ] && [ -n "$ROUTE" ]; then
    access_url="${url_scheme}://${ROUTE}.${DOMAIN}"
  elif [ "$ROUTE_TYPE" = "path" ] && [ -n "$ROUTE" ]; then
    access_url="${url_scheme}://${DOMAIN}/${ROUTE}"
  else
    access_url="${url_scheme}://${DOMAIN}"
  fi
  
  plugin_telegram_send_message "Deployment completed successfully!\nApplication is available at: ${access_url}" "success"
  return 0
}

plugin_telegram_notify_health_check_failed() {
  local app_name="$1"
  local app_dir="$2"
  
  local message="Health check failed for deployment"
  
  # Include logs if enabled
  if [ "${TELEGRAM_INCLUDE_LOGS}" = "true" ]; then
    local container_name="${app_name}-app"
    local logs=$(docker logs --tail=10 "$container_name" 2>&1 || echo "No logs available")
    message="${message}\n\nLast 10 log lines:\n\`\`\`\n${logs}\n\`\`\`"
  fi
  
  plugin_telegram_send_message "$message" "error"
  return 0
}

plugin_telegram_notify_cutover() {
  local app_name="$1"
  plugin_telegram_send_message "Cutover completed successfully" "info"
  return 0
}

plugin_telegram_notify_cleanup() {
  local app_name="$1"
  plugin_telegram_send_message "Cleanup completed successfully" "info"
  return 0
}