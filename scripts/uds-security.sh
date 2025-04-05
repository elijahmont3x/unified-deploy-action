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
# Enhanced version with more patterns and multi-line handling
uds_sanitize_env_vars() {
  local input="$1"
  local sanitized="$input"
  
  # Handle empty input
  if [ -z "$input" ]; then
    return 0
  fi
  
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
    "\\b[A-Za-z0-9_-]+_PWD\\b"
    
    # Common variable prefixes
    "\\bPASSWORD[A-Za-z0-9_-]*\\b"
    "\\bPASS[A-Za-z0-9_-]*\\b"
    "\\bACCESS_TOKEN[A-Za-z0-9_-]*\\b"
    "\\bSECRET[A-Za-z0-9_-]*\\b"
    "\\bAPIKEY[A-Za-z0-9_-]*\\b"
    "\\bAPI_KEY[A-Za-z0-9_-]*\\b"
    "\\bPRIVATE_KEY[A-Za-z0-9_-]*\\b"
    "\\bAUTH[A-Za-z0-9_-]*_TOKEN\\b"
    "\\bTOKEN[A-Za-z0-9_-]*\\b"
    "\\bREFRESH_TOKEN[A-Za-z0-9_-]*\\b"
    "\\bSESSION_KEY[A-Za-z0-9_-]*\\b"
    
    # API tokens and keys
    "\\b[A-Za-z0-9_-]+_API_TOKEN\\b"
    "\\b[A-Za-z0-9_-]+_API_KEY\\b"
    
    # Encryption and signing related
    "\\bENCRYPTION_[A-Za-z0-9_-]+\\b"
    "\\bSIGNING_[A-Za-z0-9_-]+\\b"
    
    # OAuth related
    "\\bOAUTH_[A-Za-z0-9_-]+\\b"
    "\\b[A-Za-z0-9_-]+_OAUTH\\b"
    
    # Two-factor authentication
    "\\bTOTP_[A-Za-z0-9_-]+\\b"
    "\\b2FA_[A-Za-z0-9_-]+\\b"
    "\\bMFA_[A-Za-z0-9_-]+\\b"
    
    # SSH related
    "\\bSSH_[A-Za-z0-9_-]*KEY\\b"
    "\\bSSH_[A-Za-z0-9_-]*SECRET\\b"
    
    # JWT related
    "\\bJWT_[A-Za-z0-9_-]+\\b"
    "\\b[A-Za-z0-9_-]+_JWT\\b"
    
    # Certificate related
    "\\bCERT_[A-Za-z0-9_-]+\\b"
    "\\b[A-Za-z0-9_-]+_CERT\\b"
    "\\bCERTIFICATE_[A-Za-z0-9_-]+\\b"
    
    # Cloud provider specific
    "\\bAWS_[A-Za-z0-9_-]*KEY\\b"
    "\\bAWS_[A-Za-z0-9_-]*SECRET\\b"
    "\\bAZURE_[A-Za-z0-9_-]*KEY\\b"
    "\\bGCP_[A-Za-z0-9_-]*KEY\\b"
    
    # Database related
    "\\bDB_[A-Za-z0-9_-]*PASSWORD\\b"
    "\\bDATABASE_[A-Za-z0-9_-]*PASSWORD\\b"
    "\\bPGPASSWORD\\b"
    "\\bMYSQL_PWD\\b"
    
    # Common service providers
    "\\bTWILIO_[A-Za-z0-9_-]*\\b"
    "\\bSTRIPE_[A-Za-z0-9_-]*\\b"
    "\\bSENDGRID_[A-Za-z0-9_-]*\\b"
    "\\bMAILCHIMP_[A-Za-z0-9_-]*\\b"
  )
  
  # Apply sanitization for each pattern with improved regex syntax
  for pattern in "${patterns[@]}"; do
    # key=value format (both quoted and unquoted)
    sanitized=$(echo "$sanitized" | sed -E "s/($pattern)=([^[:space:]\"';]+|\"[^\"]*\"|'[^']*')/\1=******/g")
    
    # key: value format (JSON/YAML style)
    sanitized=$(echo "$sanitized" | sed -E "s/($pattern): *([^[:space:],}\"';]|\"[^\"]*\"|'[^']*')/\1: ******/g")
    
    # "key": "value" format (JSON style with quoted keys)
    sanitized=$(echo "$sanitized" | sed -E "s/\"($pattern)\": *(\"[^\"]*\"|[0-9]+|true|false|null)/\"\1\": \"******\"/g")
    
    # variable="value" or variable='value' format (shell style)
    sanitized=$(echo "$sanitized" | sed -E "s/($pattern)=\"[^\"]*\"/\1=\"******\"/g")
    sanitized=$(echo "$sanitized" | sed -E "s/($pattern)='[^']*'/\1='******'/g")
  done

  # Sanitize connection strings - expanded for more database types
  local connection_patterns=(
    "postgres(ql)?://[^:]+:[^@]+@"
    "mysql://[^:]+:[^@]+@"
    "mongodb(\\+srv)?://[^:]+:[^@]+@"
    "redis://[^:]+:[^@]+@"
    "redis(\\+sentinel)?://[^:]+:[^@]+@"
    "amqp://[^:]+:[^@]+@"
    "rabbitmq://[^:]+:[^@]+@"
    "jdbc:[^:]+://[^:]+:[^@;]+(@|;password=)"
    "kafka://[^:]+:[^@]+@"
    "mssql://[^:]+:[^@]+@"
    "oracle://[^:]+:[^@]+@"
    "mariadb://[^:]+:[^@]+@"
    "couchdb://[^:]+:[^@]+@"
    "cassandra://[^:]+:[^@]+@"
    "elasticsearch://[^:]+:[^@]+@"
    "solr://[^:]+:[^@]+@"
    "ldap://[^:]+:[^@]+@"
    "ldaps://[^:]+:[^@]+@"
    "smtp://[^:]+:[^@]+@"
    "imap://[^:]+:[^@]+@"
    # Generic username:password@host pattern
    "[a-zA-Z0-9]+://[^:]+:[^@]+@"
  )
  
  # Apply connection string sanitization
  for pattern in "${connection_patterns[@]}"; do
    sanitized=$(echo "$sanitized" | sed -E "s|($pattern)|\\1******@|g")
  done
  
  # Sanitize inline passwords in connection strings
  local password_param_patterns=(
    "password=[^&;]+"
    "passwd=[^&;]+"
    "pwd=[^&;]+"
    "secret=[^&;]+"
    "apikey=[^&;]+"
    "api_key=[^&;]+"
    "access_token=[^&;]+"
    "auth_token=[^&;]+"
  )
  
  for pattern in "${password_param_patterns[@]}"; do
    sanitized=$(echo "$sanitized" | sed -E "s|($pattern)|\\1******|g")
  done
  
  # Sanitize Authentication Headers
  sanitized=$(echo "$sanitized" | sed -E 's/(Authorization: (Basic|Bearer|Digest|NTLM|Negotiate|OAuth) )[a-zA-Z0-9+/._=-]{8,}/\1******/gi')
  sanitized=$(echo "$sanitized" | sed -E 's/(X-Api-Key: )[a-zA-Z0-9+/._=-]{8,}/\1******/gi')
  
  # Sanitize AWS-style access keys and session tokens
  sanitized=$(echo "$sanitized" | sed -E 's/(AKIA[A-Z0-9]{16})/******/g')
  sanitized=$(echo "$sanitized" | sed -E 's/([a-zA-Z0-9+/]{40})/******/g')
  
  # Sanitize common token formats
  # JWT tokens
  sanitized=$(echo "$sanitized" | sed -E 's/eyJ[a-zA-Z0-9_-]+\.[a-zA-Z0-9_-]+\.[a-zA-Z0-9_-]+/******/g')
  # OAuth tokens (typically long random strings)
  sanitized=$(echo "$sanitized" | sed -E 's/ya29\.[a-zA-Z0-9_-]{100,}/******/g')
  sanitized=$(echo "$sanitized" | sed -E 's/gho_[a-zA-Z0-9]{36,}/******/g') # GitHub tokens
  
  # Sanitize private keys, certificates and PEM content
  if [[ "$sanitized" == *"PRIVATE KEY"* ]] || [[ "$sanitized" == *"CERTIFICATE"* ]]; then
    # Handle multi-line private keys and certificates using a temporary file
    local temp_file=$(mktemp)
    echo "$sanitized" > "$temp_file"
    
    # Replace content between BEGIN and END markers
    sed -i -E '
      /BEGIN (PRIVATE KEY|RSA PRIVATE KEY|OPENSSH PRIVATE KEY|EC PRIVATE KEY|DSA PRIVATE KEY|CERTIFICATE)/,/END/s/.*/[REDACTED]/
    ' "$temp_file"
    
    # Read back the sanitized content
    sanitized=$(cat "$temp_file")
    rm -f "$temp_file"
  fi
  
  # Output the sanitized string
  echo "$sanitized"
}

# Apply secure permissions to files or directories
uds_secure_permissions() {
  local target="$1"
  local perms="${2:-600}"
  local recursive="${3:-false}"
  
  if [ ! -e "$target" ]; then
    uds_log "Target does not exist: $target" "error"
    return 1
  fi
  
  if [ "$recursive" = "true" ] && [ -d "$target" ]; then
    # Apply recursively for directories
    find "$target" -type f -exec chmod "$perms" {} \; 2>/dev/null
    find "$target" -type d -exec chmod "$perms" {} \; 2>/dev/null
  else
    # Apply to just the target
    chmod "$perms" "$target" 2>/dev/null || {
      uds_log "Failed to set permissions on $target" "error"
      return 1
    }
  fi
  
  return 0
}

# Securely delete sensitive files with multiple overwrite passes
uds_secure_delete() {
  local target="$1"
  local passes="${2:-3}"  # Default to 3 passes for better security
  
  # Check if target exists
  if [ ! -e "$target" ]; then
    return 0
  fi
  
  # Log operation at debug level
  uds_log "Securely deleting: $target" "debug"
  
  # Try shred if available (most secure)
  if command -v shred &>/dev/null; then
    shred -u -z -n "$passes" "$target" 2>/dev/null
    if [ $? -eq 0 ]; then
      return 0
    else
      uds_log "shred failed, falling back to alternative method" "debug"
    fi
  fi
  
  # Try srm if available
  if command -v srm &>/dev/null; then
    srm -z "$target" 2>/dev/null
    if [ $? -eq 0 ]; then
      return 0
    else
      uds_log "srm failed, falling back to alternative method" "debug"
    fi
  fi
  
  # Try secure-delete's srm if available
  if command -v srm &>/dev/null; then
    srm "$target" 2>/dev/null
    if [ $? -eq 0 ]; then
      return 0
    else
      uds_log "secure-delete's srm failed, falling back to alternative method" "debug"
    fi
  fi
  
  # Fallback to simple overwrite and remove
  if [ -f "$target" ]; then
    # Get file size
    local file_size=$(stat -c %s "$target" 2>/dev/null || stat -f %z "$target" 2>/dev/null)
    if [ -z "$file_size" ] || [ "$file_size" -eq 0 ]; then
      file_size=1024  # Default to 1KB if size determination fails
    fi
    
    # Multiple overwrite passes with different patterns
    for ((i=1; i<=passes; i++)); do
      case $((i % 4)) in
        0) dd if=/dev/zero bs=1024 count=$((file_size / 1024 + 1)) 2>/dev/null | dd of="$target" bs=1024 conv=notrunc 2>/dev/null || true ;;
        1) dd if=/dev/urandom bs=1024 count=$((file_size / 1024 + 1)) 2>/dev/null | dd of="$target" bs=1024 conv=notrunc 2>/dev/null || true ;;
        2) tr '\0' '\377' < /dev/zero | dd bs=1024 count=$((file_size / 1024 + 1)) 2>/dev/null | dd of="$target" bs=1024 conv=notrunc 2>/dev/null || true ;;
        3) tr '\0' '\125' < /dev/zero | dd bs=1024 count=$((file_size / 1024 + 1)) 2>/dev/null | dd of="$target" bs=1024 conv=notrunc 2>/dev/null || true ;;
      esac
    done
  fi
  
  # Finally remove the file
  rm -f "$target" 2>/dev/null
  
  # Verify file is gone
  if [ -e "$target" ]; then
    uds_log "Failed to securely delete: $target" "warning"
    return 1
  fi
  
  return 0
}

# Validate and sanitize a filename to prevent path traversal attacks
uds_sanitize_filename() {
  local filename="$1"
  local sanitized=""
  
  # Handle empty input
  if [ -z "$filename" ]; then
    echo ""
    return 0
  fi
  
  # Remove any path components and only keep the filename
  sanitized=$(basename "$filename")
  
  # Remove any special characters that could be used for command injection
  sanitized=$(echo "$sanitized" | tr -cd 'a-zA-Z0-9._-')
  
  # Ensure the filename doesn't start with a dash (which could be interpreted as a command option)
  if [[ "$sanitized" == -* ]]; then
    sanitized="_${sanitized}"
  fi
  
  # Check if sanitization removed everything
  if [ -z "$sanitized" ]; then
    sanitized="sanitized_file"
  fi
  
  echo "$sanitized"
}

# Generate a secure random password/token
uds_generate_secure_token() {
  local length="${1:-32}"
  local use_special="${2:-false}"
  local use_base64="${3:-false}"
  
  # Validate length
  if ! [[ "$length" =~ ^[0-9]+$ ]]; then
    uds_log "Invalid length specified for token generation: $length" "error"
    return 1
  fi
  
  # If length is too small, warn and set minimum
  if [ "$length" -lt 16 ]; then
    uds_log "Token length too short, using minimum of 16 characters" "warning"
    length=16
  fi
  
  # If base64 is requested, generate using openssl directly
  if [ "$use_base64" = "true" ] && command -v openssl &>/dev/null; then
    # For base64, we need 3/4 of the final desired length in raw bytes
    local raw_bytes=$(( (length * 3 + 3) / 4 ))
    local token=$(openssl rand -base64 "$raw_bytes" | head -c "$length")
    echo "$token"
    return 0
  fi
  
  # Character set definition
  local chars="ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
  
  if [ "$use_special" = "true" ]; then
    chars="${chars}!@#$%^&*()-_=+[]{}|;:,.<>?"
  fi
  
  local token=""
  
  # Generate token using OpenSSL if available (most secure)
  if command -v openssl &>/dev/null; then
    # We need to generate more characters than needed to ensure we have enough after filtering
    local oversize_factor=3
    token=$(openssl rand -base64 $(( length * oversize_factor )) | tr -dc "$chars" | head -c "$length")
    
    # If we couldn't get enough characters, try again with a different approach
    if [ ${#token} -lt "$length" ]; then
      # Alternative approach using /dev/urandom and tr
      token=$(< /dev/urandom tr -dc "$chars" | head -c "$length")
    fi
  # Use /dev/urandom as fallback
  elif [ -r "/dev/urandom" ]; then
    token=$(< /dev/urandom tr -dc "$chars" | head -c "$length")
  # Last resort, use $RANDOM bash variable (less secure)
  else
    uds_log "Using fallback method for token generation (less secure)" "warning"
    local chars_length=${#chars}
    for ((i=1; i<=length; i++)); do
      local pos=$((RANDOM % chars_length))
      token="${token}${chars:$pos:1}"
    done
  fi
  
  # Verify we generated a token of correct length
  if [ ${#token} -ne "$length" ]; then
    uds_log "Failed to generate token of requested length" "warning"
    # Try one more approach as last resort
    token=""
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

# Securely compare strings in constant time to prevent timing attacks
uds_secure_compare() {
  local str1="$1"
  local str2="$2"
  
  # Quick length check (not constant time, but prevents unnecessary processing)
  if [ ${#str1} -ne ${#str2} ]; then
    return 1
  fi
  
  # Compare each character in constant time
  local result=0
  local length=${#str1}
  
  for ((i=0; i<length; i++)); do
    if [ "${str1:$i:1}" != "${str2:$i:1}" ]; then
      result=1
      # Don't return early - continue processing all characters to maintain constant time
    fi
  done
  
  return $result
}

# Check for weak permissions on sensitive files and directories
uds_check_sensitive_permissions() {
  local base_dir="$1"
  local report_file="${2:-${UDS_LOGS_DIR}/security_check.log}"
  
  if [ ! -d "$base_dir" ]; then
    uds_log "Directory not found: $base_dir" "error"
    return 1
  fi
  
  uds_log "Checking permissions on sensitive files in $base_dir" "info"
  
  # Initialize report file
  echo "UDS Security Permission Check - $(date)" > "$report_file"
  echo "====================================" >> "$report_file"
  
  # Check key directories
  local key_dirs=(
    "${base_dir}/configs"
    "${base_dir}/certs"
    "${base_dir}/logs"
  )
  
  for dir in "${key_dirs[@]}"; do
    if [ -d "$dir" ]; then
      local dir_perms=$(stat -c %a "$dir" 2>/dev/null || stat -f %Lp "$dir" 2>/dev/null)
      
      echo "Directory: $dir - Permissions: $dir_perms" >> "$report_file"
      
      # Check if directory is too permissive
      if [ "$dir_perms" -gt 750 ]; then
        echo "WARNING: Directory has loose permissions: $dir ($dir_perms)" >> "$report_file"
        uds_log "Directory has loose permissions: $dir ($dir_perms)" "warning"
      fi
      
      # Check files in directory
      find "$dir" -type f -name "*.key" -o -name "*.pem" -o -name "*.cert" -o -name "*.p12" -o -name "*.pfx" -o -name "*pass*" 2>/dev/null | while read -r file; do
        local file_perms=$(stat -c %a "$file" 2>/dev/null || stat -f %Lp "$file" 2>/dev/null)
        
        echo "File: $file - Permissions: $file_perms" >> "$report_file"
        
        # Check if file is too permissive
        if [ "$file_perms" -gt 600 ]; then
          echo "WARNING: Sensitive file has loose permissions: $file ($file_perms)" >> "$report_file"
          uds_log "Sensitive file has loose permissions: $file ($file_perms)" "warning"
        fi
      done
    fi
  done
  
  # Check registry file permissions
  if [ -f "${UDS_REGISTRY_FILE}" ]; then
    local reg_perms=$(stat -c %a "${UDS_REGISTRY_FILE}" 2>/dev/null || stat -f %Lp "${UDS_REGISTRY_FILE}" 2>/dev/null)
    
    echo "Registry file: ${UDS_REGISTRY_FILE} - Permissions: $reg_perms" >> "$report_file"
    
    # Check if file is too permissive
    if [ "$reg_perms" -gt 600 ]; then
      echo "WARNING: Registry file has loose permissions: ${UDS_REGISTRY_FILE} ($reg_perms)" >> "$report_file"
      uds_log "Registry file has loose permissions: ${UDS_REGISTRY_FILE} ($reg_perms)" "warning"
    fi
  fi
  
  uds_log "Security permission check completed. Report saved to $report_file" "info"
  return 0
}

# Export module state and functions
export UDS_SECURITY_LOADED
export -f uds_sanitize_env_vars uds_secure_permissions uds_secure_delete
export -f uds_sanitize_filename uds_generate_secure_token uds_verify_checksum
export -f uds_secure_compare uds_check_sensitive_permissions