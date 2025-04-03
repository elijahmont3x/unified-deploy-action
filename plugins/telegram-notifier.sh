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
  uds_register_plugin_arg "telegram_notifier" "TELEGRAM_MAX_RETRIES" "3"
  uds_register_plugin_arg "telegram_notifier" "TELEGRAM_RETRY_DELAY" "5"
  uds_register_plugin_arg "telegram_notifier" "TELEGRAM_CONNECTION_TIMEOUT" "10"
  uds_register_plugin_arg "telegram_notifier" "TELEGRAM_DISABLE_NOTIFICATION" "false"
  uds_register_plugin_arg "telegram_notifier" "TELEGRAM_WEBHOOK_URL" ""
  
  # Register plugin hooks
  uds_register_plugin_hook "telegram_notifier" "pre_deploy" "plugin_telegram_notify_deploy_start"
  uds_register_plugin_hook "telegram_notifier" "post_deploy" "plugin_telegram_notify_deploy_success"
  uds_register_plugin_hook "telegram_notifier" "health_check_failed" "plugin_telegram_notify_health_check_failed"
  uds_register_plugin_hook "telegram_notifier" "post_cutover" "plugin_telegram_notify_cutover"
  uds_register_plugin_hook "telegram_notifier" "post_cleanup" "plugin_telegram_notify_cleanup"
  uds_register_plugin_hook "telegram_notifier" "post_rollback" "plugin_telegram_notify_rollback"
}

# Activate the plugin
plugin_activate_telegram_notifier() {
  uds_log "Activating Telegram Notifier plugin" "debug"
  
  # Validate required configuration
  if [ "${TELEGRAM_ENABLED}" = "true" ]; then
    if [ -z "${TELEGRAM_BOT_TOKEN}" ]; then
      uds_log "Telegram notifications enabled but missing bot token" "warning"
      TELEGRAM_ENABLED="false"
      return 0
    fi
    
    if [ -z "${TELEGRAM_CHAT_ID}" ] && [ -z "${TELEGRAM_WEBHOOK_URL}" ]; then
      uds_log "Telegram notifications enabled but missing chat ID or webhook URL" "warning"
      TELEGRAM_ENABLED="false"
      return 0
    fi
    
    uds_log "Telegram notifications enabled" "info"
    
    # Test the connection
    plugin_telegram_test_connection
  fi
}

# Test the Telegram connection
plugin_telegram_test_connection() {
  if [ "${TELEGRAM_ENABLED}" != "true" ]; then
    return 0
  fi
  
  uds_log "Testing Telegram connection" "debug"
  
  # Create temporary file for error output
  local tmp_error=$(mktemp)
  
  # Skip webhook test if using chat ID
  if [ -n "${TELEGRAM_CHAT_ID}" ]; then
    # Use curl to test the connection
    local test_result=$(curl -s -X POST \
      "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getMe" \
      -m "${TELEGRAM_CONNECTION_TIMEOUT}" \
      -w "%{http_code}" \
      2>"$tmp_error")
    
    # Check the result
    if [ "$test_result" = "200" ]; then
      uds_log "Telegram connection test successful" "debug"
    else
      local error_msg=$(cat "$tmp_error")
      uds_log "Telegram connection test failed: $error_msg (HTTP code: $test_result)" "warning"
      
      # Disable the plugin if connection test fails
      TELEGRAM_ENABLED="false"
    fi
  elif [ -n "${TELEGRAM_WEBHOOK_URL}" ]; then
    # Test webhook URL with a minimal payload
    local test_result=$(curl -s -X POST \
      "${TELEGRAM_WEBHOOK_URL}" \
      -H "Content-Type: application/json" \
      -d '{"text":"UDS Telegram notifier test message"}' \
      -m "${TELEGRAM_CONNECTION_TIMEOUT}" \
      -w "%{http_code}" \
      2>"$tmp_error")
    
    # Check the result
    if [ "${test_result:0:1}" = "2" ]; then
      uds_log "Telegram webhook test successful" "debug"
    else
      local error_msg=$(cat "$tmp_error")
      uds_log "Telegram webhook test failed: $error_msg (HTTP code: $test_result)" "warning"
      
      # Disable the plugin if connection test fails
      TELEGRAM_ENABLED="false"
    fi
  fi
  
  rm -f "$tmp_error"
  return 0
}

# Format a message for Telegram
plugin_telegram_format_message() {
  local app_name="$1"
  local message="$2"
  local level="${3:-info}"
  local version="${4:-unknown}"
  
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
  
  # Format message with emoji, timestamp, app name and version
  local timestamp=$(date +"%Y-%m-%d %H:%M:%S")
  local hostname=$(hostname)
  local formatted_message="${emoji} *${app_name}* (${version}) at ${timestamp}\n\n${message}\n\nHost: \`${hostname}\`"
  
  # Sanitize the message to protect sensitive data
  local sanitized_message=$(uds_sanitize_env_vars "$formatted_message")
  
  echo "$sanitized_message"
}

# Send a message to Telegram with retry logic
plugin_telegram_send_message() {
  local message="$1"
  local level="${2:-info}"
  local version="${TAG:-latest}"
  
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
  
  # Format the message
  local formatted_message=$(plugin_telegram_format_message "$APP_NAME" "$message" "$level" "$version")
  
  # Determine whether to use Telegram API or webhook
  if [ -n "${TELEGRAM_CHAT_ID}" ]; then
    # Send via Telegram API
    plugin_telegram_send_api_message "$formatted_message" "$level"
  elif [ -n "${TELEGRAM_WEBHOOK_URL}" ]; then
    # Send via webhook
    plugin_telegram_send_webhook_message "$formatted_message" "$level"
  else
    uds_log "No Telegram chat ID or webhook URL configured" "warning"
    return 1
  fi
  
  return $?
}

# Send a message via Telegram API
plugin_telegram_send_api_message() {
  local formatted_message="$1"
  local level="$2"
  
  # Create temporary file for error output
  local tmp_error=$(mktemp)
  local tmp_response=$(mktemp)
  
  # Determine disable notification flag
  local disable_notification="false"
  if [ "${TELEGRAM_DISABLE_NOTIFICATION}" = "true" ] || [ "$level" = "debug" ] || [ "$level" = "info" ]; then
    disable_notification="true"
  fi
  
  # Initialize retry counter
  local retry_count=0
  local max_retries=${TELEGRAM_MAX_RETRIES}
  local retry_delay=${TELEGRAM_RETRY_DELAY}
  
  while [ $retry_count -lt $max_retries ]; do
    # Use curl to send the message with better error handling
    local http_code=$(curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
      -d "chat_id=${TELEGRAM_CHAT_ID}" \
      -d "text=${formatted_message}" \
      -d "parse_mode=Markdown" \
      -d "disable_notification=${disable_notification}" \
      -m ${TELEGRAM_CONNECTION_TIMEOUT} \
      -w "%{http_code}" \
      -o "$tmp_response" \
      2>"$tmp_error")
    
    # Check if the request was successful
    if [ "$http_code" = "200" ]; then
      rm -f "$tmp_error" "$tmp_response"
      return 0
    fi
    
    # Handle errors
    local error_msg=$(cat "$tmp_error")
    local api_error=$(cat "$tmp_response" | grep -o '"description":"[^"]*"' | cut -d'"' -f4)
    
    if [ -n "$api_error" ]; then
      error_msg="API error: $api_error"
    fi
    
    uds_log "Failed to send Telegram message (attempt $((retry_count+1))/$max_retries): $error_msg (HTTP code: $http_code)" "warning"
    
    # Check if we should retry
    if [ $retry_count -lt $((max_retries-1)) ]; then
      uds_log "Retrying in $retry_delay seconds..." "debug"
      sleep $retry_delay
      
      # Exponential backoff for retries
      retry_delay=$((retry_delay * 2))
    fi
    
    retry_count=$((retry_count+1))
  done
  
  rm -f "$tmp_error" "$tmp_response"
  uds_log "Failed to send Telegram message after $max_retries attempts" "error"
  return 1
}

# Send a message via webhook
plugin_telegram_send_webhook_message() {
  local formatted_message="$1"
  local level="$2"
  
  # Create temporary file for error output
  local tmp_error=$(mktemp)
  local tmp_response=$(mktemp)
  
  # Create webhook payload
  local payload=$(cat << EOF
{
  "text": "$formatted_message",
  "level": "$level",
  "app_name": "$APP_NAME",
  "version": "${TAG:-latest}",
  "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
}
EOF
)
  
  # Initialize retry counter
  local retry_count=0
  local max_retries=${TELEGRAM_MAX_RETRIES}
  local retry_delay=${TELEGRAM_RETRY_DELAY}
  
  while [ $retry_count -lt $max_retries ]; do
    # Use curl to send the webhook
    local http_code=$(curl -s -X POST "${TELEGRAM_WEBHOOK_URL}" \
      -H "Content-Type: application/json" \
      -d "$payload" \
      -m ${TELEGRAM_CONNECTION_TIMEOUT} \
      -w "%{http_code}" \
      -o "$tmp_response" \
      2>"$tmp_error")
    
    # Check if the request was successful
    if [[ "${http_code:0:1}" = "2" ]]; then
      rm -f "$tmp_error" "$tmp_response"
      return 0
    fi
    
    # Handle errors
    local error_msg=$(cat "$tmp_error")
    
    uds_log "Failed to send webhook message (attempt $((retry_count+1))/$max_retries): $error_msg (HTTP code: $http_code)" "warning"
    
    # Check if we should retry
    if [ $retry_count -lt $((max_retries-1)) ]; then
      uds_log "Retrying in $retry_delay seconds..." "debug"
      sleep $retry_delay
      
      # Exponential backoff for retries
      retry_delay=$((retry_delay * 2))
    fi
    
    retry_count=$((retry_count+1))
  done
  
  rm -f "$tmp_error" "$tmp_response"
  uds_log "Failed to send webhook message after $max_retries attempts" "error"
  return 1
}

# Collect container logs for notification
plugin_telegram_collect_logs() {
  local app_name="$1"
  local max_lines="${2:-10}"
  
  local container_name="${app_name}-app"
  local logs=""
  
  # Check if container exists
  if docker ps -a -q --filter "name=$container_name" | grep -q .; then
    logs=$(docker logs --tail="$max_lines" "$container_name" 2>&1 || echo "No logs available")
  else
    logs="Container not found"
  fi
  
  echo "$logs"
}

# Notification hooks
plugin_telegram_notify_deploy_start() {
  local app_name="$1"
  local message="🚀 Deployment started for version ${TAG:-latest}"
  
  if [ -n "$IMAGE" ]; then
    message="${message}\nImage: \`${IMAGE}\`"
  fi
  
  plugin_telegram_send_message "$message" "info"
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
  
  # Build the message
  local message="🎉 Deployment completed successfully!\n"
  message="${message}• Application is available at: [${access_url}](${access_url})\n"
  message="${message}• Image: \`${IMAGE}:${TAG}\`\n"
  message="${message}• Deployment time: $(date "+%Y-%m-%d %H:%M:%S")\n"
  
  # Add health check info if available
  if [ -n "$HEALTH_CHECK" ] && [ "$HEALTH_CHECK" != "none" ] && [ "$HEALTH_CHECK" != "disabled" ]; then
    message="${message}• Health Check: \`${HEALTH_CHECK}\`\n"
  fi
  
  # Include a container ID for traceability
  local container_id=$(docker ps -q --filter "name=${app_name}-app" | head -n1)
  if [ -n "$container_id" ]; then
    message="${message}• Container ID: \`${container_id:0:12}\`"
  fi
  
  plugin_telegram_send_message "$message" "success"
  return 0
}

plugin_telegram_notify_health_check_failed() {
  local app_name="$1"
  local app_dir="$2"
  
  local message="❌ Health check failed for deployment\n"
  message="${message}• Image: \`${IMAGE}:${TAG}\`\n"
  message="${message}• Health Check: \`${HEALTH_CHECK}\`\n"
  
  # Include container status if available
  local container_name="${app_name}-app"
  if docker ps -a -q --filter "name=$container_name" | grep -q .; then
    local container_status=$(docker inspect --format='{{.State.Status}}' "$container_name" 2>/dev/null)
    local exit_code=$(docker inspect --format='{{.State.ExitCode}}' "$container_name" 2>/dev/null)
    
    message="${message}• Container Status: \`${container_status}\`\n"
    
    if [ "$container_status" = "exited" ] && [ "$exit_code" != "0" ]; then
      message="${message}• Exit Code: \`${exit_code}\`\n"
    fi
  fi
  
  # Include logs if enabled
  if [ "${TELEGRAM_INCLUDE_LOGS}" = "true" ]; then
    local logs=$(plugin_telegram_collect_logs "$app_name" "${MAX_LOG_LINES:-20}")
    message="${message}\n*Last logs:*\n\`\`\`\n${logs}\n\`\`\`"
  fi
  
  plugin_telegram_send_message "$message" "error"
  return 0
}

plugin_telegram_notify_cutover() {
  local app_name="$1"
  
  # Build the message
  local message="🔄 Cutover completed successfully\n"
  message="${message}• New version is now live: \`${TAG:-latest}\`"
  
  plugin_telegram_send_message "$message" "info"
  return 0
}

plugin_telegram_notify_cleanup() {
  local app_name="$1"
  
  # Build the message
  local message="🧹 Cleanup completed successfully\n"
  message="${message}• Application: \`${app_name}\`\n"
  message="${message}• All resources have been cleaned up"
  
  plugin_telegram_send_message "$message" "info"
  return 0
}

plugin_telegram_notify_rollback() {
  local app_name="$1"
  local app_dir="$2"
  
  # Get info about previous version
  local prev_version=""
  local service_data=$(uds_get_service "$app_name" 2>/dev/null)
  
  if [ -n "$service_data" ]; then
    local version_history=$(echo "$service_data" | jq -r '.version_history // []')
    if [ "$version_history" != "[]" ]; then
      prev_version=$(echo "$version_history" | jq -r 'if length > 0 then .[length-1].tag else "unknown" end')
    fi
  fi
  
  # Build the message
  local message="⚠️ Deployment failed - Rolled back to previous version\n"
  
  if [ -n "$prev_version" ] && [ "$prev_version" != "unknown" ]; then
    message="${message}• Rolled back to version: \`${prev_version}\`\n"
  else
    message="${message}• Rollback completed\n"
  fi
  
  message="${message}• Failed version: \`${TAG:-latest}\`\n"
  message="${message}• Rollback time: $(date "+%Y-%m-%d %H:%M:%S")"
  
  # Include logs if enabled
  if [ "${TELEGRAM_INCLUDE_LOGS}" = "true" ]; then
    local logs=$(plugin_telegram_collect_logs "$app_name" "${MAX_LOG_LINES:-10}")
    message="${message}\n\n*Last logs before rollback:*\n\`\`\`\n${logs}\n\`\`\`"
  fi
  
  plugin_telegram_send_message "$message" "warning"
  return 0
}