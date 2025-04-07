#!/bin/bash
#
# ssl-manager.sh - SSL Certificate management plugin for Unified Deployment System
#
# This plugin handles SSL certificate generation and renewal using Let's Encrypt

# Register the plugin
register_plugin() {
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
  local cert_full_path="${cert_dir}/fullchain.pem"
  local key_full_path="${cert_dir}/privkey.pem"
  
  if [ -f "$cert_full_path" ] && [ -f "$key_full_path" ]; then
    uds_log "Certificate files exist, checking validity" "debug"
    
    # Enhanced validity checking with more informative output
    if ! openssl x509 -checkend $((SSL_RENEWAL_DAYS * 86400)) -noout -in "$cert_full_path" &> /dev/null; then
      # Get exact expiration date
      local expiry_date=$(openssl x509 -enddate -noout -in "$cert_full_path" | cut -d= -f2)
      local expiry_epoch=$(date -d "$expiry_date" +%s 2>/dev/null || date -j -f "%b %d %H:%M:%S %Y %Z" "$expiry_date" +%s 2>/dev/null)
      local current_epoch=$(date +%s)
      local days_remaining=$(( (expiry_epoch - current_epoch) / 86400 ))
      
      if [ $days_remaining -lt 0 ]; then
        uds_log "SSL certificate for $server_name has expired ($days_remaining days ago)" "warning"
      else
        uds_log "SSL certificate for $server_name will expire in $days_remaining days" "warning"
      fi
      
      # Certificate is expiring soon or has expired, renew it
      plugin_ssl_setup "$server_name" "$SSL_EMAIL" "$cert_dir"
    else
      # Additional verification of certificate details
      uds_log "SSL certificate is valid" "debug"
      
      # Check if certificate matches domain
      local cert_domain=$(openssl x509 -noout -subject -in "$cert_full_path" | grep -oP 'CN\s*=\s*\K[^,]*' || echo "unknown")
      
      if [[ "$cert_domain" != "$server_name" && "$cert_domain" != "*.${DOMAIN}" && "$server_name" != "*.${DOMAIN}" ]]; then
        uds_log "Certificate domain ($cert_domain) doesn't match required domain ($server_name)" "warning"
        plugin_ssl_setup "$server_name" "$SSL_EMAIL" "$cert_dir"
      else
        # Check certificate and key pair match
        local cert_modulus=$(openssl x509 -noout -modulus -in "$cert_full_path" 2>/dev/null | openssl md5 2>/dev/null)
        local key_modulus=$(openssl rsa -noout -modulus -in "$key_full_path" 2>/dev/null | openssl md5 2>/dev/null)
        
        if [ "$cert_modulus" != "$key_modulus" ]; then
          uds_log "Certificate and key don't match, regenerating" "warning"
          plugin_ssl_setup "$server_name" "$SSL_EMAIL" "$cert_dir"
        else
          uds_log "SSL certificate for $server_name is valid and matches private key" "success"
          return 0
        fi
      fi
    fi
  else
    uds_log "SSL certificate for $server_name not found" "info"
    # Certificate doesn't exist, generate new one
    plugin_ssl_setup "$server_name" "$SSL_EMAIL" "$cert_dir"
  fi
  
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
  
  # Create a function to track progress
  ssl_progress() {
    local progress="$1"
    local message="$2"
    uds_log "$message ($progress%)" "info"
  }
  
  # Use Let's Encrypt if certbot is available and we have an email
  if command -v certbot &> /dev/null && [ -n "$email" ]; then
    ssl_progress 10 "Using Let's Encrypt to obtain SSL certificate"
    
    # Build certbot command with enhanced options
    local certbot_cmd="certbot certonly --non-interactive --agree-tos"
    
    # Add email
    certbot_cmd="$certbot_cmd --email ${email}"
    
    # Add domain
    certbot_cmd="$certbot_cmd -d ${server_name}"
    
    # Add staging flag if enabled
    if [ "${SSL_STAGING}" = "true" ]; then
      certbot_cmd="$certbot_cmd --staging"
      uds_log "Using Let's Encrypt staging environment" "warning"
    fi
    
    # Add RSA key size
    certbot_cmd="$certbot_cmd --rsa-key-size ${SSL_RSA_KEY_SIZE}"
    
    # Wildcard certificates require DNS challenge
    if [ "$is_wildcard" = true ]; then
      if [ -z "${SSL_DNS_PROVIDER}" ]; then
        uds_log "Wildcard certificates require a DNS provider, falling back to self-signed" "warning"
        plugin_ssl_generate_self_signed "$server_name" "$cert_dir"
        return 0
      fi
      
      ssl_progress 20 "Using DNS challenge for wildcard certificate"
      certbot_cmd="$certbot_cmd --preferred-challenges dns --dns-${SSL_DNS_PROVIDER}"
      
      # Add credentials if provided
      if [ -n "${SSL_DNS_CREDENTIALS}" ]; then
        # Create a secure credentials file
        local creds_file="/tmp/dns_credentials_$(date +%s).ini"
        # Sanitize credentials before writing to file
        local sanitized_creds=$(echo "${SSL_DNS_CREDENTIALS}" | sed 's/\\\\/\\/g' | sed 's/\\"/"/g')
        echo "${sanitized_creds}" > "$creds_file"
        chmod 600 "$creds_file"
        
        certbot_cmd="$certbot_cmd --dns-${SSL_DNS_PROVIDER}-credentials $creds_file"
      fi
    else
      # For non-wildcard, use standalone mode with http validation
      ssl_progress 20 "Using HTTP challenge for standard certificate"
      certbot_cmd="$certbot_cmd --preferred-challenges http --standalone"
      
      # Add pre/post hooks to stop/start Nginx if it's running
      certbot_cmd="$certbot_cmd --pre-hook \"docker stop nginx-proxy 2>/dev/null || true\" --post-hook \"docker start nginx-proxy 2>/dev/null || true\""
    fi
    
    # Add options for unattended operation
    certbot_cmd="$certbot_cmd --keep-until-expiring"
    
    # Show the command for debugging
    uds_log "Running certbot command: $certbot_cmd" "debug"
    
    # Run certbot with progress updates
    ssl_progress 30 "Obtaining certificate from Let's Encrypt"
    local certbot_output=""
    local certbot_success=false
    
    # Run certbot with error handling
    certbot_output=$(eval "$certbot_cmd" 2>&1) || {
      uds_log "Certbot command failed" "error"
      uds_log "Certbot output: $certbot_output" "debug"
      
      # Check for specific error patterns
      if echo "$certbot_output" | grep -q "too many certificates already issued"; then
        uds_log "Let's Encrypt rate limit reached. Try again later or use staging environment." "error"
      elif echo "$certbot_output" | grep -q "DNS problem"; then
        uds_log "DNS validation failed. Check your DNS settings and provider configuration." "error"
      elif echo "$certbot_output" | grep -q "Connection refused"; then
        uds_log "HTTP validation failed. Make sure port 80 is available." "error"
      fi
      
      ssl_progress 50 "Falling back to self-signed certificate"
      plugin_ssl_generate_self_signed "$server_name" "$cert_dir"
      return 0
    }
    
    certbot_success=true
    ssl_progress 70 "Certificate obtained successfully"
    
    # Get the path where Let's Encrypt saved the certificates
    local le_cert_path="/etc/letsencrypt/live/${server_name}"
    if [ ! -d "$le_cert_path" ]; then
      # Try to find the certificate directory in case domain name normalization was applied
      le_cert_path=$(find /etc/letsencrypt/live -name "*.pem" | grep -v README | head -n 1 | xargs dirname 2>/dev/null)
    fi
    
    if [ -d "$le_cert_path" ]; then
      ssl_progress 80 "Copying certificates to deployment directory"
      # Copy certificates to our directory with proper permissions
      cp -L "${le_cert_path}/fullchain.pem" "${cert_dir}/fullchain.pem" || {
        uds_log "Failed to copy fullchain.pem" "error"
        certbot_success=false
      }
      
      cp -L "${le_cert_path}/privkey.pem" "${cert_dir}/privkey.pem" || {
        uds_log "Failed to copy privkey.pem" "error"
        certbot_success=false
      }
      
      # Set secure permissions
      chmod 644 "${cert_dir}/fullchain.pem"
      chmod 600 "${cert_dir}/privkey.pem"
      
      ssl_progress 90 "Setting up certificate renewal"
      # Set up renewal
      plugin_ssl_setup_auto_renewal
      
      ssl_progress 100 "Let's Encrypt certificate setup completed"
      uds_log "Let's Encrypt certificate obtained successfully" "success"
    else
      certbot_success=false
      uds_log "Failed to locate Let's Encrypt certificates" "error"
    fi
    
    # Clean up credentials file if it exists
    find /tmp -name "dns_credentials_*.ini" -mmin +5 -delete 2>/dev/null || true
    
    # If Let's Encrypt failed, fall back to self-signed
    if [ "$certbot_success" = false ]; then
      uds_log "Failed to obtain Let's Encrypt certificate, falling back to self-signed" "warning"
      plugin_ssl_generate_self_signed "$server_name" "$cert_dir"
    fi
  else
    # Generate self-signed certificate
    uds_log "Certbot not available or no email provided, using self-signed certificate" "warning"
    plugin_ssl_generate_self_signed "$server_name" "$cert_dir"
  fi
  
  return 0
}

# Generate a self-signed certificate with improved security
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
    
    # Also add www subdomain for convenience
    subject_alt_name="${subject_alt_name},DNS:www.${base_domain}"
  else
    # For non-wildcard, add www variant as well
    if [[ "$server_name" != "www."* ]]; then
      subject_alt_name="${subject_alt_name},DNS:www.${server_name}"
    fi
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
x509_extensions    = v3_ca

[ req_dn ]
CN = ${server_name}
O = UDS Self-Signed Certificate
OU = Unified Deployment System
C = US

[ req_ext ]
subjectAltName = ${subject_alt_name}

[ v3_ca ]
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always,issuer
basicConstraints = critical, CA:true
keyUsage = critical, digitalSignature, cRLSign, keyCertSign
subjectAltName = ${subject_alt_name}
EOL
  
  # Generate key and CSR
  openssl genrsa -out "${cert_dir}/privkey.pem" "${SSL_RSA_KEY_SIZE}" || {
    uds_log "Failed to generate RSA key" "error"
    rm -f "$ssl_config"
    return 1
  }
  
  # Set secure permissions for private key
  chmod 600 "${cert_dir}/privkey.pem"
  
  # Generate self-signed certificate with 1 year validity (updated from 3650 days)
  openssl req -new -x509 -sha256 -key "${cert_dir}/privkey.pem" \
    -out "${cert_dir}/fullchain.pem" \
    -days 365 \
    -config "$ssl_config" || {
    uds_log "Failed to generate self-signed certificate" "error"
    rm -f "$ssl_config"
    return 1
  }
  
  # Set appropriate permissions
  chmod 644 "${cert_dir}/fullchain.pem"
  
  # Create chain.pem (identical to fullchain.pem for self-signed)
  cp "${cert_dir}/fullchain.pem" "${cert_dir}/chain.pem"
  chmod 644 "${cert_dir}/chain.pem"
  
  # Create cert.pem (just the certificate without the chain)
  cp "${cert_dir}/fullchain.pem" "${cert_dir}/cert.pem"
  chmod 644 "${cert_dir}/cert.pem"
  
  # Clean up
  rm -f "$ssl_config"
  
  # Verify the certificate
  if openssl x509 -noout -text -in "${cert_dir}/fullchain.pem" > /dev/null; then
    uds_log "Self-signed certificate generated successfully and verified" "success"
    
    # Log certificate details
    local cert_subject=$(openssl x509 -noout -subject -in "${cert_dir}/fullchain.pem")
    local cert_issuer=$(openssl x509 -noout -issuer -in "${cert_dir}/fullchain.pem")
    local cert_dates=$(openssl x509 -noout -dates -in "${cert_dir}/fullchain.pem")
    local cert_sans=$(openssl x509 -noout -text -in "${cert_dir}/fullchain.pem" | grep -A1 "Subject Alternative Name" | tail -n1)
    
    uds_log "Certificate subject: $cert_subject" "debug"
    uds_log "Certificate issuer: $cert_issuer" "debug"
    uds_log "Certificate validity: $cert_dates" "debug"
    uds_log "Certificate SANs: $cert_sans" "debug"
    
    return 0
  else
    uds_log "Failed to verify generated certificate" "error"
    return 1
  fi
}

# Set up auto-renewal for Let's Encrypt certificates with improved reliability
plugin_ssl_setup_auto_renewal() {
  if ! command -v certbot &> /dev/null; then
    return 0
  fi
  
  uds_log "Setting up automatic certificate renewal" "info"
  
  # Ensure log directory exists
  mkdir -p "/var/log" 2>/dev/null || mkdir -p "${UDS_LOGS_DIR}/certbot" 2>/dev/null || true
  
  # Determine log file location
  local log_file="/var/log/certbot-renew.log"
  if [ ! -w "/var/log" ]; then
    log_file="${UDS_LOGS_DIR}/certbot/renew.log"
    mkdir -p "$(dirname "$log_file")" 2>/dev/null || true
  fi
  
  # Create renewal script with improved error handling and notification
  local renewal_script="${UDS_BASE_DIR}/renew-certs.sh"
  
  cat > "$renewal_script" << EOL
#!/bin/bash
# Renew certificates and reload Nginx

# Lock file to prevent concurrent runs
LOCK_FILE="/tmp/certbot-renew.lock"

# Exit if renewal is already in progress
if [ -f "\$LOCK_FILE" ]; then
  # Check if the process is actually running
  if ps -p \$(cat "\$LOCK_FILE" 2>/dev/null) &>/dev/null; then
    echo "\$(date) - Renewal already in progress, exiting" >> "$log_file"
    exit 0
  else
    # Lock file exists but process is gone
    echo "\$(date) - Removing stale lock file" >> "$log_file"
    rm -f "\$LOCK_FILE"
  fi
fi

# Create lock file with current PID
echo \$\$ > "\$LOCK_FILE"

# Make sure we remove the lock file when the script exits
trap 'rm -f "\$LOCK_FILE"' EXIT

# Log function with timestamp
log() {
  echo "\$(date) - \$1" >> "$log_file"
}

log "Starting certificate renewal process"

# Test if certbot is available
if ! command -v certbot &>/dev/null; then
  log "Certbot not found, aborting"
  exit 1
fi

# Check if we need to renew any certificates (dry run first)
NEEDS_RENEWAL=false
if certbot renew --dry-run &>/dev/null; then
  # Check which certificates need renewal
  DRY_RUN_OUTPUT=\$(certbot renew --dry-run 2>&1)
  if echo "\$DRY_RUN_OUTPUT" | grep -q "No renewals were attempted"; then
    log "No certificates need renewal at this time"
    exit 0
  fi
  NEEDS_RENEWAL=true
else
  log "Certbot dry-run failed, continuing with actual renewal"
  NEEDS_RENEWAL=true
fi

# Only proceed if we need to renew certificates
if [ "\$NEEDS_RENEWAL" = "true" ]; then
  log "Certificates need renewal, proceeding"
  
  # Run certbot with proper error handling
  RENEWAL_OUTPUT=\$(certbot renew 2>&1)
  RENEWAL_STATUS=\$?
  
  if [ \$RENEWAL_STATUS -eq 0 ]; then
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
  else
    log "Certificate renewal failed with exit code \$RENEWAL_STATUS"
    log "Error output: \$RENEWAL_OUTPUT"
    
    # Send notification if telegram notifier is available and enabled
    if type plugin_telegram_send_message &>/dev/null && [ "\${TELEGRAM_ENABLED:-false}" = "true" ]; then
      plugin_telegram_send_message "SSL certificate renewal failed. Please check the logs." "error"
    fi
  fi
else
  log "No certificates need renewal at this time"
fi
EOL
  
  chmod +x "$renewal_script"
  
  # Add crontab entry to run twice daily (standard for Let's Encrypt)
  # Only add if not already present
  if ! crontab -l 2>/dev/null | grep -q "$renewal_script"; then
    (crontab -l 2>/dev/null || echo "") > /tmp/crontab.tmp
    echo "0 0,12 * * * $renewal_script > /dev/null 2>&1" >> /tmp/crontab.tmp
    
    # Try to install the crontab
    if ! crontab /tmp/crontab.tmp; then
      # If crontab installation fails, create a system timer/service if systemd is available
      if command -v systemctl &>/dev/null; then
        uds_log "Creating systemd timer for certificate renewal" "info"
        
        # Create service file
        local service_file="/etc/systemd/system/certbot-renew.service"
        if [ ! -w "/etc/systemd/system" ]; then
          service_file="${UDS_BASE_DIR}/certbot-renew.service"
        fi
        
        cat > "$service_file" << EOL
[Unit]
Description=Renew Let's Encrypt certificates
After=network.target

[Service]
Type=oneshot
ExecStart=$renewal_script
User=$(whoami)

[Install]
WantedBy=multi-user.target
EOL
        
        # Create timer file
        local timer_file="/etc/systemd/system/certbot-renew.timer"
        if [ ! -w "/etc/systemd/system" ]; then
          timer_file="${UDS_BASE_DIR}/certbot-renew.timer"
        fi
        
        cat > "$timer_file" << EOL
[Unit]
Description=Run Let's Encrypt certificate renewal twice daily

[Timer]
OnCalendar=*-*-* 00,12:00:00
RandomizedDelaySec=3600
Persistent=true

[Install]
WantedBy=timers.target
EOL
        
        # Attempt to enable the timer if we have privileges
        if [ "$service_file" = "/etc/systemd/system/certbot-renew.service" ]; then
          systemctl daemon-reload
          systemctl enable certbot-renew.timer
          systemctl start certbot-renew.timer
        else
          uds_log "Created systemd files in $UDS_BASE_DIR but cannot enable them. Manual installation required." "warning"
        fi
      else
        # Fallback to a shell script that can be executed by user crontab
        uds_log "Created renewal script but couldn't install crontab entry. Please add the following line to your crontab:" "warning"
        uds_log "0 0,12 * * * $renewal_script > /dev/null 2>&1" "warning"
      fi
    fi
    
    rm -f /tmp/crontab.tmp
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
  
  # Check if the newly deployed site is properly serving HTTPS
  local url=""
  
  if [ "$ROUTE_TYPE" = "subdomain" ] && [ -n "$ROUTE" ]; then
    url="https://${ROUTE}.${DOMAIN}"
  else
    url="https://${DOMAIN}"
    if [ -n "$ROUTE" ]; then
      url="${url}/${ROUTE}"
    fi
  fi
  
  uds_log "Testing HTTPS connection to $url" "info"
  
  # Use curl to test the connection
  if command -v curl &>/dev/null; then
    local https_result=$(curl -s -o /dev/null -w "%{http_code}" -m 5 "$url")
    
    if [ "$https_result" -ge 200 ] && [ "$https_result" -lt 500 ]; then
      uds_log "HTTPS connection test passed with status $https_result" "success"
    else
      uds_log "HTTPS connection test returned status $https_result, might need additional configuration" "warning"
    fi
  fi
  
  return 0
}