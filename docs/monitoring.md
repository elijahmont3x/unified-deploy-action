# Monitoring Integration Guide

This guide explains how to integrate monitoring tools with applications deployed using the Unified Deployment System (UDS).

## Overview

While UDS provides advanced health checks during deployment, comprehensive monitoring of your applications in production requires integration with specialized monitoring tools. This guide explains how to expose metrics from your applications and integrate with popular monitoring systems.

## UDS Health Check System

UDS includes a sophisticated health check system with automatic detection capabilities:

### Automatic Health Check Detection

UDS can automatically determine the appropriate health check type based on your container:

```json
{
  "health_check": "/health",
  "health_check_type": "auto",
  "health_check_timeout": 60
}
```

The system detects:
- **HTTP servers**: Node.js, Python, Ruby applications
- **Databases**: PostgreSQL, MySQL, MongoDB
- **Message queues**: RabbitMQ, Kafka
- **Search engines**: Elasticsearch
- **Cache systems**: Redis, Memcached

### Available Health Check Types

| Type | Description | Example Configuration |
|------|-------------|----------------------|
| `http` | Standard HTTP endpoint check | `"health_check": "/health"` |
| `tcp` | Checks if a port is open | `"health_check": ""` |
| `database` | Specialized database check | `"health_check_type": "database"` |
| `rabbitmq` | RabbitMQ status check | `"health_check_type": "rabbitmq"` |
| `elasticsearch` | Elasticsearch cluster health | `"health_check_type": "elasticsearch"` |
| `kafka` | Kafka broker check | `"health_check_type": "kafka"` |
| `container` | Uses container's built-in health check | `"health_check_type": "container"` |
| `command` | Uses a custom command | `"health_check_command": "./check.sh"` |

### Integration with Multi-Stage Deployment

Health checks are particularly important in multi-stage deployments where they:
1. Verify the application deployed successfully to staging
2. Confirm the application is working after cutover to production
3. Decide whether to proceed with deployment or rollback

## Application Requirements

### Health Check Endpoints

Applications should expose health check endpoints that provide meaningful status information:

```
GET /health
```

A good health check response should:

- Return HTTP 200 for a healthy service
- Include service dependencies status
- Be lightweight and fast to respond
- Not require authentication

Example response:

```json
{
  "status": "ok",
  "version": "1.0.3",
  "uptime": 12345,
  "dependencies": {
    "database": "ok",
    "cache": "ok",
    "messaging": "degraded"
  }
}
```

### Metrics Endpoints

For metrics collection, applications should expose a `/metrics` endpoint compatible with Prometheus:

```
GET /metrics
```

Example response:

```
# HELP http_requests_total The total number of HTTP requests
# TYPE http_requests_total counter
http_requests_total{method="post",code="200"} 1027
http_requests_total{method="get",code="200"} 12354
# HELP http_request_duration_seconds The HTTP request latencies in seconds
# TYPE http_request_duration_seconds histogram
http_request_duration_seconds_bucket{le="0.05"} 24054
http_request_duration_seconds_bucket{le="0.1"} 33444
http_request_duration_seconds_bucket{le="0.2"} 100392
```

## Integration with Monitoring Systems

### Prometheus + Grafana

1. **Prometheus Configuration**

   Add your applications to Prometheus's `prometheus.yml`:

   ```yaml
   scrape_configs:
     - job_name: 'myapp'
       scrape_interval: 15s
       metrics_path: /metrics
       static_configs:
         - targets: ['myapp-host:3000']
   ```

2. **Grafana Dashboard**

   Create dashboards in Grafana using the metrics from Prometheus. Start with our template dashboards in the `monitoring/dashboards` directory.

### ELK Stack

1. **Log Formatting**

   UDS applications should log in JSON format for easier parsing:

   ```json
   {"timestamp":"2023-05-01T12:34:56Z","level":"info","message":"Request processed","requestId":"abc123","duration":45}
   ```

2. **Filebeat Configuration**

   ```yaml
   filebeat.inputs:
   - type: log
     enabled: true
     paths:
       - /var/log/myapp/*.log
     json.keys_under_root: true
     json.add_error_key: true
   ```

### Datadog

1. **Agent Installation**

   Install the Datadog agent on your host:

   ```bash
   DD_API_KEY=<DATADOG_API_KEY> bash -c "$(curl -L https://raw.githubusercontent.com/DataDog/datadog-agent/master/cmd/agent/install_script.sh)"
   ```

2. **Application Integration**

   Add the Datadog environment variables to your UDS configuration:

   ```json
   "env_vars": {
     "DD_AGENT_HOST": "localhost",
     "DD_TRACE_ENABLED": "true",
     "DD_SERVICE_NAME": "my-service",
     "DD_ENV": "production"
   }
   ```

## Advanced Monitoring Configuration

### Custom Prometheus Exporters

For applications that don't natively expose Prometheus metrics, you can use exporters such as:

- Node Exporter for hardware and OS metrics
- MySQL Exporter for MySQL database metrics
- Redis Exporter for Redis metrics

Add these exporters to your UDS configuration as additional services.

### Alerting

Configure alerts in your monitoring system based on critical indicators:

- High error rates (>1% of requests)
- Increased latency (p95 > 500ms)
- Resource constraints (CPU > 80%, memory > 85%)
- Disk space issues (< 10% free)

## Best Practices

1. **Use structured logging** - Format logs as JSON for easier parsing
2. **Include request IDs** - Add correlation IDs to logs for tracing request flows
3. **Monitor the golden signals**:
   - Latency
   - Traffic
   - Errors
   - Saturation
4. **Set appropriate thresholds** - Establish baselines before setting alert thresholds
5. **Implement log rotation** - Prevent disk space issues from log growth

## Troubleshooting

### Common Issues

1. **Missing metrics**
   - Check if the application is exposing the metrics endpoint
   - Verify network connectivity between Prometheus and your application

2. **Log parsing failures**
   - Validate log format against expected schema
   - Check for malformed JSON entries

3. **False alerts**
   - Review and adjust alert thresholds
   - Add dampening to reduce alert noise

## Additional Resources

- [Prometheus Documentation](https://prometheus.io/docs/)
- [Grafana Dashboard Examples](https://grafana.com/grafana/dashboards/)
- [ELK Stack Documentation](https://www.elastic.co/guide/index.html)
- [Datadog Integration Guide](https://docs.datadoghq.com/integrations/)
