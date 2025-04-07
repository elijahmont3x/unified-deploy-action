#!/bin/bash
#
# persistence-manager.sh - Persistent services manager for Unified Deployment System
#
# This plugin manages persistent services like databases that should persist across deployments

# Register the plugin
register_plugin() {
  uds_log "Registering Persistence Manager plugin" "debug"
  
  # Register plugin arguments
  uds_register_plugin_arg "persistence_manager" "PERSISTENCE_PROFILE" "persistence"
  uds_register_plugin_arg "persistence_manager" "PERSISTENCE_DATA_DIR" "${UDS_BASE_DIR}/data"
  uds_register_plugin_arg "persistence_manager" "PERSISTENCE_AUTO_SETUP" "true"
  
  # Register plugin hooks
  uds_register_plugin_hook "persistence_manager" "pre_deploy" "plugin_persistence_setup"
  uds_register_plugin_hook "persistence_manager" "post_deploy" "plugin_persistence_check"
}

# Activate the plugin
plugin_activate_persistence_manager() {
  uds_log "Activating Persistence Manager plugin" "debug"
  
  # Create data directory if it doesn't exist
  mkdir -p "${PERSISTENCE_DATA_DIR}"
}

# Set up persistent services
plugin_persistence_setup() {
  local app_name="$1"
  local app_dir="$2"
  
  uds_log "Setting up persistence for $app_name" "info"
  
  # Check if this service is marked as persistent
  if [ "$PERSISTENT" = "true" ]; then
    uds_log "$app_name is marked as a persistent service" "info"
    
    # Create data directory for the persistent service
    local data_dir="${PERSISTENCE_DATA_DIR}/${app_name}"
    mkdir -p "$data_dir"
    
    # Check if we need to modify the compose file to add volumes
    if [ -f "${app_dir}/docker-compose.yml" ]; then
      # Check if compose file already has volumes
      if ! grep -q "volumes:" "${app_dir}/docker-compose.yml"; then
        # Add volumes section for the persistent service
        uds_log "Adding persistent volumes to docker-compose.yml" "info"
        
        # Create a temporary file
        local temp_file="${app_dir}/docker-compose.yml.tmp"
        
        # Add volumes section to the service
        awk -v data_dir="$data_dir" '
        /services:/ { in_services = 1 }
        /^  [a-zA-Z0-9_-]+:/ { if (in_services) service_name = $1 }
        /container_name:/ && in_services { 
          print $0; 
          print "    volumes:"; 
          print "      - " data_dir ":/data"; 
          next;
        }
        { print $0 }
        ' "${app_dir}/docker-compose.yml" > "$temp_file"
        
        # Replace the original file
        mv "$temp_file" "${app_dir}/docker-compose.yml"
      fi
      
      # Add volumes section at the end if it doesn't exist
      if ! grep -q "^volumes:" "${app_dir}/docker-compose.yml"; then
        echo "" >> "${app_dir}/docker-compose.yml"
        echo "volumes:" >> "${app_dir}/docker-compose.yml"
        echo "  ${app_name}-data:" >> "${app_dir}/docker-compose.yml"
        echo "    name: ${app_name}-data" >> "${app_dir}/docker-compose.yml"
        echo "    external: false" >> "${app_dir}/docker-compose.yml"
      fi
    fi
  elif [ "${PERSISTENCE_AUTO_SETUP}" = "true" ]; then
    # Check for common database/cache services in the compose file
    if [ -f "${app_dir}/docker-compose.yml" ]; then
      # Look for common database services
      if grep -q -E "image: (postgres|mysql|mariadb|mongo|redis|elasticsearch|rabbitmq|memcached)" "${app_dir}/docker-compose.yml"; then
        uds_log "Detected potential persistent services in compose file" "info"
        
        # Add persistence profile to these services
        local temp_file="${app_dir}/docker-compose.yml.tmp"
        
        awk -v profile="${PERSISTENCE_PROFILE}" '
        /image: (postgres|mysql|mariadb|mongo|redis|elasticsearch|rabbitmq|memcached)/ { in_db_service = 1 }
        /profiles:/ && in_db_service { 
          print $0;
          print "      - " profile;
          in_db_service = 0;
          next;
        }
        /^  [a-zA-Z0-9_-]+:/ { in_db_service = 0 }
        /container_name:/ && in_db_service { 
          print $0;
          print "    profiles:";
          print "      - " profile;
          next;
        }
        { print $0 }
        ' "${app_dir}/docker-compose.yml" > "$temp_file"
        
        # Replace the original file
        mv "$temp_file" "${app_dir}/docker-compose.yml"
        
        # Create data directories for the detected services
        mkdir -p "${PERSISTENCE_DATA_DIR}/${app_name}/db"
        mkdir -p "${PERSISTENCE_DATA_DIR}/${app_name}/redis"
        mkdir -p "${PERSISTENCE_DATA_DIR}/${app_name}/elasticsearch"
        
        # Add proper permissions
        chmod -R 777 "${PERSISTENCE_DATA_DIR}/${app_name}"
      fi
    fi
  fi
  
  return 0
}

# Check persistent services after deployment
plugin_persistence_check() {
  local app_name="$1"
  local app_dir="$2"
  
  uds_log "Checking persistence for $app_name" "debug"
  
  # If this is a persistent service, register it as such
  if [ "$PERSISTENT" = "true" ]; then
    # Update the service registry to mark as persistent
    local service_data=$(uds_get_service "$app_name")
    if [ -n "$service_data" ]; then
      echo "$service_data" | jq '.is_persistent = true' > /tmp/service.json
      local registry_data=$(cat "$UDS_REGISTRY_FILE")
      local updated_registry=$(echo "$registry_data" | jq --arg name "$app_name" --slurpfile service /tmp/service.json '.services[$name] = $service[0]')
      echo "$updated_registry" > "$UDS_REGISTRY_FILE"
      rm /tmp/service.json
    fi
  fi
  
  return 0
}