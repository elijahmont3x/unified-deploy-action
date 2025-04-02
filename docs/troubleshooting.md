# UDS Troubleshooting Guide

This guide helps you diagnose and resolve common issues when working with the Unified Deployment System.

## Diagnostic Approach

When troubleshooting UDS, follow this systematic approach:

1. **Check logs**: Always start by checking UDS logs with `--log-level=debug`
2. **Verify configuration**: Many issues come from misconfiguration
3. **Check system requirements**: Ensure all dependencies are installed
4. **Inspect containers**: Check container status and logs
5. **Verify network**: Ensure proper network connectivity

## Common Issues and Solutions

### 1. Deployment Failures

#### Symptom: Deployment fails with "Failed to pull image" error

**Possible causes:**
- Image doesn't exist or is private
- Docker credentials not configured
- Network connectivity issues

**Solutions:**
- Verify image exists with `docker pull <image>:<tag>`
- Set up Docker credentials with `docker login`
- Check network connectivity to the registry
- For private images, add registry authentication

#### Symptom: Deployment completes but application is not accessible

**Possible causes:**
- Nginx configuration issue
- Health check failure
- Application not listening on expected port
- Firewall blocking access

**Solutions:**
- Check Nginx configuration in `/opt/uds/nginx/`
- Verify health check response with `curl -v http://localhost:<port>/<health-check-path>`
- Use `docker logs <container>` to check application logs
- Verify port exposure with `docker port <container>`
- Check firewall settings with `ufw status` or equivalent

### 2. SSL Certificate Issues

#### Symptom: "Failed to obtain Let's Encrypt certificate" error

**Possible causes:**
- DNS not properly configured
- Port 80 blocked
- Rate limits exceeded
- Missing or invalid email address

**Solutions:**
- Verify DNS configuration with `dig <domain>`
- Ensure port 80 is accessible for HTTP challenge
- Use `--ssl-staging=true` for testing
- Provide a valid email with `ssl_email`
- For wildcard certificates, set up DNS provider credentials

#### Symptom: Certificate exists but site shows as insecure

**Possible causes:**
- Nginx not properly configured
- Certificate not renewed
- Mixed content on the website

**Solutions:**
- Check certificate expiration with `openssl x509 -enddate -noout -in /opt/uds/certs/<domain>/fullchain.pem`
- Verify Nginx configuration includes SSL directives
- Force renewal with `certbot renew --force-renewal`

### 3. Docker and Container Issues

#### Symptom: "Error starting container" or container exits immediately

**Possible causes:**
- Container configuration issues
- Resource constraints
- Application crashes on startup

**Solutions:**
- Check container logs with `docker logs <container>`
- Verify environment variables are set correctly
- Check resource usage with `docker stats`
- Try running the container manually to debug:
  ```bash
  docker run -it --rm <image>:<tag> /bin/sh
  ```

#### Symptom: Container starts but health check fails

**Possible causes:**
- Application not ready when health check runs
- Incorrect health check endpoint
- Health check timeout too short

**Solutions:**
- Increase `health_check_timeout` value
- Verify health check endpoint with `curl` or browser
- Set proper `health_check_type` for your application
- Check application logs to see if it's reporting readiness

### 4. Multi-Stage Deployment Issues

#### Symptom: Cutover stage fails with "Failed to move staging to production"

**Possible causes:**
- Permission issues
- Disk space issues
- File system errors

**Solutions:**
- Check disk space with `df -h`
- Verify directory permissions
- Check that no processes are keeping files open

#### Symptom: Rollback fails to restore previous version

**Possible causes:**
- Backup creation failed
- Registry data corruption
- No previous versions tracked

**Solutions:**
- Verify backup directory exists
- Check registry file for corruption
- Ensure `version_tracking` is enabled

### 5. Network and Routing Issues

#### Symptom: Container networking issues between services

**Possible causes:**
- Network not properly configured
- Container names resolution issues
- Port mapping problems

**Solutions:**
- Check Docker network with `docker network inspect <network>`
- Verify containers are on the same network
- Test connectivity from within containers:
  ```bash
  docker exec -it <container> ping <other-container>
  ```

#### Symptom: Nginx routing doesn't work correctly

**Possible causes:**
- Nginx configuration syntax error
- Incorrect route settings
- Nginx not reloaded after changes

**Solutions:**
- Validate Nginx configuration with `nginx -t`
- Check UDS Nginx configurations in `/opt/uds/nginx/`
- Manually reload Nginx with `nginx -s reload`
- Verify route settings in the configuration

### 6. Plugin-Related Issues

#### Symptom: Plugin doesn't activate or execute

**Possible causes:**
- Plugin not properly installed
- Plugin not included in configuration
- Permission issues

**Solutions:**
- Verify plugin exists in plugins directory
- Check that plugin is included in `plugins` configuration
- Check plugin permissions
- Enable debug logs to see plugin loading messages

#### Symptom: Plugin causes deployment failure

**Possible causes:**
- Plugin configuration issues
- Dependency conflicts
- Logic errors in plugin code

**Solutions:**
- Check plugin logs with `--log-level=debug`
- Try deployment without the plugin
- Verify plugin configuration settings

### 7. SSH and GitHub Actions Issues

#### Symptom: GitHub Action fails with SSH error

**Possible causes:**
- Invalid SSH key
- Host key verification issues
- Connection timeouts
- Permission issues on remote server

**Solutions:**
- Verify SSH key format and permissions
- Ensure server allows SSH connections
- Check that user has appropriate permissions
- Set longer connection timeout
- Verify the SSH key is correctly set in GitHub Secrets

#### Symptom: GitHub Action timeouts during deployment

**Possible causes:**
- Deployment takes too long
- Network issues
- Resource constraints on the server

**Solutions:**
- Increase GitHub Actions timeout in workflow file
- Check server load and resources
- Optimize deployment to be faster
- Consider breaking into smaller deployments

### 8. Database and Persistence Issues

#### Symptom: Data is lost after deployment

**Possible causes:**
- Volume not properly configured
- Persistence plugin not activated
- Container replaced without data migration

**Solutions:**
- Verify `persistent` option is set to `true`
- Check volume mappings in configuration
- Enable persistence-manager plugin
- Inspect volumes with `docker volume ls` and `docker volume inspect`

#### Symptom: Database migrations fail

**Possible causes:**
- Migration script errors
- Database connection issues
- Insufficient permissions

**Solutions:**
- Check migration script for errors
- Verify database credentials and connection string
- Ensure database user has required permissions
- Manually run migrations to debug

## Advanced Diagnostics

### Using UDS Debug Mode

For detailed debug output, use:

```bash
./scripts/uds-deploy.sh --config=config.json --log-level=debug
```

### Examining Deployment Logs

Logs are stored in the `/opt/uds/logs/` directory on the remote server:

```bash
ssh user@host cat /opt/uds/logs/uds.log
```

For audit logs (if security-manager is enabled):

```bash
ssh user@host cat /opt/uds/logs/audit.log
```

### Docker Container Inspection

To inspect a deployed container:

```bash
# Get container details
ssh user@host "docker inspect <app-name>-app"

# Check container logs
ssh user@host "docker logs <app-name>-app"

# Check container health
ssh user@host "docker inspect --format='{{.State.Health.Status}}' <app-name>-app"
```

### Checking Service Registry

Examine the service registry to understand the deployment state:

```bash
ssh user@host "cat /opt/uds/service-registry.json | jq '.services.\"<app-name>\"'"
```

## Recovery Procedures

### Manual Rollback

If automatic rollback fails, you can manually roll back:

```bash
ssh user@host "/opt/uds/uds-rollback.sh --config=/opt/uds/configs/<app-name>-config.json"
```

### Recovering from Registry Corruption

If the service registry becomes corrupted:

```bash
ssh user@host "cp /opt/uds/service-registry.json /opt/uds/service-registry.json.bak"
ssh user@host "echo '{\"services\":{}}' > /opt/uds/service-registry.json"
```

Note: This will lose all registry data. You'll need to re-register services manually.

### Recovering from Failed SSL Setup

If SSL setup fails:

```bash
# Clean up failed certificates
ssh user@host "rm -rf /opt/uds/certs/<domain>"

# Re-run with staging for testing
ssh user@host "SSL_STAGING=true /opt/uds/uds-deploy.sh --config=/opt/uds/configs/<app-name>-config.json"
```

## Preventative Measures

### Regular Maintenance

1. Monitor logs for unusual activity
2. Regularly update UDS
3. Set up system monitoring
4. Keep backups of critical configurations
5. Document custom configurations and plugins

### Testing New Deployments

1. Use a staging environment first
2. Enable multi-stage deployment
3. Test rollbacks periodically
4. Use health checks to verify application stability

By following this troubleshooting guide, you should be able to resolve most issues encountered when using the Unified Deployment System.
