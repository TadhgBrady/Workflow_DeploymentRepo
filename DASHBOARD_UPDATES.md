# Dashboard Updates - April 20, 2026

## Changes Made

### 1. Application Services Dashboard Created
**File**: `helm/grafana/templates/configmap.yaml`

A new dashboard was created to monitor application services and Kubernetes infrastructure:

**Dashboard Name**: Application Services Dashboard
**UID**: app-services-monitoring
**Location**: Grafana home → Find "Application Services Dashboard"

**Panels**:
1. **Total Kubernetes Targets** (Stat) - Shows total number of targets Prometheus is monitoring
2. **Healthy Targets** (Stat) - Shows how many targets are successfully being scraped
3. **Scrape Targets Status** (Table) - Detailed view of each scrape target (job, instance, status)
4. **Node Memory Available** (Time-series Graph) - Memory availability trends over time
5. **Service Metrics** (Placeholder) - Ready for service-level application metrics

**Metrics Tracked**:
- `up{job="..."}` - Target health/availability
- `node_memory_MemAvailable_bytes` - Node memory availability

### 2. kube-state-metrics Deployed
**File**: New file `kube-state-metrics.yaml`

Deployed kube-state-metrics to provide Kubernetes object state metrics:

**Components**:
- ServiceAccount: `kube-state-metrics` in `kube-system` namespace
- ClusterRole: Permissions to read all Kubernetes objects
- Service: Exposes metrics on port 8080
- Deployment: Single replica with resource limits

**Metrics Provided**:
- `kube_pod_status_phase` - Pod lifecycle states (Running, Pending, Failed, etc.)
- `kube_pod_container_status_restarts_total` - Container restart counts
- `kube_deployment_status_replicas` - Deployment replica status
- `kube_node_status_condition` - Node health conditions

**Status**: ✅ Successfully deployed and running in kube-system namespace

### 3. Documentation Updated

#### MONITORING_QUICK_START.md
- Added kube-state-metrics to quick start deployment instructions
- Updated "What You Just Got" to include kube-state-metrics
- Added Application Services Dashboard to pre-built dashboards section
- Documented new dashboard panels and use cases

#### helm/grafana/README.md
- Updated Overview section to mention kube-state-metrics
- Added Application Services Dashboard as new dashboard (Dashboard #5)
- Included deployment instructions for kube-state-metrics
- Documented metrics tracked in the new dashboard

#### MONITORING_IMPLEMENTATION.md
- Added kube-state-metrics deployment files to "What's Been Created"
- Updated quick start deployment to include kube-state-metrics
- Added new section "Pre-Built Dashboards" with Application Services Dashboard details
- Documented how to extend dashboard with application metrics
- Added example Prometheus annotations for services exposing metrics

## Current State

### Dashboards Available in Grafana

1. **Cluster Overview** - CPU, memory, pod count, restart rate
2. **Fluent Bit Monitoring** - Logging pipeline metrics
3. **Infrastructure Health** - Node-level metrics
4. **Pod Status** - Pod restarts and status distribution
5. **Application Services Dashboard** ✅ NEW - Service health and resource usage
6. **Application Alerts** (Staging/Prod) - Failed pods, high CPU/memory

### Metrics Collection Status

**Available Now**:
- ✅ Prometheus self-metrics
- ✅ Kubernetes API server metrics
- ✅ Node/kubelet metrics
- ✅ Docker container metrics
- ✅ Fluent Bit pipeline metrics
- ✅ kube-state-metrics (Kubernetes object state)

**Available When Services Expose Metrics**:
- ⏳ HTTP request metrics
- ⏳ Application latency metrics
- ⏳ Application error rates
- ⏳ Custom business metrics

## Next Steps

### To Add Application Metrics to Dashboard

1. **Update service deployments** to expose metrics endpoint:
```yaml
annotations:
  prometheus.io/scrape: "true"
  prometheus.io/port: "8080"
  prometheus.io/path: "/metrics"
```

2. **Services must include Prometheus client library**:
   - Java: micrometer or prometheus-client
   - Node.js: prom-client
   - Python: prometheus-client
   - Go: prometheus/client_golang

3. **Update Application Services Dashboard** with new queries:
```promql
http_requests_total{job="service-name"}
histogram_quantile(0.95, http_request_duration_seconds)
rate(http_requests_total{status=~"5.."}[5m])
```

### To Deploy to AWS Staging

```bash
aws eks update-kubeconfig --name year4-project-staging --region eu-west-1
kubectl create namespace monitoring

# Deploy kube-state-metrics
kubectl apply -f kube-state-metrics.yaml

# Deploy Prometheus
helm install prometheus ./helm/prometheus \
  -f helm/prometheus/values-staging.yaml \
  -n monitoring

# Deploy Grafana
helm install grafana ./helm/grafana \
  -f helm/grafana/values-staging.yaml \
  -n monitoring
```

### To Deploy AlertManager (Future)

Once alerting is configured:
- Deploy AlertManager Helm chart
- Configure notification channels (Slack, email, PagerDuty)
- Route alerts from Prometheus to AlertManager
- Test alert firing with synthetic loads

## Files Modified/Created

| File | Status | Change |
|------|--------|--------|
| helm/grafana/templates/configmap.yaml | Modified | Added Application Services Dashboard ConfigMap |
| helm/grafana/templates/deployment.yaml | Modified | Updated init container to provision new dashboard |
| kube-state-metrics.yaml | Created | New deployment for Kubernetes metrics |
| MONITORING_QUICK_START.md | Modified | Added dashboard info and kube-state-metrics steps |
| helm/grafana/README.md | Modified | Updated dashboards section with new dashboard |
| MONITORING_IMPLEMENTATION.md | Modified | Added pre-built dashboards section and implementation details |

## Verification Commands

```bash
# Verify kube-state-metrics is running
kubectl get pods -n kube-system | grep kube-state-metrics

# Verify Prometheus is scraping kube-state-metrics
kubectl port-forward -n monitoring svc/prometheus 9090:9090
# Visit http://localhost:9090/targets - should see kube-state-metrics target

# Verify Grafana has new dashboard
kubectl port-forward -n monitoring svc/grafana 3000:3000
# Visit http://localhost:3000 - login and find "Application Services Dashboard"
```

## Known Limitations

1. **No application-level metrics yet** - Dashboard shows infrastructure only until services expose `/metrics`
2. **Limited historical data** - Metrics retention:
   - Dev: 7 days (15s intervals)
   - Staging: 14 days (30s intervals)
   - Prod: 30 days (30s intervals)
3. **No alerting routing** - Alert rules defined but not sent to external systems yet
4. **Manual scaling** - StatefulSet replicas not auto-scaling yet

## Success Metrics

✅ Application Services Dashboard created and deployed
✅ kube-state-metrics providing Kubernetes metrics
✅ Documentation updated to reflect changes
✅ Grafana successfully displays infrastructure metrics
✅ Ready for application-level metric integration

