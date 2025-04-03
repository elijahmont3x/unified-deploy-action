#!/bin/bash
#
# ssl-manager.sh - SSL Certificate management plugin for Unified Deployment System
#
# This plugin handles SSL certificate generation and renewal using Let's Encrypt

# Register the plugin
plugin_register_ssl_manager() {
  uds_log "Registering SSL Manager plugin" "debug"
  
  # Register plugin arguments
  uds_register_plugin_arg "ssl_manager" "SSL_STAGING" "false"
  uds_register_plugin_arg "ssl_manager" "SSL_RENEWAL_DAYS" "30"
  uds_register_plugin_arg "ssl_manager" "SSL_RSA_KEY_SIZE" "4096"
  uds_register_plugin_arg "ssl_manager" "SSL_WILDCARD" "false"
  uds_register_plugin_arg "ssl_manager" "SSL_DNS_PROVIDER" ""
  uds_register_plugin_arg "ssl_manager" "SSL_DNS_CREDENTIALS" ""
  
  # Register plugin hooks
  uds_register_plugin_hook "ssl_manager" "pre_deploy" "plugin_ssl_check"
  uds_register_plugin_hook "ssl_manager" "post_deploy" "plugin_ssl_finalize"
  
  # Check for certbot
  if ! command -v certbot &> /dev/null; then
    uds_log "Certbot not found, SSL plugin will use self-signed certificates only" "warning"
    uds_log "To install Certbot: apt-get update && apt-get install -y certbot" "info"
  fi
}

# Activate the plugin
plugin_activate_ssl_manager() {
  uds_log "Activating SSL Manager plugin" "debug"
  
  # Make sure the certs directory exists
  mkdir -p "${UDS_CERTS_DIR}"
  uds_secure_permissions "${UDS_CERTS_DIR}" 700
}

# Check SSL certificates before deployment
plugin_ssl_check() {
  local app_name="$1"
  
  if [ "$SSL" != "true" ]; then
    return 0
  fi
  
  if [ -z "$DOMAIN" ]; then
    uds_log "No domain specified, cannot set up SSL" "error"
    return 1
  }
  
  local server_name="$DOMAIN"
  # Check for wildcard domain request
  if [ "${SSL_WILDCARD:-false}" = "true" ] && [ "$ROUTE_TYPE" = "subdomain" ]; then
    server_name="*.${DOMAIN}"
    uds_log "Wildcard SSL certificate requested for $server_name" "info"
  elif [ "$ROUTE_TYPE" = "subdomain" ] && [ -n "$ROUTE" ]; then
    server_name="${ROUTE}.${DOMAIN}"
  fi
  
  uds_log "Checking SSL certificate for $server_name" "info"
  
  # Create certificate directory if it doesn't exist
  local cert_dir="${UDS_CERTS_DIR}/${server_name}"
  mkdir -p "$cert_dir"
  
  # Check if certificate exists and is valid
  if [ -f "${cert_dir}/fullchain.pem" ] && [ -f "${cert_dir}/privkey.pem" ]; then
    # Check certificate expiration
    if openssl x509 -checkend $((${SSL_RENEWAL_DAYS} * 86400)) -noout -in "${cert_dir}/fullchain.pem" &> /dev/null; then
      uds_log "SSL certificate for $server_name is valid" "info"
      return 0
    else
      uds_log "SSL certificate for $server_name is expiring soon or invalid" "warning"
    fi
  else
    uds_log "SSL certificate for $server_name not found" "info"
  fi
  
  # Certificate doesn't exist or is invalid/expiring, generate new one
  plugin_ssl_setup "$server_name" "$SSL_EMAIL" "$cert_dir"
  
  return $?
}

# Set up SSL certificate using Let's Encrypt or self-signed
plugin_ssl_setup() {
  local server_name="$1"
  local email="$2"
  local cert_dir="$3"
  
  uds_log "Setting up SSL certificate for $server_name" "info"
  
  # Create certificate directory if it doesn't exist
  mkdir -p "$cert_dir"
  
  # Check for wildcard certificate request
  local is_wildcard=false
  if [[ "$server_name" == \** ]]; then
    is_wildcard=true
  fi
  
  # Use Let's Encrypt if certbot is available and we have an email
  if command -v certbot &> /dev/null && [ -n "$email" ]; then
    uds_log "Using Let's Encrypt to obtain SSL certificate" "info"
    
    # Build certbot command
    local certbot_cmd="certbot certonly"
    
    # Wildcard certificates require DNS challenge
    if [ "$is_wildcard" = true ]; then
      if [ -z "${SSL_DNS_PROVIDER}" ]; then
        uds_log "Wildcard certificates require a DNS provider, falling back to self-signed" "warning"
        plugin_ssl_generate_self_signed "$server_name" "$cert_dir"
        return 0
      fi
      
      uds_log "Using DNS challenge for wildcard certificate" "info"
      certbot_cmd="${certbot_cmd} --dns-${SSL_DNS_PROVIDER}"
      
      # Add credentials if provided
      if [ -n "${SSL_DNS_CREDENTIALS}" ]; then
        # Create a secure credentials file
        local creds_file="/tmp/dns_credentials.ini"
        # Sanitize credentials before writing to file
        local sanitized_creds=$(echo "${SSL_DNS_CREDENTIALS}" | sed 's/\\\\/\\/g' | sed 's/\\"/"/g')
        echo "${sanitized_creds}" > "$creds_file"
        uds_secure_permissions "$creds_file" 600
        
        certbot_cmd="${certbot_cmd} --dns-${SSL_DNS_PROVIDER}-credentials $creds_file"
      fi
    else
      # For non-wildcard, use standalone
      certbot_cmd="${certbot_cmd} --standalone"
    fi
    
    # Add staging flag if enabled
    if [ "${SSL_STAGING}" = "true" ]; then
      certbot_cmd="${certbot_cmd} --staging"
    fi
    
    # Add email and domain
    certbot_cmd="${certbot_cmd} --agree-tos --non-interactive"
    certbot_cmd="${certbot_cmd} --email ${email} -d ${server_name}"
    
    # Add RSA key size
    certbot_cmd="${certbot_cmd} --rsa-key-size ${SSL_RSA_KEY_SIZE}"
    
    # For non-wildcard certs, need to stop web servers temporarily
    if [ "$is_wildcard" = false ]; then
      # Stop Nginx temporarily
      local nginx_was_running=false
      if docker ps -q --filter "name=nginx-proxy" | grep -q .; then
        nginx_was_running=true
        uds_log "Stopping Nginx temporarily for certificate validation" "info"
        docker stop nginx-proxy || true
      elif command -v nginx &> /dev/null && pgrep -x nginx > /dev/null; then
        nginx_was_running=true
        uds_log "Stopping Nginx service temporarily for certificate validation" "info"
        systemctl stop nginx || service nginx stop || true
      fi
    fi
    
    # Run certbot
    uds_log "Running: $certbot_cmd" "debug"
    local certbot_success=false
    if eval "$certbot_cmd"; then
      certbot_success=true
      
      # Get the path where Let's Encrypt saved the certificates
      local le_cert_path="/etc/letsencrypt/live/${server_name}"
      if [ ! -d "$le_cert_path" ]; then
        # Try to find the certificate directory in case domain name normalization was applied
        le_cert_path=$(find /etc/letsencrypt/live -name "*.pem" | grep -v README | head -n 1 | xargs dirname 2>/dev/null)
      fi
      
      if [ -d "$le_cert_path" ]; then
        # Copy certificates to our directory with proper permissions
        cp -L "${le_cert_path}/fullchain.pem" "${cert_dir}/fullchain.pem"
        cp -L "${le_cert_path}/privkey.pem" "${cert_dir}/privkey.pem"
        chmod 644 "${cert_dir}/fullchain.pem"
        chmod 600 "${cert_dir}/privkey.pem"
        
        uds_log "Let's Encrypt certificate obtained successfully" "success"
      else
        certbot_success=false
        uds_log "Failed to locate Let's Encrypt certificates" "error"
      fi
    fi
    
    # Clean up credentials file if it exists
    if [ -f "/tmp/dns_credentials.ini" ]; then
      uds_secure_delete "/tmp/dns_credentials.ini"
    fi
    
    # Restart Nginx if we stopped it
    if [ "$is_wildcard" = false ] && [ "$nginx_was_running" = true ]; then
      uds_log "Restarting Nginx" "info"
      if docker ps -a --filter "name=nginx-proxy" | grep -q .; then
        docker start nginx-proxy || true
      elif command -v nginx &> /dev/null; then
        systemctl start nginx || service nginx start || true
      fi
    fi
    
    # If Let's Encrypt failed, fall back to self-signed
    if [ "$certbot_success" = false ]; then
      uds_log "Failed to obtain Let's Encrypt certificate, falling back to self-signed" "warning"
      plugin_ssl_generate_self_signed "$server_name" "$cert_dir"
    fi
  else
    # Generate self-signed certificate
    plugin_ssl_generate_self_signed "$server_name" "$cert_dir"
  fi
  
  return 0
}

# Generate a self-signed certificate
plugin_ssl_generate_self_signed() {
  local server_name="$1"
  local cert_dir="$2"
  
  uds_log "Generating self-signed certificate for $server_name" "info"
  
  # Create directory if it doesn't exist
  mkdir -p "$cert_dir"
  
  # Determine if it's a wildcard certificate
  local subject_alt_name="DNS:${server_name}"
  if [[ "$server_name" == \** ]]; then
    # Add both wildcard and base domain as SANs
    local base_domain="${server_name#\*.}"
    subject_alt_name="DNS:${server_name},DNS:${base_domain}"
  fi
  
  # Create a temporary OpenSSL config for SAN support
  local ssl_config=$(mktemp)
  cat > "$ssl_config" << EOL
[ req ]
default_bits       = ${SSL_RSA_KEY_SIZE}
default_md         = sha256
prompt             = no
encrypt_key        = no
distinguished_name = req_dn
req_extensions     = req_ext

[ req_dn ]
CN = ${server_name}

[ req_ext ]
subjectAltName = ${subject_alt_name}
EOL
  
  # Generate self-signed certificate
  if openssl req -x509 -nodes -days 365 -newkey rsa:${SSL_RSA_KEY_SIZE} \
    -keyout "${cert_dir}/privkey.pem" \
    -out "${cert_dir}/fullchain.pem" \
    -config "$ssl_config"; then
    
    uds_log "Self-signed certificate generated successfully" "success"
    chmod 644 "${cert_dir}/fullchain.pem"
    chmod 600 "${cert_dir}/privkey.pem"
    rm -f "$ssl_config"
    return 0
  else
    uds_log "Failed to generate self-signed certificate" "error"
    rm -f "$ssl_config"
    return 1
  fi
}

# Set up auto-renewal for Let's Encrypt certificates
plugin_ssl_setup_auto_renewal() {
  if ! command -v certbot &> /dev/null; then
    return 0
  fi
  
  uds_log "Setting up automatic certificate renewal" "info"
  
  # Ensure log directory exists
  mkdir -p "/var/log" 2>/dev/null || true
  
  # Create renewal script with improved error handling
  local renewal_script="${UDS_BASE_DIR}/renew-certs.sh"
  
  cat > "$renewal_script" << 'EOL'
#!/bin/bash
# Renew certificates and reload Nginx

# Log function
log() {
  echo "$(date) - $1" >> /var/log/certbot-renew.log
}

log "Starting certificate renewal process"

# Run certbot with proper error handling
if ! certbot renew --quiet; then
  log "Certificate renewal failed with exit code $?"
else
  log "Certificates renewed successfully"
  
  # Reload Nginx
  if docker ps -q --filter "name=nginx-proxy" | grep -q .; then
    log "Reloading Nginx in Docker container"
    if ! docker exec nginx-proxy nginx -s reload; then
      log "Failed to reload Nginx in container"
    fi
  elif command -v nginx &> /dev/null; then
    log "Reloading Nginx service"
    if ! (nginx -s reload || systemctl reload nginx || service nginx reload); then
      log "Failed to reload Nginx service"
    fi
  else
    log "Nginx not found, skipping reload"
  fi
fi
EOL
  
  chmod +x "$renewal_script"
  
  # Add crontab entry to run twice daily (standard for Let's Encrypt)
  # Only add if not already present
  if ! crontab -l 2>/dev/null | grep -q "$renewal_script"; then
    (crontab -l 2>/dev/null || echo "") > /tmp/crontab.tmp
    echo "0 0,12 * * * $renewal_script > /dev/null 2>&1" >> /tmp/crontab.tmp
    crontab /tmp/crontab.tmp
    rm /tmp/crontab.tmp
  fi
  
  uds_log "Automatic certificate renewal configured" "success"
  return 0
}

# Finalize SSL setup after deployment
plugin_ssl_finalize() {
  if [ "$SSL" != "true" ]; then
    return 0
  fi
  
  # Set up auto-renewal if Let's Encrypt is available
  if command -v certbot &> /dev/null; then
    plugin_ssl_setup_auto_renewal
  fi
  
  return 0
}