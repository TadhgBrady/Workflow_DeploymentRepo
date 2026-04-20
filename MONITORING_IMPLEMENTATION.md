# Monitoring & Alerting Implementation Summary

## What's Been Created

### Prometheus Helm Chart (`helm/prometheus/`)
- ✅ Chart.yaml - Metadata (v1.0.0, Prometheus v2.50.1)
- ✅ values-dev.yaml - 1 replica, 10Gi, 15s intervals
- ✅ values-staging.yaml - 2 replicas HA, 50Gi, 30s intervals
- ✅ values-prod.yaml - 3 replicas HA, 100Gi, 30s intervals + alerts
- ✅ templates/configmap.yaml - Prometheus config & alert rules rendering
- ✅ templates/deployment.yaml - Deployment with liveness/readiness probes
- ✅ templates/service.yaml - ClusterIP service (port 9090)
- ✅ templates/serviceaccount.yaml - Service account for RBAC
- ✅ templates/clusterrole.yaml - Permissions for K8s API access
- ✅ templates/clusterrolebinding.yaml - Bind role to service account
- ✅ templates/_helpers.tpl - Template helpers
- ✅ README.md - Configuration reference

### Grafana Helm Chart (`helm/grafana/`)
- ✅ Chart.yaml - Metadata (v1.0.0, Grafana v10.2.2)
- ✅ values-dev.yaml - 1 replica, 5Gi, basic dashboards
- ✅ values-staging.yaml - 2 replicas HA, 20Gi, enhanced dashboards
- ✅ values-prod.yaml - 3 replicas HA, 50Gi, comprehensive dashboards
- ✅ templates/configmap.yaml - Datasources & dashboards provisioning (includes new Application Services Dashboard)
- ✅ templates/deployment.yaml - Deployment with init container for dashboards
- ✅ templates/pvc.yaml - Persistent volume claim for Grafana storage
- ✅ templates/service.yaml - ClusterIP service (port 3000)
- ✅ templates/serviceaccount.yaml - Service account
- ✅ templates/_helpers.tpl - Template helpers
- ✅ README.md - Configuration reference

### kube-state-metrics Deployment (`kube-state-metrics.yaml`)
- ✅ ServiceAccount - RBAC identity in kube-system namespace
- ✅ ClusterRole - Permissions to read Kubernetes objects (pods, nodes, deployments, etc.)
- ✅ ClusterRoleBinding - Bind role to service account
- ✅ Service - Exposes metrics on port 8080 for Prometheus scraping
- ✅ Deployment - Runs kube-state-metrics pod with resource limits

**Purpose**: Provides Kubernetes object state metrics that Prometheus scrapes:
- `kube_pod_status_phase` - Pod lifecycle states
- `kube_pod_container_status_restarts_total` - Container restart counts
- `kube_deployment_status_replicas` - Deployment replica status
- `kube_node_status_condition` - Node health

### Documentation
- ✅ MONITORING_SETUP.md - Complete deployment guide (step-by-step)
- ✅ Prometheus README - Config details and troubleshooting
- ✅ Grafana README - Usage guide and integrations

## Key Features Implemented

### Metrics Collection (Prometheus)
**Scrape Targets**:
- Prometheus itself (self-monitoring)
- Kubernetes API server (HTTPS)
- Kubernetes nodes (kubelet metrics)
- All pods (with prometheus.io/scrape=true annotation)
- Fluent Bit specifically (port 2020)
- kube-state-metrics (if installed)

**Alert Rules** (Production):
- `HighErrorRateKubelet`: Node errors >5%
- `FluentBitHighErrors`: >10 errors/sec
- `PodEndingPhase`: Failed/Unknown pods
- `NodeNotReady`: Unavailable nodes
- `HighMemoryUsage`: >90% memory (staging/prod)
- `HighCPUUsage`: >80% CPU (prod only)
- `PersistentVolumeSpaceLow`: >85% full (prod only)

### Metrics Storage
- **Dev**: 10Gi, 7-day retention
- **Staging**: 50Gi, 30-day retention
- **Prod**: 100Gi, 90-day retention

### Visualization (Grafana)
**Pre-configured Dashboards**:
1. **Cluster Overview**: CPU, memory, pod count, restart rates
2. **Fluent Bit**: Input/output rates, errors, retries
3. **Infrastructure Health**: Node metrics, disk I/O, network
4. **Pod Status**: Restarts, phase distribution, namespace counts
5. **Application Alerts** (staging/prod): Top consumers, failed pods

**Features**:
- Auto-provisioned datasources (Prometheus)
- Auto-provisioned dashboards
- Environment-specific metrics
- High availability setup (staging/prod)

### HA & Resilience

| Aspect | Dev | Staging | Prod |
|--------|-----|---------|------|
| Replicas | 1 | 2 | 3 |
| Pod Anti-affinity | — | Preferred | Required |
| Dedicated Nodes | — | — | Yes |
| Storage Class | standard | gp2 | gp3 |
| Scrape Interval | 15s | 30s | 30s |

### RBAC

**ClusterRole Permissions**:
- nodes, nodes/proxy, nodes/metrics: get, list, watch
- services, endpoints, pods: get, list, watch
- ingresses, deployments, statefulsets, daemonsets: get, list, watch
- `/metrics` endpoints: access

**Service Accounts**:
- prometheus: For metric scraping
- grafana: For dashboard serving

## Quick Start

### Deploy Locally (Dev)
```bash
# Create namespace
kubectl create namespace monitoring

# Deploy kube-state-metrics (required for Kubernetes object metrics)
kubectl apply -f kube-state-metrics.yaml

# Deploy Prometheus
helm install prometheus ./helm/prometheus \
  -f helm/prometheus/values-dev.yaml \
  -n monitoring

# Deploy Grafana
helm install grafana ./helm/grafana \
  -f helm/grafana/values-dev.yaml \
  -n monitoring

# Access
kubectl port-forward -n monitoring svc/grafana 3000:3000
# http://localhost:3000 (admin/changeme)
```

### Deploy to AWS EKS (Staging)
```bash
# Prerequisites
aws eks update-kubeconfig --name year4-project-staging --region eu-west-1
kubectl create namespace monitoring

# Deploy
helm install prometheus ./helm/prometheus \
  -f helm/prometheus/values-staging.yaml \
  -n monitoring

helm install grafana ./helm/grafana \
  -f helm/grafana/values-staging.yaml \
  -n monitoring

# Verify
kubectl get pods -n monitoring
```

See [MONITORING_SETUP.md](./MONITORING_SETUP.md) for detailed steps.

## Architecture Decisions

### Why Prometheus + Grafana?
- **Prometheus**: Industry standard for Kubernetes monitoring
- **Time-series database**: Efficient storage for metrics
- **Flexible scraping**: Works with any app exposing metrics
- **Grafana**: Rich visualization without learning PromQL deeply
- **Pre-built integrations**: Works out of the box with Fluent Bit, K8s

### Why Helm Charts (Not Operators)?
- Simpler to understand and customize
- Easier deployment across multiple environments
- Less overhead than full operators
- Can migrate to operators later if needed

### Why Multi-Replicas in Production?
- **HA**: If one pod fails, others continue
- **No data loss**: Each pod has own storage
- **Load distribution**: Queries spread across replicas
- **Maintenance**: Can drain nodes without downtime

### Why Different Storage Sizes?
- **Dev**: Little data, cleanup fast
- **Staging**: Moderate data, historical queries
- **Prod**: Large volumes, compliance retention

## Metrics Tracked

### Cluster Health
- Node readiness
- Pod phase distribution
- Deployment replica status
- Resource availability

### Application Performance
- Pod CPU/memory usage
- Container restart rates
- IP allocation status
- Network I/O

### Logging Pipeline
- Fluent Bit records/sec
- Output success rate
- Error frequency
- Retry patterns
- Processor throughput

### Infrastructure
- Node CPU/memory/disk
- Network bytes/errors
- Volume usage
- I/O performance

## Integration Points

### Already Integrated
- ✅ Fluent Bit metrics (port 2020)
- ✅ Kubernetes API server
- ✅ Kubernetes nodes (kubelet)
- ✅ Pod annotations (prometheus.io/*)

### Available for Future Integration
- ⏳ Slack alerting (via Grafana notification channels)
- ⏳ Email notifications
- ⏳ PagerDuty integration
- ⏳ Team alerts (Microsoft Teams)
- ⏳ Custom webhooks

### Can Be Added
- ⏳ AlertManager for complex routing
- ⏳ Prometheus Operator
- ⏳ Thanos for long-term storage
- ⏳ Victoria Metrics for higher scale

## Security Considerations

### RBAC
- Minimal permissions: Only what's needed
- Service account per component
- ClusterRole for cross-namespace access

### Credentials
- Grafana default password in values (CHANGE THIS!)
- Production: Use AWS Secrets Manager
- Admin account should be protected

### Network
- Services: ClusterIP (internal only)
- For external access: Use Ingress or AWS ALB
- Prometheus metrics endpoint: No authentication (internal)

### Data
- Metrics may contain sensitive info (pod names, resource usage)
- PVCs support encryption at rest (AWS EBS)
- Backup Grafana dashboards regularly

## Pre-Built Dashboards

### Application Services Dashboard (NEW)
**Location**: Grafana home → Application Services Dashboard

**Panels**:
1. **Total Kubernetes Targets** - Count of all scrape targets Prometheus monitors
2. **Healthy Targets** - Count of targets successfully scraped
3. **Scrape Targets Status Table** - Detailed table showing all targets (job, instance, status)
4. **Node Memory Available** - Time-series graph of available memory across nodes
5. **Service Metrics** - (Placeholder for service-level metrics)

**Metrics Used**:
- `up` - Whether target is reachable (from Prometheus itself)
- `node_memory_MemAvailable_bytes` - Available RAM on nodes
- Infrastructure-level metrics from Kubernetes/kubelet

**Data Requirements**:
- ✅ kube-state-metrics must be deployed (provides Kubernetes object state)
- ✅ Prometheus must be scraping nodes (kubelet metrics)
- ✅ Node exporter metrics (if nodes have node-exporter installed)

**Future Enhancement**:
To add application-specific metrics (HTTP requests, latency, errors):
1. Services must expose `/metrics` endpoint (Port 8080+)
2. Add `prometheus.io/scrape: "true"` annotation to pod spec
3. Prometheus will auto-discover and scrape

**Example service annotation**:
```yaml
annotations:
  prometheus.io/scrape: "true"
  prometheus.io/port: "8080"
  prometheus.io/path: "/metrics"
```

Then update Dashboard with queries like:
```promql
http_requests_total{job="my-service"}
histogram_quantile(0.95, http_request_duration_seconds{job="my-service"})
```

## Troubleshooting

### Metrics not appearing
1. Check Prometheus targets: `http://prometheus:9090/targets`
2. Verify pod annotations: `prometheus.io/scrape=true`
3. Check pod logs: `kubectl logs <pod>`
4. Verify metrics endpoint: `curl http://pod-ip:port/metrics`

### Grafana can't connect
1. Test Prometheus: Grafana UI → Data Sources → Prometheus → Test
2. Check service DNS: `nslookup prometheus.monitoring.svc.cluster.local`
3. Verify firewall rules (AWS SG)

### High resource usage
1. **Prometheus**: Reduce scrape interval, reduce retention
2. **Grafana**: Simplify dashboards, add caching
3. Both: Upgrade node resources

### Storage full
1. Check PVC: `kubectl get pvc -n monitoring`
2. Increase size: Edit PVC or storage class
3. Archive old data to S3
4. Reduce retention period

## Next Phase: Alerting

Current implementation has alert rules defined but no routing. To implement full alerting:

1. **Deploy AlertManager**
   ```bash
   helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
   helm install alertmanager prometheus-community/alertmanager \
     -n monitoring
   ```

2. **Configure Routes** (alert destination rules)
3. **Add Receivers** (Slack, email, etc.)
4. **Test Alerts** (trigger test alert)

See Phase 3 in [MONITORING_SETUP.md](./MONITORING_SETUP.md#step-xx-configure-alertmanager).

## File Structure

```
Repository Root/
├── helm/
│   ├── prometheus/                    (NEW - Metrics collection)
│   │   ├── Chart.yaml
│   │   ├── values-dev.yaml
│   │   ├── values-staging.yaml
│   │   ├── values-prod.yaml
│   │   ├── templates/
│   │   │   ├── configmap.yaml
│   │   │   ├── deployment.yaml
│   │   │   ├── service.yaml
│   │   │   ├── serviceaccount.yaml
│   │   │   ├── clusterrole.yaml
│   │   │   ├── clusterrolebinding.yaml
│   │   │   └── _helpers.tpl
│   │   └── README.md
│   │
│   ├── grafana/                       (NEW - Visualization)
│   │   ├── Chart.yaml
│   │   ├── values-dev.yaml
│   │   ├── values-staging.yaml
│   │   ├── values-prod.yaml
│   │   ├── templates/
│   │   │   ├── configmap.yaml
│   │   │   ├── deployment.yaml
│   │   │   ├── service.yaml
│   │   │   ├── serviceaccount.yaml
│   │   │   └── _helpers.tpl
│   │   └── README.md
│   │
│   ├── fluent-bit/                   (Existing - Logging)
│   └── wt-app/                       (Existing - Application)
│
└── MONITORING_SETUP.md                (NEW - Comprehensive guide)
```

## Metrics Available for Queries

### System Metrics
```promql
# Node metrics
node_cpu_seconds_total
node_memory_MemTotal_bytes
node_filesystem_size_bytes

# Container metrics
container_cpu_usage_seconds_total
container_memory_usage_bytes
container_network_receive_bytes_total

# Kubernetes metrics
kube_pod_status_phase
kube_deployment_status_replicas
kube_node_status_condition
```

### Application Metrics
```promql
# Fluent Bit
fluentbit_input_records_total
fluentbit_output_errors_total
fluentbit_output_retries_total
fluentbit_processor_bytes
```

### Example Dashboards Provided
- Cluster Overview (5 panels)
- Fluent Bit Pipeline (4-5 panels)
- Infrastructure Health (4 panels)
- Pod Status (3 panels)
- Application Alerts (3 panels)

All automatically provisioned and ready to use.

## Cost Analysis

### per Environment (Monthly estimate):

**Development (Local)**:
- Compute: Minimal (local workstation)
- Storage: $0 (test as needed)
- Total: $0

**Staging (AWS)**:
- 2 Prometheus pods: t3.small (2 x $0.023/hr) = $34
- 2 Grafana pods: t3.micro (2 x $0.011/hr) = $16
- 50Gi EBS (gp2): ~$2.50
- Data transfer out: ~$0.10
- **Total: ~$50-55/month**

**Production (AWS)**:
- 3 Prometheus pods: t3.medium (3 x $0.047/hr) = $101
- 3 Grafana pods: t3.small (3 x $0.023/hr) = $51
- 100Gi EBS (gp3): ~$10
- Data transfer out: ~$0.50
- Optional: S3 for archival = ~$2.30
- **Total: ~$160-170/month**

## Success Metrics

✅ **System is working when:**
1. Prometheus collects metrics from all targets
2. Grafana dashboards display data
3. Alert rules fire on test conditions
4. Infrastructure metrics visible for all nodes
5. Fluent Bit metrics flowing and healthy
6. Application pods metrics collected

⏳ **Next steps:**
1. Customize dashboards for your app
2. Configure alerting notifications
3. Set up performance baselines
4. Create runbooks for common alerts

---

**Implementation Date**: April 20, 2026
**Status**: ✅ Ready for Deployment
**Next Phase**: Deploy to staging/prod, configure alerting
