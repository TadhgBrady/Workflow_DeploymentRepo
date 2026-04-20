# Prometheus Helm Chart

Prometheus metrics collection for Year 4 Project monitoring stack.

## Overview

This Helm chart deploys Prometheus to collect application and infrastructure metrics from:
- Kubernetes API server, nodes, and kubelet
- Fluent Bit logging pipeline metrics
- kube-state-metrics (pod/deployment status)
- Application metrics (pods with Prometheus scrape annotations)

## Features

- **Multi-environment support**: Dev (1 replica), Staging (2 replicas), Production (3 replicas HA)
- **Flexible scraping**: YAML-based scrape configurations
- **Alerting rules**: Pre-configured alert rules for common issues
- **Persistent storage**: PVC-backed storage for metrics retention
- **RBAC**: Secure service account and cluster role configuration
- **Pod anti-affinity**: Distribute replicas across nodes (staging/prod)

## Installation

### Development (Local)
```bash
helm install prometheus ./helm/prometheus \
  -n monitoring \
  -f helm/prometheus/values-dev.yaml
```

### Staging (AWS)
```bash
helm install prometheus ./helm/prometheus \
  -n monitoring \
  -f helm/prometheus/values-staging.yaml
```

### Production (AWS)
```bash
helm install prometheus ./helm/prometheus \
  -n monitoring \
  -f helm/prometheus/values-prod.yaml
```

## Configuration

### Global Settings
- `scrape_interval`: How often to collect metrics (15s dev, 30s staging/prod)
- `evaluation_interval`: How often to evaluate alert rules
- `external_labels`: Added to all metrics for environment identification

### Scrape Jobs

#### prometheus
- Prometheus's own metrics for self-monitoring

#### kubernetes-apiservers  
- Kubernetes API server metrics via HTTPS

#### kubernetes-nodes
- Node-level metrics (CPU, memory, disk)

#### kubernetes-pods
- All pod metrics (respects `prometheus.io/scrape: "true"` annotation)

#### fluent-bit
- Fluent Bit metrics via port 2020
  - Input records count
  - Output errors
  - Retry attempts

#### kube-state-metrics
- Kubernetes object state (if installed)
  - Pod phase and conditions
  - Deployment replicas
  - Node readiness

## Metrics Collected

### Infrastructure
- Node CPU, memory, disk usage
- Network bytes/errors
- Volume usage

### Application  
- Pod CPU, memory usage
- Container restarts
- Pod phase (running, failed, pending)

### Logging
- Fluent Bit records processed
- CloudWatch/Elasticsearch send errors
- Retry counts

## Alert Rules

### Critical Alerts
- `NodeNotReady`: Node unavailable (5m)
- `HighCPUUsage`: Pod using >80% CPU (prod only, 5m)

### Warning Alerts
- `FluentBitHighErrors`: >10 errors/sec from Fluent Bit
- `PodEndingPhase`: Pod in Failed/Unknown phase (5m)
- `HighMemoryUsage`: Pod >90% memory limit (staging/prod)
- `HighErrorRateKubelet`: Node errors >5% (5m)

### Storage Alert (Production)
- `PersistentVolumeSpaceLow`: PV >85% full

## Environment-Specific Notes

### Development
- 1 replica for resource efficiency
- 10Gi storage (daily rotation)
- Debug metrics from Fluent Bit/Prometheus
- Scrape every 15 minutes (less frequent)

### Staging
- 2 replicas with pod anti-affinity for redundancy
- 50Gi storage (30-day retention ~30 days of data)
- Scrape every 30 seconds
- Additional memory/CPU alerts

### Production  
- 3 replicas with required pod anti-affinity (HA)
- 100Gi storage (90-day retention)
- Dedicated monitoring nodes (workload=monitoring)
- Enhanced alerting for CPU/memory/storage
- Faster scraping (30s) and evaluation

## Accessing Prometheus

### Port-Forward (Local)
```bash
kubectl port-forward -n monitoring svc/prometheus 9090:9090
# Visit http://localhost:9090
```

### AWS Services
- Query at: `http://prometheus.monitoring.svc.cluster.local:9090`
- Expose via Ingress or AWS ALB if external access needed

## Custom Metrics

To scrape metrics from your application pods:

1. **Enable metrics endpoint** in your application (on any port)

2. **Add annotations** to pod spec:
```yaml
annotations:
  prometheus.io/scrape: "true"
  prometheus.io/port: "8080"  # Change to your metrics port
  prometheus.io/path: "/metrics"  # Change if different path
```

3. **Metrics will be scraped** automatically

## Queries

### Common PromQL Queries

```promql
# CPU usage per pod
rate(container_cpu_usage_seconds_total[5m])

# Memory usage per pod (bytes)
container_memory_usage_bytes

# Pod restart count
kube_pod_container_status_restarts_total

# Fluent Bit errors
rate(fluentbit_output_errors_total[5m])

# Node memory available
node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes

# Disk usage %
(kubelet_volume_stats_used_bytes / kubelet_volume_stats_capacity_bytes) * 100
```

## Troubleshooting

### Prometheus not scraping targets
```bash
# Check Prometheus targets
kubectl port-forward -n monitoring svc/prometheus 9090:9090
# Visit http://localhost:9090/targets
# Look for "Down" targets and check error messages
```

### Missing metrics
1. Check pod has `prometheus.io/scrape: "true"` annotation
2. Verify metrics endpoint on correct port/path
3. Check RBAC permissions: `kubectl get clusterrole prometheus -o yaml`

### High memory usage
- Increase `--storage.tsdb.retention.time` in values (default 15d)
- Reduce `scrape_interval` or sample limit
- Add more storage or increase pod resources

### Disk space filling up
```bash
# Check PVC usage
kubectl get pvc -n monitoring
kubectl describe pvc prometheus-storage -n monitoring

# Increase PVC size or enable log rotation
```

## Upgrading

### Re-deploy with new values
```bash
helm upgrade prometheus ./helm/prometheus \
  -n monitoring \
  -f helm/prometheus/values-prod.yaml
```

### Retain data during upgrades
- Persistent volumes are preserved
- Metrics stored in `/prometheus` survive pod restarts

## Cost Considerations

### Storage Costs (AWS EBS)
- Dev: 10Gi @ ~$0.53/month
- Staging: 50Gi @ ~$2.65/month  
- Prod: 100Gi @ ~$5.30/month
- High-performance gp3: +50% cost for better latency

### Compute Costs
- Dev: 1 pod (low CPU/memory)
- Staging: 2 pods (standard)
- Prod: 3 pods on dedicated nodes (premium)

## References

- [Prometheus Documentation](https://prometheus.io/docs/)
- [PromQL Query Language](https://prometheus.io/docs/prometheus/latest/querying/basics/)
- [Kubernetes Metrics](https://kubernetes.io/docs/tasks/debug-application-cluster/resource-metrics-pipeline/)
- [Fluent Bit Metrics](https://docs.fluentbit.io/manual/administration/monitoring)
