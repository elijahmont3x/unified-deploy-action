#!/bin/bash
#
# uds-security.sh - Security utilities for Unified Deployment System
#
# This module provides security-related functions used by the core system

# Avoid loading multiple times
if [ -n "$UDS_SECURITY_LOADED" ]; then
  return 0
fi

# Load dependencies
if [ -z "$UDS_ENV_LOADED" ]; then
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/uds-env.sh"
fi

if [ -z "$UDS_LOGGING_LOADED" ]; then
  source "${UDS_BASE_DIR}/uds-logging.sh"
fi

UDS_SECURITY_LOADED=1

# Sanitize sensitive environment variables for logging
uds_sanitize_env_vars() {
  local input="$1"
  local sanitized="$input"
  
  # Enhanced patterns to sanitize - expanded to cover more sensitive data patterns
  local patterns=(
    # Common credential patterns
    "[A-Za-z0-9_-]+_PASSWORD"
    "[A-Za-z0-9_-]+_PASS"
    "[A-Za-z0-9_-]+_SECRET"
    "[A-Za-z0-9_-]+_KEY"
    "[A-Za-z0-9_-]+_TOKEN"
    "[A-Za-z0-9_-]+_CREDENTIALS"
    "[A-Za-z0-9_-]+_CERT"
    "[A-Za-z0-9_-]+_CREDS"
    "[A-Za-z0-9_-]+_AUTH"
    
    # Common variable prefixes
    "PASSWORD[A-Za-z0-9_-]*"
    "ACCESS_TOKEN[A-Za-z0-9_-]*"
    "SECRET[A-Za-z0-9_-]*"
    "APIKEY[A-Za-z0-9_-]*"
    "API_KEY[A-Za-z0-9_-]*"
    "PRIVATE_KEY[A-Za-z0-9_-]*"
    "AUTH[A-Za-z0-9_-]*_TOKEN"
    "TOKEN[A-Za-z0-9_-]*"
    "REFRESH_TOKEN[A-Za-z0-9_-]*"
    "SESSION_KEY[A-Za-z0-9_-]*"
    "SSH_KEY"
    "SSL_DNS_CREDENTIALS"
    "CONNECTION_STRING"
    "CONN_STR"
    
    # Database credentials
    "DB_PASSWORD"
    "DATABASE_PASSWORD"
    "MYSQL_PASSWORD"
    "POSTGRES_PASSWORD"
    "MONGODB_PASSWORD"
    "PG_PASSWORD"
    
    # Cloud provider credentials
    "AWS_SECRET"
    "AWS_ACCESS_KEY"
    "AWS_SECRET_ACCESS_KEY"
    "AZURE_KEY"
    "AZURE_SECRET"
    "AZURE_PASSWORD"
    "AZURE_CONNECTION_STRING"
    "GCP_KEY"
    "GOOGLE_APPLICATION_CREDENTIALS"
    "DIGITALOCEAN_TOKEN"
    "DO_TOKEN"
    
    # OAuth and auth patterns
    "OAUTH_TOKEN"
    "OAUTH_SECRET"
    "OAUTH_REFRESH_TOKEN"
    "CLIENT_SECRET"
    "JWT_SECRET"
    "JWT_KEY"
    "AUTH0_CLIENT_SECRET"
    
    # Service-specific patterns
    "GITHUB_TOKEN"
    "GITHUB_SECRET"
    "GITLAB_TOKEN"
    "DOCKER_PASSWORD"
    "NPM_TOKEN"
    "STRIPE_SECRET"
    "STRIPE_KEY"
    "SLACK_TOKEN"
    "SLACK_WEBHOOK"
    "TWILIO_AUTH"
    "SENDGRID_API_KEY"
  )
  
  # Apply sanitization to each pattern
  for pattern in "${patterns[@]}"; do
    # Cover both key=value and key: value formats with various quoting styles
    # key=value format (unquoted)
    sanitized=$(echo "$sanitized" | sed -E "s/($pattern)=([^[:space:]\"']+)/\1=******/g")
    
    # key='value' format (single quotes)
    sanitized=$(echo "$sanitized" | sed -E "s/($pattern)=('[^']+')/\1=******/g")
    
    # key="value" format (double quotes)
    sanitized=$(echo "$sanitized" | sed -E "s/($pattern)=(\"[^\"]+\")/\1=******/g")
    
    # key: value format (JSON/YAML style)
    sanitized=$(echo "$sanitized" | sed -E "s/($pattern): *([^[:space:],}\"])/\1: ******/g")
    
    # key: "value" format (JSON style with quotes)
    sanitized=$(echo "$sanitized" | sed -E "s/($pattern): *(\"[^\"]+\")/\1: \"******\"/g")
    
    # key: 'value' format (YAML style with quotes)
    sanitized=$(echo "$sanitized" | sed -E "s/($pattern): *('[^']+')/\1: '******'/g")
  done

  # Enhanced JSON pattern sanitization - for structured data formats
  local json_patterns=(
    "password"
    "passwd"
    "pass"
    "secret"
    "token"
    "apitoken"
    "api_token"
    "key"
    "apikey"
    "api_key"
    "access_key"
    "access_token"
    "auth"
    "credentials"
    "creds"
    "cert"
    "private_key"
    "ssh_key"
    "encryption_key"
    "connection_string"
    "conn_str"
    "client_secret"
    "oauth_token"
    "refresh_token"
    "jwt_token"
    "session_key"
  )
  
  # Apply JSON pattern sanitization - handles more formats and variations
  for pattern in "${json_patterns[@]}"; do
    # Standard JSON pattern: "key": "value"
    sanitized=$(echo "$sanitized" | sed -E "s/\"($pattern)\"\s*:\s*\"[^\"]*\"/\"\\1\": \"******\"/gi")
    
    # JSON with single quotes: 'key': 'value'
    sanitized=$(echo "$sanitized" | sed -E "s/'($pattern)'\s*:\s*'[^']*'/\'\\1\': \'******\'/gi")
    
    # JSON with mixed quotes: "key": 'value' or 'key': "value"
    sanitized=$(echo "$sanitized" | sed -E "s/\"($pattern)\"\s*:\s*'[^']*'/\"\\1\": \'******\'/gi")
    sanitized=$(echo "$sanitized" | sed -E "s/'($pattern)'\s*:\s*\"[^\"]*\"/\'\\1\': \"******\"/gi")
    
    # JSON with numeric values: "key": 12345 
    sanitized=$(echo "$sanitized" | sed -E "s/\"($pattern)\"\s*:\s*[0-9]+/\"\\1\": ******/gi")
    
    # YAML/JSON with no quotes: key: value
    sanitized=$(echo "$sanitized" | sed -E "s/($pattern)\s*:\s*[^[:space:],}\"]*/\\1: ******/gi")
  done
  
  # Handle database connection strings (more complex patterns)
  # Match common database connection string formats
  local connection_patterns=(
    # Standard connection strings
    "postgresql://[^:]+:[^@]+@"
    "mysql://[^:]+:[^@]+@"
    "mongodb://[^:]+:[^@]+@"
    "mongodb+srv://[^:]+:[^@]+@"
    "redis://[^:]+:[^@]+@"
    "db2://[^:]+:[^@]+@"
    "oracle://[^:]+:[^@]+@"
    "sqlserver://[^:]+:[^@]+@"
    
    # JDBC connection strings
    "jdbc:postgresql://[^:]+:[^@]+@"
    "jdbc:mysql://[^:]+:[^@]+@"
    "jdbc:oracle:thin:[^/]+/[^@]+@"
    "jdbc:sqlserver://[^:]+:[^;]+;password=[^;]+"
    
    # ODBC connection strings
    "Driver=.*;.*PWD=([^;]*)"
    "Driver=.*;.*Password=([^;]*)"
    "Driver=.*;.*UID=([^;]*);.*PWD=([^;]*)"
  )
  
  # Apply connection string sanitization
  for pattern in "${connection_patterns[@]}"; do
    case "$pattern" in
      # Handle special ODBC cases
      "Driver=.*;.*PWD=([^;]*)")
        sanitized=$(echo "$sanitized" | sed -E "s/(Driver=.*;.*)PWD=([^;]*)(;.*)/\\1PWD=******\\3/gi")
        ;;
      "Driver=.*;.*Password=([^;]*)")
        sanitized=$(echo "$sanitized" | sed -E "s/(Driver=.*;.*)Password=([^;]*)(;.*)/\\1Password=******\\3/gi")
        ;;
      "Driver=.*;.*UID=([^;]*);.*PWD=([^;]*)")
        sanitized=$(echo "$sanitized" | sed -E "s/(Driver=.*;.*UID=)([^;]*)(;.*PWD=)([^;]*)(;.*)/\\1******\\3******\\5/gi")
        ;;
      # Handle URL-style connection strings
      *)
        sanitized=$(echo "$sanitized" | sed -E "s|($pattern)|\\1username:******@|g")
        ;;
    esac
  done
  
  # Sanitize Base64-encoded credentials
  # This attempts to find and sanitize Base64-encoded credentials (JWT tokens, basic auth)
  sanitized=$(echo "$sanitized" | sed -E "s/(eyJ[a-zA-Z0-9_-]{20,}\.eyJ[a-zA-Z0-9_-]{20,}\.)[a-zA-Z0-9_-]+/\\1******/g")
  sanitized=$(echo "$sanitized" | sed -E "s/(Authorization: Basic )[a-zA-Z0-9+/=]{16,}/\\1******/gi")
  sanitized=$(echo "$sanitized" | sed -E "s/(Authorization: Bearer )[a-zA-Z0-9+/._=-]{16,}/\\1******/gi")
  
  # Sanitize AWS-style access keys and session tokens
  sanitized=$(echo "$sanitized" | sed -E "s/(AKIA[A-Z0-9]{16})/******/g")
  sanitized=$(echo "$sanitized" | sed -E "s/([a-zA-Z0-9+/]{40})/******/g")
  sanitized=$(echo "$sanitized" | sed -E "s/(AWS_SESSION_TOKEN=)[a-zA-Z0-9+/=]{100,}/\\1******/g")
  
  # Sanitize private keys and certificates
  sanitized=$(echo "$sanitized" | sed -E "/-----BEGIN ([A-Z]+ )?PRIVATE KEY-----/,/-----END ([A-Z]+ )?PRIVATE KEY-----/s/.*/[PRIVATE KEY REDACTED]/")
  sanitized=$(echo "$sanitized" | sed -E "/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/s/.*/[CERTIFICATE REDACTED]/")
  
  echo "$sanitized"
}

# Apply secure permissions to files or directories
uds_secure_permissions() {
  local target="$1"
  local perms="${2:-600}"
  
  if [ ! -e "$target" ]; then
    uds_log "Target does not exist: $target" "error"
    return 1
  fi
  
  chmod "$perms" "$target" || {
    uds_log "Failed to set permissions on $target" "error"
    return 1
  }
  
  return 0
}

# Securely delete sensitive files with multiple overwrite passes
uds_secure_delete() {
  local target="$1"
  local passes="${2:-3}"  # Default to 3 passes for better security
  
  if [ ! -e "$target" ]; then
    return 0
  fi
  
  # Try shred if available (most secure)
  if command -v shred &>/dev/null; then
    shred -u -z -n "$passes" "$target"
  # Try srm if available
  elif command -v srm &>/dev/null; then
    srm -z "$target"
  # Try secure-delete if available
  elif command -v srm &>/dev/null; then
    srm "$target"
  # Fallback to simple overwrite and remove
  else
    # Multiple overwrite passes with different patterns
    for ((i=1; i<=passes; i++)); do
      case $((i % 3)) in
        0) dd if=/dev/zero of="$target" bs=1k count=1 conv=notrunc &>/dev/null || true ;;
        1) dd if=/dev/urandom of="$target" bs=1k count=1 conv=notrunc &>/dev/null || true ;;
        2) echo -n -e "\xff\xff\xff\xff" | dd of="$target" bs=1k count=1 conv=notrunc &>/dev/null || true ;;
      esac
    done
    rm -f "$target"
  fi
  
  return 0
}

# Validate and sanitize a filename to prevent path traversal attacks
uds_sanitize_filename() {
  local filename="$1"
  local sanitized=""
  
  # Remove any path components and only keep the filename
  sanitized=$(basename "$filename")
  
  # Remove any special characters that could be used for command injection
  sanitized=$(echo "$sanitized" | tr -cd 'a-zA-Z0-9._-')
  
  echo "$sanitized"
}

# Generate a secure random password/token
uds_generate_secure_token() {
  local length="${1:-32}"
  local use_special="${2:-false}"
  
  local chars="ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
  
  if [ "$use_special" = "true" ]; then
    chars="${chars}!@#$%^&*()-_=+[]{}|;:,.<>?"
  fi
  
  local token=""
  
  # Generate token using OpenSSL if available (most secure)
  if command -v openssl &>/dev/null; then
    token=$(openssl rand -base64 $((length * 2)) | tr -dc "$chars" | head -c "$length")
  # Use /dev/urandom as fallback
  elif [ -r "/dev/urandom" ]; then
    token=$(cat /dev/urandom | tr -dc "$chars" | head -c "$length")
  # Last resort, use $RANDOM bash variable (less secure)
  else
    local chars_length=${#chars}
    for ((i=1; i<=length; i++)); do
      local pos=$((RANDOM % chars_length))
      token="${token}${chars:$pos:1}"
    done
  fi
  
  echo "$token"
}

# Verify file integrity using checksums
uds_verify_checksum() {
  local file="$1"
  local expected_checksum="$2"
  local algorithm="${3:-sha256}"
  
  if [ ! -f "$file" ]; then
    uds_log "File not found: $file" "error"
    return 1
  fi
  
  local calculated_checksum=""
  
  case "$algorithm" in
    md5)
      if command -v md5sum &>/dev/null; then
        calculated_checksum=$(md5sum "$file" | awk '{print $1}')
      elif command -v md5 &>/dev/null; then
        calculated_checksum=$(md5 -q "$file")
      else
        uds_log "No MD5 utility found" "error"
        return 1
      fi
      ;;
      
    sha1)
      if command -v sha1sum &>/dev/null; then
        calculated_checksum=$(sha1sum "$file" | awk '{print $1}')
      elif command -v shasum &>/dev/null; then
        calculated_checksum=$(shasum -a 1 "$file" | awk '{print $1}')
      else
        uds_log "No SHA1 utility found" "error"
        return 1
      fi
      ;;
      
    sha256|*)
      if command -v sha256sum &>/dev/null; then
        calculated_checksum=$(sha256sum "$file" | awk '{print $1}')
      elif command -v shasum &>/dev/null; then
        calculated_checksum=$(shasum -a 256 "$file" | awk '{print $1}')
      else
        uds_log "No SHA256 utility found" "error"
        return 1
      fi
      ;;
  esac
  
  if [ "$calculated_checksum" = "$expected_checksum" ]; then
    return 0
  else
    uds_log "Checksum verification failed for $file" "error"
    uds_log "Expected: $expected_checksum" "error"
    uds_log "Actual: $calculated_checksum" "error"
    return 1
  fi
}

# Export module state and functions
export UDS_SECURITY_LOADED
export -f uds_sanitize_env_vars uds_secure_permissions uds_secure_delete
export -f uds_sanitize_filename uds_generate_secure_token uds_verify_checksum