# Monitoring & Alerting Setup Guide

Complete guide to deploying Prometheus and Grafana for Year 4 Project monitoring and alerting system.

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                    Metrics Collection Layer                     │
├─────────────────────────────────────────────────────────────────┤
│  Fluent Bit            Kubernetes       Applications             │
│  (port 2020)           (kubelet, API)   (prometheus.io/*)        │
│      │                       │                │                  │
│      └───────────────────────┼────────────────┘                  │
│                              │                                   │
│                         Prometheus                               │
│                    (scrapes targets)                             │
│                    • Time series DB                              │
│                    • 30s scrape interval                         │
│                    • 30-100GB storage                            │
└─────────────────────────────────────────────────────────────────┘
                              │
                ┌─────────────┼─────────────┐
                │             │             │
         ┌──────▼──────┐ ┌───▼────────┐ ┌─▼──────────┐
         │ Grafana     │ │ AlertMgr   │ │ Long-term  │
         │ Dashboards  │ │ Rules/     │ │ Storage    │
         │ • Cluster   │ │ Alerting   │ │ (S3/GCS)   │
         │ • Fluent Bit│ │ • Slack    │ │ • Archives │
         │ • Nodes     │ │ • Email    │ │ • Athena   │
         │ • Apps      │ │ • PagerDty │ │   queries  │
         └─────────────┘ └────────────┘ └────────────┘
             (UI)          (Notifications)  (Historical)
```

## Multi-Environment Strategy

### Development (Local Kind Cluster)
- **Prometheus**: 1 replica, 10Gi storage, 15s scrape interval
- **Grafana**: 1 replica, 5Gi storage
- **Retention**: 7 days (automatic cleanup)
- **Purpose**: Real-time metrics during development

### Staging (AWS EKS)
- **Prometheus**: 2 replicas (HA), 50Gi storage, 30s scrape interval
- **Grafana**: 2 replicas (HA), 20Gi storage
- **Retention**: 30 days
- **Purpose**: Test alerting rules, dashboards before production

### Production (AWS EKS)
- **Prometheus**: 3 replicas (HA), 100Gi storage, 30s scrape interval
- **Grafana**: 3 replicas (HA), 50Gi storage
- **Retention**: 90 days
- **Alerting**: Slack, email, PagerDuty
- **Purpose**: Production monitoring with SLA compliance

## Prerequisites

### Kubernetes Cluster
- EKS cluster created and accessible
- Persistent volume provisioner (AWS EBS)
- RBAC enabled
- Ingress controller (optional, for auth bypass)

### Tools
- `kubectl` configured for target cluster
- `helm` 3.x installed
- AWS CLI (for prod deployments)

### Storage
- EBS volumes available
- Performance: gp2 (dev/staging), gp3 (prod preferred)

## Deployment Steps

### Step 1: Create Monitoring Namespace

```bash
kubectl create namespace monitoring
kubectl label namespace monitoring monitoring=enabled
```

### Step 2: Deploy Prometheus (Development)

```bash
# Verify Helm chart
helm template prometheus ./helm/prometheus \
  -f helm/prometheus/values-dev.yaml \
  -n monitoring | head -20

# Deploy
helm install prometheus ./helm/prometheus \
  -f helm/prometheus/values-dev.yaml \
  -n monitoring

# Verify
kubectl get pods -n monitoring -l app=prometheus
kubectl get svc -n monitoring prometheus
```

### Step 3: Deploy Grafana (Development)

```bash
# Deploy
helm install grafana ./helm/grafana \
  -f helm/grafana/values-dev.yaml \
  -n monitoring

# Verify
kubectl get pods -n monitoring -l app=grafana
kubectl get svc -n monitoring grafana
```

### Step 4: Verify Metrics Collection

```bash
# Port-forward to Prometheus
kubectl port-forward -n monitoring svc/prometheus 9090:9090 &

# Check targets
curl http://localhost:9090/api/v1/targets | jq '.data.activeTargets | length'

# Query metrics
curl 'http://localhost:9090/api/v1/query?query=up' | jq '.data.result | length'
```

### Step 5: Access Grafana

```bash
# Port-forward
kubectl port-forward -n monitoring svc/grafana 3000:3000

# Open browser: http://localhost:3000
# Login: admin / changeme
```

### Step 6: Deploy to Staging (AWS EKS)

```bash
# Connect to staging cluster
aws eks update-kubeconfig --name year4-project-staging --region eu-west-1

# Create namespace
kubectl create namespace monitoring

# Deploy Prometheus
helm install prometheus ./helm/prometheus \
  -f helm/prometheus/values-staging.yaml \
  -n monitoring

# Deploy Grafana
helm install grafana ./helm/grafana \
  -f helm/grafana/values-staging.yaml \
  -n monitoring

# Verify
kubectl get pods -n monitoring
```

### Step 7: Configure Storage Classes (AWS)

For production, use better storage performance:

```bash
# Create gp3 storage class
kubectl apply -f - <<EOF
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: gp3
provisioner: ebs.csi.aws.com
parameters:
  type: gp3
  iops: "3000"
  throughput: "125"
allowVolumeExpansion: true
EOF

# Update values-prod.yaml to use gp3
# storageClass: "gp3"
```

### Step 8: Deploy to Production (AWS EKS)

```bash
# Connect to production cluster
aws eks update-kubeconfig --name year4-project-prod --region eu-west-1

# Create namespace
kubectl create namespace monitoring

# Deploy with dedicated nodes (if available)
helm install prometheus ./helm/prometheus \
  -f helm/prometheus/values-prod.yaml \
  -n monitoring

helm install grafana ./helm/grafana \
  -f helm/grafana/values-prod.yaml \
  -n monitoring

# Verify all 3 replicas running
kubectl get pods -n monitoring -o wide
```

## Alerting Configuration

### Built-in Alert Rules

Alert rules are configured in values files under `config.alertRules`:

#### Development Alerts
- `FluentBitHighErrors`: >10 errors/sec (warning)
- `PodEndingPhase`: Pod in Failed/Unknown (warning)
- `NodeNotReady`: Node unready (critical)

#### Staging Alerts
- All development alerts PLUS:
- `HighMemoryUsage`: Pod >90% memory (warning)
- `HighCPUUsage`: Pod >80% CPU (warning)

#### Production Alerts
- All staging alerts PLUS:
- `PersistentVolumeSpaceLow`: PV >85% full (warning)
- Enhanced severity levels (warning vs critical)

### Adding Custom Alert Rules

Edit `values-prod.yaml`:

```yaml
config:
  alertRules:
    - alert: CustomAlert
      expr: 'my_metric > 1000'
      for: 5m
      labels:
        severity: warning
        component: custom
      annotations:
        summary: "My custom alert triggered"
        description: "Value: {{ $value }}"
```

Then upgrade:

```bash
helm upgrade prometheus ./helm/prometheus \
  -f helm/prometheus/values-prod.yaml \
  -n monitoring
```

### AlertManager Integration (Future)

To extend alerting beyond built-in rules:

```bash
# 1. Deploy AlertManager
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm install alertmanager prometheus-community/kube-prometheus-stack \
  -n monitoring

# 2. Configure notification channels
# Edit AlertManager config to route to:
# - Slack webhooks
# - Email (SMTP)
# - PagerDuty
# - Opsgenie
# - Teams
```

## Key Metrics to Monitor

### Cluster Health
```promql
# Nodes available
count(kube_node_status_condition{condition="Ready",status="true"})

# Pods running
count(kube_pod_status_phase{phase="Running"})

# Deployment replicas ready
count(kube_deployment_status_replicas_updated) / count(kube_deployment_spec_replicas)
```

### Application Performance
```promql
# CPU usage by pod
rate(container_cpu_usage_seconds_total[5m])

# Memory usage by pod
container_memory_usage_bytes

# Pod restart rate (last hour)
increase(kube_pod_container_status_restarts_total[1h])
```

### Logging Pipeline
```promql
# Fluent Bit input records/sec
rate(fluentbit_input_records_total[5m])

# Fluent Bit error rate
rate(fluentbit_output_errors_total[5m])

# Fluent Bit success rate %
(1 - rate(fluentbit_output_errors_total[5m]) / rate(fluentbit_output_records_total[5m])) * 100
```

### Infrastructure
```promql
# Node CPU usage %
(1 - avg(irate(node_cpu_seconds_total{mode="idle"}[5m]))) * 100

# Node memory available %
(node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) * 100

# Disk usage %
(1 - (node_filesystem_avail_bytes / node_filesystem_size_bytes)) * 100
```

## Dashboard Usage

### Cluster Overview
- Real-time cluster CPU/memory usage
- Pod state distribution
- Network I/O rates
- **Use**: Daily health check

### Fluent Bit Monitoring
- Records flowing through pipeline
- Error rates and patterns
- Uptime tracking
- **Use**: Verify logging pipeline health

### Infrastructure Health
- Per-node resource utilization
- Disk I/O patterns
- Network interface stats
- **Use**: Capacity planning

### Pod Status
- Running vs failed pods
- Restart frequency
- Resource limits vs actual usage
- **Use**: Debug pod issues

### Application Alerts
- High memory consumers
- High CPU consumers
- Failed pods
- **Use**: Investigate performance

## Grafana Best Practices

### Dashboard Organization
```
Year 4 Project/
├── System Overview
│   ├── Cluster Summary
│   └── Node Details
├── Logging (Fluent Bit)
│   ├── Pipeline Health
│   ├── Error Analysis
│   └── Performance
├── Applications
│   ├── Auth Service
│   ├── User Service
│   └── Job Service
└── Infrastructure
    ├── Storage
    ├── Network
    └── Compute
```

### Creating Custom Dashboards

1. **Click "Create Dashboard"**
2. **Add panels** (graphs, tables, alerts)
3. **Write PromQL queries**:
   ```promql
   rate(container_cpu_usage_seconds_total{pod="auth-service"}[5m])
   ```
4. **Set visualization**: Graph, Gauge, Table, etc.
5. **Add threshold** for alerts
6. **Save & share**

### Dashboard Variables (Filtering)

Add dropdown selectors to dashboards:

```yaml
# In Grafana UI:
# Dashboard Settings → Variables → New
# Type: Query
# Query: label_values(kube_pod_info, namespace)
# Variable name: namespace

# Use in panels:
rate(container_cpu_usage_seconds_total{namespace="$namespace"}[5m])
```

## Common Queries

### Pod of Interest
```promql
# Show all containers of auth-service
container_memory_usage_bytes{pod=~"auth-service.*"}

# CPU rate for all user services
rate(container_cpu_usage_seconds_total{pod=~"user.*"}[5m])
```

### By Namespace
```promql
# Memory by namespace
sum by (namespace) (container_memory_usage_bytes)

# Pod count by namespace
count by (namespace) (kube_pod_info)
```

### Time Aggregation
```promql
# Last 5 minutes average
avg(rate(container_cpu_usage_seconds_total[5m]))

# Over last 1 hour
increase(container_network_receive_bytes_total[1h])

# Max in last 30 minutes
max_over_time(rate(fluentbit_output_errors_total[5m])[30m:1m])
```

### Named Metrics
```promql
# Top 5 memory consumers
topk(5, container_memory_usage_bytes)

# Bottom 5 (least used)
bottomk(5, container_memory_usage_bytes)

# Standard deviation
stddev(rate(container_cpu_usage_seconds_total[5m]))
```

## Troubleshooting

### Prometheus Can't Scrape Targets

**Problem**: Targets showing "Down" in Prometheus

**Diagnosis**:
```bash
# Port-forward to Prometheus
kubectl port-forward -n monitoring svc/prometheus 9090:9090

# Visit: http://localhost:9090/targets
# Check error messages for each target
```

**Solutions**:
1. **Pod annotations wrong format**:
   ```yaml
   annotations:
     prometheus.io/scrape: "true"  # Must be string "true"
     prometheus.io/port: "8080"    # Must be string port number
   ```

2. **Metrics port not exposed**: Ensure pod opens metrics port

3. **RBAC permission denied**: Check ClusterRole permissions

4. **DNS resolution**: Use FQDN if cross-namespace

### Grafana Dashboards Blank

**Problem**: Dashboard shows "No Data"

**Diagnosis**:
```bash
# Check Prometheus datasource
# Grafana UI → Configuration → Data Sources → Prometheus
# Click "Test" button

# Check query in Prometheus directly
kubectl port-forward -n monitoring svc/prometheus 9090:9090
# Try query at http://localhost:9090/graph
```

**Solutions**:
1. **Metrics not yet collected**: Prometheus scrapes every 30s, wait for data
2. **Query syntax error**: Validate in Prometheus UI first
3. **Wrong metric name**: Check available metrics in Prometheus

### High Memory Usage

**Prometheus Memory**:
- Increase `--storage.tsdb.mem-blocks`: More blocks in memory
- Decrease scrape interval to reduce TSB size
- Reduce retention period

**Grafana Memory**:
- High concurrent dashboard views consume more RAM
- Increase resources in values
- Add query caching layer

### Storage Filling Up

**Check usage**:
```bash
kubectl exec -n monitoring -it prometheus-0 -- \
  du -sh /prometheus

kubectl get pvc -n monitoring
kubectl describe pvc prometheus -n monitoring
```

**Solutions**:
1. **Increase PVC size**: Edit PVC spec
2. **Archive old data**: S3/GCS with retention policy
3. **Reduce retention**: `config.global.scrape_interval`

### Pod Crashes/Restarts

```bash
# Check logs
kubectl logs -n monitoring -l app=prometheus -f

# Check events
kubectl describe pod -n monitoring prometheus-0

# Common issues:
# - Insufficient disk space
# - Memory limit exceeded
# - Permission denied
```

## Cost Optimization

### Development
- Minimal resources: 250m CPU, 256Mi memory
- 10Gi storage (auto-cleanup after 7d)
- 1 replica
- **Monthly cost**: ~$15-20

### Staging  
- Standard resources: 500m CPU, 512Mi memory
- 50Gi storage (30d retention)
- 2 replicas
- **Monthly cost**: ~$50-75

### Production
- High resources: 1000m CPUs each, 1Gi memory minimum
- 100Gi storage (90d retention, gp3)
- 3 replicas
- S3 archival for >90 days
- **Monthly cost**: ~$200-300

### Cost-Saving Strategies
1. **Reduce scrape interval**: 60s instead of 30s (saves 50% storage)
2. **Archive to S3**: Move metrics >30d old to S3 (~$0.023/GB/month)
3. **Query sampling**: Record only 10% of high-volume metrics
4. **Smaller retention**: 14d instead of 30d (staging)

## Next Steps

### Immediate (This Week)
- [ ] Deploy Prometheus + Grafana to dev
- [ ] Verify metrics flowing from Fluent Bit
- [ ] Create custom dashboard for auth-service
- [ ] Test alert rules

### Short-term (Next Week)
- [ ] Deploy to staging EKS
- [ ] Configure Slack webhook for alerts
- [ ] Set up email notifications for production
- [ ] Document alert runbooks

### Medium-term (Later)
- [ ] Deploy AlertManager for complex alerting
- [ ] Create dashboards for each microservice
- [ ] Implement query sampling for large deployments
- [ ] Set up log archival to S3

### Long-term
- [ ] Federated Prometheus for multi-cluster
- [ ] Machine learning for anomaly detection
- [ ] Integrate with APM (application performance monitoring)
- [ ] Custom metrics from applications

## References

- [Prometheus Documentation](https://prometheus.io/docs/)
- [PromQL Query Guide](https://prometheus.io/docs/prometheus/latest/querying/basics/)
- [Grafana Dashboards](https://grafana.com/grafana/dashboards/)
- [Kubernetes Monitoring](https://kubernetes.io/docs/tasks/debug-application-cluster/resource-metrics-pipeline/)
- [Fluent Bit Metrics](https://docs.fluentbit.io/manual/administration/monitoring)
- [AlertManager Config](https://prometheus.io/docs/alerting/latest/configuration/)

## Support Commands

```bash
# Monitor Prometheus scrape performance
watch -n 5 'kubectl exec -n monitoring prometheus-0 \
  -- curl -s localhost:9090/api/v1/targets | jq ".data.activeTargets | length"'

# Tail all monitoring logs
kubectl logs -n monitoring -l app=prometheus -f &
kubectl logs -n monitoring -l app=grafana -f

# Check resource usage
kubectl top pods -n monitoring
kubectl top nodes

# Get metrics from Prometheus
kubectl port-forward -n monitoring svc/prometheus 9090:9090
# Then visit http://localhost:9090/graph
```

---

**Next Action**: Follow Step 1-5 to deploy locally, then Steps 6-8 for AWS EKS deployment
