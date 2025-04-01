# Security Best Practices for UDS

This guide covers security best practices when using the Unified Deployment System.

## Overview

UDS includes several security features to help protect your deployments. This document outlines how to use these features effectively and provides additional recommendations.

## Core Security Features

### Secure Permissions Management

UDS automatically applies appropriate permissions to sensitive files:

- Configuration files: `600` (owner read/write only)
- SSL certificates: `600` for private keys, `644` for public certificates
- Log directories: `700` (owner full access only)
- Application directories: `755` (public read/execute, owner full access)

### Sensitive Data Protection

When using UDS:

1. **Environment Variables**: Sensitive values in environment variables are automatically sanitized in logs

2. **Secure Deletion**: When temporary files containing sensitive data are deleted, UDS uses secure deletion techniques:
   ```bash
   # UDS automatically uses the best available method:
   shred -u -z file.key  # If available
   srm -z file.key       # Alternative
   # Fallback to overwriting with zeros
   ```

3. **Registry Security**: The service registry, which stores information about deployments, is stored with `600` permissions

### Security Manager Plugin

The Security Manager plugin adds additional security features:

```json
{
  "plugins": "security-manager",
  "env_vars": {
    "SECURITY_ENCRYPT_ENV": "true",
    "SECURITY_AUDIT_LOGGING": "true"
  }
}
```

Key features:
- Audit logging of all operations
- Log rotation to prevent disk exhaustion
- Environment variable encryption support
- Security warnings for insecure configurations

## Recommended Security Practices

### 1. Use Multi-Stage Deployment

Multi-stage deployments provide additional security by isolating the deployment process:

```bash
./scripts/uds-deploy.sh --config=config.json --multi-stage
```

This ensures that if a deployment fails, the previous version remains intact.

### 2. Enable Secure Mode

When running setup:

```bash
./scripts/uds-setup.sh --config=config.json --secure-mode
```

This enables additional security checks and constraints.

### 3. Use HTTPS with Strong SSL Configuration

Always enable SSL for production deployments:

```json
{
  "ssl": true,
  "ssl_email": "admin@example.com"
}
```

UDS configures Nginx with strong SSL settings:
- TLS 1.2 and 1.3 only
- Strong cipher suites
- HSTS headers
- Security headers for XSS protection

### 4. Handle Credentials Carefully

Store sensitive credentials in environment variables, not in the configuration file:

```bash
# Bad practice - credentials in configuration
cat > config.json << EOL
{
  "env_vars": {
    "DATABASE_PASSWORD": "super-secret-password"
  }
}
EOL

# Better - use environment variables
export DATABASE_PASSWORD="super-secret-password"
cat > config.json << EOL
{
  "env_vars": {
    "DATABASE_PASSWORD": "${DATABASE_PASSWORD}"
  }
}
EOL
```

### 5. Regular Updates

Keep your UDS installation updated:

```bash
cd unified-deployment-system
git pull
chmod +x scripts/*.sh
```

### 6. Restrict Access to UDS Files

Only administrators should have access to the UDS directories:

```bash
# Restrict access to UDS directories
sudo chown -R root:root /path/to/unified-deploy
sudo chmod -R go-w /path/to/unified-deploy
```

### 7. Wildcard Certificates Security

When using wildcard certificates:

```json
{
  "ssl_wildcard": true,
  "ssl_dns_provider": "cloudflare",
  "ssl_dns_credentials": "dns_cloudflare_api_token=your-token"
}
```

Store DNS credentials securely as they can potentially modify your DNS records.

## Security Audit Process

Periodically audit your UDS deployments:

1. Check for outdated container images:
   ```bash
   docker images --format "{{.Repository}}:{{.Tag}} {{.CreatedAt}}" | sort
   ```

2. Review audit logs:
   ```bash
   cat /path/to/unified-deploy/logs/audit.log
   ```

3. Verify SSL certificate expiration:
   ```bash
   find /path/to/unified-deploy/certs -name fullchain.pem | xargs -I{} openssl x509 -enddate -noout -in {}
   ```

4. Check for unauthorized API or SSH access in system logs

## Conclusion

By following these security best practices, you can ensure your UDS deployments remain secure and protected. The built-in security features provide a solid foundation, but maintaining security is an ongoing process that requires vigilance and regular updates.
