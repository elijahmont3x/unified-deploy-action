#!/bin/bash
#
# postgres-manager.sh - PostgreSQL migration plugin for Unified Deployment System
#
# This plugin handles PostgreSQL database migrations and backups

# Register the plugin
plugin_register_postgres_manager() {
  uds_log "Registering PostgreSQL Manager plugin" "debug"
  
  # Register plugin arguments
  uds_register_plugin_arg "postgres_manager" "PG_MIGRATION_ENABLED" "false"
  uds_register_plugin_arg "postgres_manager" "PG_CONNECTION_STRING" ""
  uds_register_plugin_arg "postgres_manager" "PG_BACKUP_ENABLED" "true"
  uds_register_plugin_arg "postgres_manager" "PG_BACKUP_DIR" "${UDS_BASE_DIR}/backups"
  uds_register_plugin_arg "postgres_manager" "PG_MIGRATION_SCRIPT" ""
  uds_register_plugin_arg "postgres_manager" "PG_MIGRATION_CONTAINER" ""
  
  # Register plugin hooks
  uds_register_plugin_hook "postgres_manager" "pre_deploy" "plugin_pg_prepare"
  uds_register_plugin_hook "postgres_manager" "post_deploy" "plugin_pg_migrate"
}

# Activate the plugin
plugin_activate_postgres_manager() {
  uds_log "Activating PostgreSQL Manager plugin" "debug"
  
  # Create backup directory if it doesn't exist
  mkdir -p "${PG_BACKUP_DIR}"
}

# Parse PostgreSQL connection string
plugin_pg_parse_connection() {
  local conn_string="$1"
  
  # Example: postgresql://username:password@hostname:port/database
  if [[ "$conn_string" =~ ^postgresql://([^:]+):([^@]+)@([^:/]+):([0-9]+)/(.+)$ ]]; then
    PG_USER="${BASH_REMATCH[1]}"
    PG_PASSWORD="${BASH_REMATCH[2]}"
    PG_HOST="${BASH_REMATCH[3]}"
    PG_PORT="${BASH_REMATCH[4]}"
    PG_DATABASE="${BASH_REMATCH[5]}"
    
    return 0
  fi
  
  uds_log "Invalid PostgreSQL connection string format" "error"
  return 1
}

# Back up PostgreSQL database
plugin_pg_backup() {
  local app_name="$1"
  
  if [ -z "${PG_CONNECTION_STRING}" ]; then
    uds_log "No PostgreSQL connection string provided, skipping backup" "warning"
    return 0
  fi
  
  # Parse connection string
  plugin_pg_parse_connection "${PG_CONNECTION_STRING}" || return 1
  
  # Generate backup filename
  local timestamp=$(date +"%Y%m%d_%H%M%S")
  local backup_file="${PG_BACKUP_DIR}/${app_name}_${timestamp}.sql"
  
  uds_log "Backing up PostgreSQL database to ${backup_file}" "info"
  
  # Create backup directory if it doesn't exist
  mkdir -p "${PG_BACKUP_DIR}"
  
  # Check if pg_dump is available
  if ! command -v pg_dump &>/dev/null; then
    uds_log "pg_dump command not found. Installing..." "warning"
    
    # Try to install PostgreSQL client
    if command -v apt-get &>/dev/null; then
      apt-get update && apt-get install -y postgresql-client
    elif command -v yum &>/dev/null; then
      yum install -y postgresql
    elif command -v apk &>/dev/null; then
      apk add --no-cache postgresql-client
    else
      uds_log "Could not install PostgreSQL client. Backup failed." "error"
      return 1
    fi
  fi
  
  # Perform the backup
  PGPASSWORD="${PG_PASSWORD}" pg_dump -h "${PG_HOST}" -p "${PG_PORT}" -U "${PG_USER}" -d "${PG_DATABASE}" -f "${backup_file}" || {
      uds_log "Database backup failed" "error"
      return 1
    }
  
  uds_log "Database backup completed successfully" "success"
  return 0
}

# Prepare for PostgreSQL operations
plugin_pg_prepare() {
  local app_name="$1"
  
  if [ "${PG_MIGRATION_ENABLED}" != "true" ]; then
    return 0
  fi
  
  if [ -z "${PG_CONNECTION_STRING}" ]; then
    uds_log "No PostgreSQL connection string provided, skipping database operations" "warning"
    return 0
  fi
  
  # Back up the database if enabled
  if [ "${PG_BACKUP_ENABLED}" = "true" ]; then
    plugin_pg_backup "$app_name" || {
      uds_log "Database backup failed, but continuing with deployment" "warning"
    }
  fi
  
  return 0
}

# Run PostgreSQL migrations
plugin_pg_migrate() {
  local app_name="$1"
  local app_dir="$2"
  
  if [ "${PG_MIGRATION_ENABLED}" != "true" ]; then
    return 0
  fi
  
  if [ -z "${PG_CONNECTION_STRING}" ]; then
    uds_log "No PostgreSQL connection string provided, skipping migrations" "warning"
    return 0
  fi
  
  uds_log "Running PostgreSQL migrations for $app_name" "info"
  
  # Determine migration strategy
  if [ -n "${PG_MIGRATION_SCRIPT}" ]; then
    # Run migration script directly
    uds_log "Running migration script: ${PG_MIGRATION_SCRIPT}" "info"
    
    if [ -n "${PG_MIGRATION_CONTAINER}" ]; then
      # Run inside container
      docker exec "${PG_MIGRATION_CONTAINER}" sh -c "${PG_MIGRATION_SCRIPT}" || {
        uds_log "Migration script failed" "error"
        return 1
      }
    else
      # Find a suitable container
      local container=$(docker ps -q --filter "name=${app_name}-")
      if [ -n "$container" ]; then
        docker exec "$container" sh -c "${PG_MIGRATION_SCRIPT}" || {
          uds_log "Migration script failed" "error"
          return 1
        }
      else
        # Run locally
        eval "${PG_MIGRATION_SCRIPT}" || {
          uds_log "Migration script failed" "error"
          return 1
        }
      fi
    fi
  else
    # Look for common migration patterns
    if [ -f "${app_dir}/migrations" ]; then
      uds_log "Found migrations directory, looking for migration tools" "info"
      
      # Find a suitable container
      local container=$(docker ps -q --filter "name=${app_name}-app" | head -n1)
      if [ -z "$container" ]; then
        container=$(docker ps -q --filter "name=${app_name}-" | head -n1)
      fi
      
      if [ -n "$container" ]; then
        # Try to detect migration tool
        if docker exec "$container" sh -c "command -v npm" &>/dev/null; then
          uds_log "Detected Node.js environment, running migrations" "info"
          docker exec -e "DATABASE_URL=${PG_CONNECTION_STRING}" "$container" sh -c "npm run migrate" || {
            uds_log "Migration failed" "error"
            return 1
          }
        elif docker exec "$container" sh -c "command -v python" &>/dev/null; then
          uds_log "Detected Python environment, running migrations" "info"
          docker exec -e "DATABASE_URL=${PG_CONNECTION_STRING}" "$container" sh -c "python manage.py migrate" || {
            uds_log "Migration failed" "error"
            return 1
          }
        else
          uds_log "Could not detect migration tool" "warning"
          return 0
        fi
      else
        uds_log "No container found to run migrations" "warning"
        return 0
      fi
    else
      uds_log "No migrations directory found" "info"
      return 0
    fi
  fi
  
  uds_log "Migrations completed successfully" "success"
  return 0
}