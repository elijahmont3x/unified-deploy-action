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
# This enhanced version catches more patterns and adds additional sanitization
uds_sanitize_env_vars() {
  local input="$1"
  local sanitized="$input"
  
  # Extended list of sensitive patterns
  local patterns=(
    # Common credential patterns with word boundaries to improve accuracy
    "\\b[A-Za-z0-9_-]+_PASSWORD\\b"
    "\\b[A-Za-z0-9_-]+_PASS\\b"
    "\\b[A-Za-z0-9_-]+_SECRET\\b"
    "\\b[A-Za-z0-9_-]+_KEY\\b"
    "\\b[A-Za-z0-9_-]+_TOKEN\\b"
    "\\b[A-Za-z0-9_-]+_CREDENTIALS\\b"
    "\\b[A-Za-z0-9_-]+_CERT\\b"
    "\\b[A-Za-z0-9_-]+_CREDS\\b"
    "\\b[A-Za-z0-9_-]+_AUTH\\b"
    
    # Common variable prefixes
    "\\bPASSWORD[A-Za-z0-9_-]*\\b"
    "\\bACCESS_TOKEN[A-Za-z0-9_-]*\\b"
    "\\bSECRET[A-Za-z0-9_-]*\\b"
    "\\bAPIKEY[A-Za-z0-9_-]*\\b"
    "\\bAPI_KEY[A-Za-z0-9_-]*\\b"
    "\\bPRIVATE_KEY[A-Za-z0-9_-]*\\b"
    "\\bAUTH[A-Za-z0-9_-]*_TOKEN\\b"
    "\\bTOKEN[A-Za-z0-9_-]*\\b"
    "\\bREFRESH_TOKEN[A-Za-z0-9_-]*\\b"
    "\\bSESSION_KEY[A-Za-z0-9_-]*\\b"
    
    # New: API tokens in standard format
    "\\b[A-Za-z0-9_-]+_API_TOKEN\\b"
    
    # New: Encryption and signing related
    "\\bENCRYPTION_[A-Za-z0-9_-]+\\b"
    "\\bSIGNING_[A-Za-z0-9_-]+\\b"
  )
  
  # Apply sanitization for each pattern with improved regex syntax
  for pattern in "${patterns[@]}"; do
    # key=value format (both quoted and unquoted)
    sanitized=$(echo "$sanitized" | sed -E "s/($pattern)=([^[:space:]\"';]+|\"[^\"]*\"|'[^']*')/\1=******/g")
    
    # key: value format (JSON/YAML style)
    sanitized=$(echo "$sanitized" | sed -E "s/($pattern): *([^[:space:],}\"';]|\"[^\"]*\"|'[^']*')/\1: ******/g")
  done

  # Sanitize connection strings - expanded for more database types
  local connection_patterns=(
    "postgres(ql)?://[^:]+:[^@]+@"
    "mysql://[^:]+:[^@]+@"
    "mongodb(\\+srv)?://[^:]+:[^@]+@"
    "redis://[^:]+:[^@]+@"
    "amqp://[^:]+:[^@]+@"
    "jdbc:[^:]+://[^:]+:[^@;]+(@|;password=)"
    # New: Generic username:password@host pattern
    "[a-zA-Z0-9]+://[^:]+:[^@]+@"
  )
  
  # Apply connection string sanitization
  for pattern in "${connection_patterns[@]}"; do
    sanitized=$(echo "$sanitized" | sed -E "s|($pattern)|\\1******@|g")
  done
  
  # Sanitize Authentication Headers
  sanitized=$(echo "$sanitized" | sed -E 's/(Authorization: (Basic|Bearer) )[a-zA-Z0-9+/._=-]{8,}/\1******/gi')
  
  # Sanitize AWS-style access keys and session tokens
  sanitized=$(echo "$sanitized" | sed -E 's/(AKIA[A-Z0-9]{16})/******/g')
  sanitized=$(echo "$sanitized" | sed -E 's/([a-zA-Z0-9+/]{40})/******/g')
  
  # Sanitize private keys and certificates
  sanitized=$(echo "$sanitized" | sed -E '/BEGIN (RSA |OPENSSH |EC |DSA |PRIVATE KEY)|BEGIN CERTIFICATE/,/END/s/.*/[REDACTED]/g')
  
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