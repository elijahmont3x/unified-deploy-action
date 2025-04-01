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
}

# Check SSL certificates before deployment
plugin_ssl_check() {
  local app_name="$1"
  
  if [ "$SSL" != "true" ]; then
    return 0
  fi
  
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
        echo "${SSL_DNS_CREDENTIALS}" > "$creds_file"
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
    
    # For non-wildcard certs, need to stop web servers
    if [ "$is_wildcard" = false ]; then
      # Stop Nginx temporarily
      if docker ps -q --filter "name=nginx-proxy" | grep -q .; then
        docker stop nginx-proxy || true
      elif command -v nginx &> /dev/null; then
        service nginx stop || systemctl stop nginx || true
      fi
    fi
    
    # Run certbot
    uds_log "Running: $certbot_cmd" "debug"
    if ! eval "$certbot_cmd"; then
      uds_log "Failed to obtain Let's Encrypt certificate, falling back to self-signed" "warning"
      plugin_ssl_generate_self_signed "$server_name" "$cert_dir"
    else
      # Copy certificates to our directory
      cp -L /etc/letsencrypt/live/${server_name}/fullchain.pem "${cert_dir}/fullchain.pem"
      cp -L /etc/letsencrypt/live/${server_name}/privkey.pem "${cert_dir}/privkey.pem"
      
      uds_log "Let's Encrypt certificate obtained successfully" "success"
      
      # Clean up credentials file if it exists
      if [ -f "/tmp/dns_credentials.ini" ]; then
        uds_secure_delete "/tmp/dns_credentials.ini"
      fi
    fi
    
    # Restart Nginx if we stopped it
    if [ "$is_wildcard" = false ]; then
      if docker ps -a --filter "name=nginx-proxy" | grep -q .; then
        docker start nginx-proxy || true
      elif command -v nginx &> /dev/null; then
        service nginx start || systemctl start nginx || true
      fi
    fi
  else
    # Generate self-signed certificate
    plugin_ssl_generate_self_signed "$server_name" "$cert_dir"
  fi
  
  # Set proper permissions
  chmod 644 "${cert_dir}/fullchain.pem"
  chmod 600 "${cert_dir}/privkey.pem"
  
  return 0
}

# Generate a self-signed certificate
plugin_ssl_generate_self_signed() {
  local server_name="$1"
  local cert_dir="$2"
  
  uds_log "Generating self-signed certificate for $server_name" "info"
  
  # Create directory if it doesn't exist
  mkdir -p "$cert_dir"
  
  # Generate self-signed certificate
  openssl req -x509 -nodes -days 365 -newkey rsa:${SSL_RSA_KEY_SIZE} \
    -keyout "${cert_dir}/privkey.pem" \
    -out "${cert_dir}/fullchain.pem" \
    -subj "/CN=${server_name}" \
    -addext "subjectAltName=DNS:${server_name}"
  
  if [ $? -eq 0 ]; then
    uds_log "Self-signed certificate generated successfully" "success"
    return 0
  else
    uds_log "Failed to generate self-signed certificate" "error"
    return 1
  fi
}

# Set up auto-renewal for Let's Encrypt certificates
plugin_ssl_setup_auto_renewal() {
  if ! command -v certbot &> /dev/null; then
    return 0
  fi
  
  uds_log "Setting up automatic certificate renewal" "info"
  
  # Check if crontab entry already exists
  if crontab -l 2>/dev/null | grep -q "certbot renew"; then
    uds_log "Automatic renewal already configured" "info"
    return 0
  fi
  
  # Create renewal script
  local renewal_script="${UDS_BASE_DIR}/renew-certs.sh"
  
  cat > "$renewal_script" << 'EOL'
#!/bin/bash
# Renew certificates and reload Nginx
certbot renew --quiet

# Check if renewal was successful
if [ $? -eq 0 ]; then
  # Reload Nginx
  if docker ps -q --filter "name=nginx-proxy" | grep -q .; then
    docker exec nginx-proxy nginx -s reload
  elif command -v nginx &> /dev/null; then
    nginx -s reload
  fi
  
  echo "$(date) - Certificates renewed successfully" >> /var/log/certbot-renew.log
else
  echo "$(date) - Certificate renewal failed" >> /var/log/certbot-renew.log
fi
EOL
  
  chmod +x "$renewal_script"
  
  # Add crontab entry to run twice daily (standard for Let's Encrypt)
  (crontab -l 2>/dev/null || echo "") | grep -v "$renewal_script" > /tmp/crontab.tmp
  echo "0 0,12 * * * $renewal_script > /dev/null 2>&1" >> /tmp/crontab.tmp
  crontab /tmp/crontab.tmp
  rm /tmp/crontab.tmp
  
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