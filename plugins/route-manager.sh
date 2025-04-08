#!/bin/bash
#
# route-manager.sh - Dynamic routing plugin for Unified Deployment System
#
# This plugin manages routing configurations for deployed applications

# Register the plugin
plugin_register_route_manager() {
  uds_log "Registering Route Manager plugin" "debug"
  
  # Register plugin arguments
  uds_register_plugin_arg "route_manager" "ROUTE_AUTO_UPDATE" "true"
  uds_register_plugin_arg "route_manager" "NGINX_CONTAINER" "nginx-proxy"
  uds_register_plugin_arg "route_manager" "NGINX_CONFIG_DIR" "/etc/nginx/conf.d"
  
  # Register plugin hooks
  uds_register_plugin_hook "route_manager" "pre_deploy" "plugin_route_prepare"
  uds_register_plugin_hook "route_manager" "post_deploy" "plugin_route_finalize"
}

# Activate the plugin
plugin_activate_route_manager() {
  uds_log "Activating Route Manager plugin" "debug"
  
  # Create nginx directory if it doesn't exist
  mkdir -p "${UDS_NGINX_DIR}"
  
  # Initialize master nginx configuration if it doesn't exist
  if [ ! -f "${UDS_NGINX_DIR}/default.conf" ]; then
    plugin_route_create_default_config
  fi
}

# Create default Nginx configuration
plugin_route_create_default_config() {
  uds_log "Creating default Nginx configuration" "info"
  
  cat > "${UDS_NGINX_DIR}/default.conf" << 'EOL'
# Default Nginx configuration managed by Unified Deployment System

# HTTP server
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;
    
    # Let's Encrypt validation
    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }
    
    # Default response for unmatched hosts
    location / {
        return 404 "No application configured for this host.\n";
    }
}

# HTTPS server
server {
    listen 443 ssl http2 default_server;
    listen [::]:443 ssl http2 default_server;
    server_name _;
    
    # Self-signed certificate for default server
    ssl_certificate /etc/nginx/certs/default.pem;
    ssl_certificate_key /etc/nginx/certs/default.key;
    ssl_protocols TLSv1.2 TLSv1.3;
    
    # Default response for unmatched hosts
    location / {
        return 404 "No application configured for this host.\n";
    }
}
EOL

  # Generate self-signed certificate for default server
  local cert_dir="${UDS_CERTS_DIR}/default"
  mkdir -p "$cert_dir"
  
  if [ ! -f "${cert_dir}/default.pem" ] || [ ! -f "${cert_dir}/default.key" ]; then
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
      -keyout "${cert_dir}/default.key" \
      -out "${cert_dir}/default.pem" \
      -subj "/CN=localhost"
  fi
  
  uds_log "Default Nginx configuration created" "success"
}

# Prepare routing configuration
plugin_route_prepare() {
  local app_name="$1"
  
  uds_log "Preparing routing configuration for $app_name" "info"
  
  # Check if Nginx proxy container exists
  if ! docker ps -q --filter "name=${NGINX_CONTAINER}" | grep -q .; then
    # Check if the container exists but is stopped
    if docker ps -a -q --filter "name=${NGINX_CONTAINER}" | grep -q .; then
      uds_log "Starting Nginx proxy container" "info"
      docker start "${NGINX_CONTAINER}"
    else
      # Create Nginx proxy container
      uds_log "Creating Nginx proxy container" "info"
      plugin_route_setup_nginx_container
    fi
  fi
  
  return 0
}

# Set up Nginx container
plugin_route_setup_nginx_container() {
  uds_log "Setting up Nginx proxy container" "info"
  
  # Create network for Nginx
  docker network create uds-network 2>/dev/null || true
  
  # Create data directories
  mkdir -p "${UDS_NGINX_DIR}" "${UDS_CERTS_DIR}" "${UDS_BASE_DIR}/www"
  
  # Copy default configuration if it doesn't exist
  if [ ! -f "${UDS_NGINX_DIR}/default.conf" ]; then
    plugin_route_create_default_config
  fi
  
  # Run Nginx container
  docker run -d \
    --name "${NGINX_CONTAINER}" \
    --restart unless-stopped \
    -p 80:80 \
    -p 443:443 \
    -v "${UDS_NGINX_DIR}:/etc/nginx/conf.d" \
    -v "${UDS_CERTS_DIR}:/etc/nginx/certs" \
    -v "${UDS_BASE_DIR}/www:/var/www/html" \
    --network uds-network \
    nginx:alpine
  
  if [ $? -ne 0 ]; then
    uds_log "Failed to start Nginx proxy container" "error"
    return 1
  fi
  
  uds_log "Nginx proxy container started successfully" "success"
  return 0
}

# Update Nginx configuration
plugin_route_update_nginx() {
  uds_log "Updating Nginx configuration" "info"
  
  # Check if Nginx container is running
  if docker ps -q --filter "name=${NGINX_CONTAINER}" | grep -q .; then
    # Copy configurations to the container
    docker cp "${UDS_NGINX_DIR}/." "${NGINX_CONTAINER}:${NGINX_CONFIG_DIR}/"
    
    # Copy certificates to the container
    docker cp "${UDS_CERTS_DIR}/." "${NGINX_CONTAINER}:/etc/nginx/certs/"
    
    # Test Nginx configuration
    if ! docker exec "${NGINX_CONTAINER}" nginx -t &>/dev/null; then
      uds_log "Invalid Nginx configuration!" "error"
      docker exec "${NGINX_CONTAINER}" nginx -t
      return 1
    fi
    
    # Reload Nginx
    docker exec "${NGINX_CONTAINER}" nginx -s reload
  else
    uds_log "Nginx container is not running" "warning"
    return 1
  fi
  
  uds_log "Nginx configuration updated successfully" "success"
  return 0
}

# Finalize routing after deployment
plugin_route_finalize() {
  local app_name="$1"
  
  uds_log "Finalizing routing for $app_name" "info"
  
  # Update Nginx if auto-update is enabled
  if [ "${ROUTE_AUTO_UPDATE}" = "true" ]; then
    plugin_route_update_nginx
  fi
  
  # Make sure the app is connected to the Nginx network
  local app_container="${app_name}-app"
  
  # Check if app container exists
  if docker ps -q --filter "name=${app_container}" | grep -q .; then
    # Connect to Nginx network if not already connected
    if ! docker network inspect uds-network --format '{{range .Containers}}{{.Name}}{{end}}' | grep -q "${app_container}"; then
      uds_log "Connecting ${app_container} to Nginx network" "info"
      docker network connect uds-network "${app_container}" || true
    fi
  fi
  
  return 0
}