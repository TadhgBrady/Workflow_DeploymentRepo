# Grafana Helm Chart

Grafana visualization dashboards for Year 4 Project metrics from Prometheus.

## Overview

This Helm chart deploys Grafana with pre-configured:
- Prometheus datasource connection
- Cluster overview dashboard
- Fluent Bit pipeline monitoring
- Node infrastructure metrics
- Application services dashboard with service-level metrics
- Automatic monitoring of Kubernetes objects via kube-state-metrics

## Features

- **Pre-configured dashboards**: Out-of-the-box dashboards for common monitoring needs
- **Prometheus integration**: Auto-connected to Prometheus datasource
- **Multi-environment**: Dev (1 replica), Staging (2 replicas HA), Production (3 replicas HA)
- **Persistence**: Grafana data stored in PVC
- **Security**: Non-root container, read-only root filesystem
- **Auto-provisioning**: Datasources and dashboards automatically provisioned

## Installation

### Development
```bash
helm install grafana ./helm/grafana \
  -n monitoring \
  -f helm/grafana/values-dev.yaml
```

### Staging
```bash
helm install grafana ./helm/grafana \
  -n monitoring \
  -f helm/grafana/values-staging.yaml
```

### Production
```bash
helm install grafana ./helm/grafana \
  -n monitoring \
  -f helm/grafana/values-prod.yaml
```

## Access

### Port-Forward (Local Development)
```bash
kubectl port-forward -n monitoring svc/grafana 3000:3000
# Visit http://localhost:3000
```

### Credentials
- **Username**: `admin`
- **Password**: See values file (default: `changeme` - CHANGE THIS!)

### AWS Services
- Query at: `http://grafana.monitoring.svc.cluster.local:3000`
- Expose via Ingress for external access

## Default Dashboards

### 1. Cluster Overview
- Cluster CPU usage percentage
- Cluster memory usage percentage
- Pod count by namespace
- Container restart rate

### 2. Fluent Bit Monitoring
- Input records per second
- Output success rate
- Error rate
- Retry count
- Uptime tracking

### 3. Infrastructure Health
- Node CPU usage
- Node memory availability
- Disk I/O metrics
- Network interface stats

### 4. Pod Status
- Pod restart counts
- Pod phase distribution
- Pods per namespace

### 5. Application Services Dashboard
- Total Kubernetes targets monitored
- Healthy vs unhealthy targets
- Scrape target status table
- Node memory availability
- Service-level CPU and memory usage

**Note:** This dashboard requires kube-state-metrics to be deployed. Deploy with:
```bash
kubectl apply -f ../../kubernetes/observability/kube-state-metrics.yaml
```

For full application metrics (HTTP requests, latency, errors), services must expose `/metrics` endpoint.

### 6. Application Alerts (Staging/Prod)
- Failed pods count
- Top 5 high-memory pods
- Top 5 high-CPU pods

## Configuration

### Datasources
Configured in `config.datasources`:
```yaml
datasources:
  - name: Prometheus
    type: prometheus
    url: http://prometheus:9090
    access: proxy
    isDefault: true
```

### Custom Dashboards

To add custom dashboards:

1. Edit the dashboard in Grafana UI
2. Export as JSON
3. Create ConfigMap:
   ```bash
   kubectl create configmap grafana-dashboard-custom \
     --from-file=custom.json \
     -n monitoring
   ```
4. Mount in deployment via values

## Performance Tuning

### High Memory Usage
```yaml
persistence:
  size: 10Gi  # Increase from 5Gi/20Gi/50Gi
```

### Slow Dashboard Loading
- Increase resources
- Add caching layer (Redis)
- Simplify dashboard queries

### High Disk I/O
- Increase storage class performance (gp3 > gp2)
- Enable query caching

## Security Considerations

### Change Default Password
```bash
# Edit values file
adminPassword: "secure-password-here"

# Or via Grafana UI after deployment
# Admin > Preferences > Password
```

### Use HTTPS
Add to values:
```yaml
env:
  GF_SERVER_PROTOCOL: https
  GF_SERVER_CERT_FILE: /path/to/cert
  GF_SERVER_KEY_FILE: /path/to/key
```

### Restrict Anonymous Access
```yaml
env:
  GF_AUTH_ANONYMOUS_ENABLED: "false"
```

### Use AWS Secrets Manager (Production)
```yaml
# Store password in AWS Secrets Manager
# Mount via external-secrets-operator
```

## Troubleshooting

### Grafana not connecting to Prometheus
```bash
# Check datasource status
kubectl port-forward -n monitoring svc/grafana 3000:3000
# Grafana UI → Configuration → Data Sources → Prometheus
# Check "Test" button
```

### Dashboards not loading
1. Check ConfigMap: `kubectl get cm -n monitoring`
2. Verify provisioning path: `/etc/grafana/provisioning/dashboards`
3. Check logs: `kubectl logs -n monitoring -l app=grafana`

### High memory usage
1. Check running queries: Grafana UI → Explore
2. Simplify dashboard queries
3. Increase pod memory limit

### Persistent data lost after restart
```bash
# Check PVC status
kubectl get pvc -n monitoring
kubectl describe pvc grafana -n monitoring
```

## Upgrade

```bash
helm upgrade grafana ./helm/grafana \
  -n monitoring \
  -f helm/grafana/values-prod.yaml
```

## Integrations

### With AlertManager
Set up notification channels in Grafana:
1. Alerting → Notification channels
2. Add webhook: `http://alertmanager:9093/api/v1/alerts`

### With Slack
1. Create Slack webhook
2. Grafana → Alerting → Notification channels
3. Type: Slack
4. Paste webhook URL

### With Email
1. Configure SMTP in values:
```yaml
env:
  GF_SMTP_ENABLED: "true"
  GF_SMTP_HOST: "smtp.gmail.com:587"
  GF_SMTP_USER: "your-email@gmail.com"
  GF_SMTP_PASSWORD: "your-app-password"
```

## Backup & Restore

### Backup Grafana Data
```bash
kubectl exec -it -n monitoring grafana-0 -- \
  tar czf - /var/lib/grafana > grafana-backup.tar.gz
```

### Restore
```bash
kubectl cp grafana-backup.tar.gz monitoring/grafana-0:/tmp/
kubectl exec -it -n monitoring grafana-0 -- \
  tar xzf /tmp/grafana-backup.tar.gz -C /
```

## Cost Analysis

### Storage
- Dev: 5Gi @ ~$0.27/month
- Staging: 20Gi @ ~$1.06/month
- Prod: 50Gi @ ~$2.66/month

### Compute
- Dev: 1 pod, 100m CPU / 128Mi memory
- Staging: 2 pods, 250m CPU / 256Mi memory
- Prod: 3 pods on dedicated nodes

## References

- [Grafana Documentation](https://grafana.com/docs/grafana/latest/)
- [Prometheus Data Source](https://grafana.com/docs/grafana/latest/datasources/prometheus/)
- [Dashboard Building](https://grafana.com/docs/grafana/latest/dashboards/build-dashboards/)
- [Alerting](https://grafana.com/docs/grafana/latest/alerting/)
