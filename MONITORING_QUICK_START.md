# Monitoring Stack Quick Reference

## What You Just Got

A complete **Prometheus + Grafana** monitoring and alerting stack with:
- ✅ Metrics collection from Kubernetes, Fluent Bit, node metrics, and kube-state-metrics
- ✅ Time-series database with environment-specific retention (7-90 days)
- ✅ Pre-built visual dashboards for cluster, logging, and application services
- ✅ Alert rules for critical conditions (nodes down, high errors, etc.)
- ✅ High availability setup for production (3 replicas)
- ✅ Environment-specific configurations (dev/staging/prod)
- ✅ kube-state-metrics for Kubernetes object state tracking

## Files Created

### Prometheus Helm Chart
```
helm/prometheus/
├── Chart.yaml                 # Metadata
├── values-dev.yaml           # Dev config (1 replica, 10Gi)
├── values-staging.yaml       # Staging config (2 replicas HA, 50Gi)
├── values-prod.yaml          # Prod config (3 replicas HA, 100Gi)
├── templates/
│   ├── configmap.yaml        # Prometheus config + alert rules
│   ├── deployment.yaml       # Pod definition
│   ├── service.yaml          # Port 9090
│   ├── serviceaccount.yaml   # RBAC identity
│   ├── clusterrole.yaml      # Permissions
│   ├── clusterrolebinding.yaml # Role binding
│   └── _helpers.tpl          # Template utilities
└── README.md                 # Configuration guide
```

### Grafana Helm Chart
```
helm/grafana/
├── Chart.yaml                # Metadata
├── values-dev.yaml           # Dev config (1 replica, 5Gi)
├── values-staging.yaml       # Staging config (2 replicas HA, 20Gi)
├── values-prod.yaml          # Prod config (3 replicas HA, 50Gi)
├── templates/
│   ├── configmap.yaml        # Datasources + dashboards
│   ├── deployment.yaml       # Pod definition with init container
│   ├── service.yaml          # Port 3000
│   ├── serviceaccount.yaml   # RBAC identity
│   └── _helpers.tpl          # Template utilities
└── README.md                 # Usage guide
```

### Documentation
- **MONITORING_SETUP.md** - Complete step-by-step deployment guide
- **MONITORING_IMPLEMENTATION.md** - What was built and how to use it
- **helm/prometheus/README.md** - Prometheus configuration details
- **helm/grafana/README.md** - Grafana dashboard usage
- **DEPLOYMENT_CHECKLIST.md** - Updated with Phase 6 monitoring steps

## Quick Start

### Deploy Locally (Development)

**1 minute setup:**
```bash
# Create namespace
kubectl create namespace monitoring

# Deploy kube-state-metrics (required for Kubernetes metrics)
kubectl apply -f kube-state-metrics.yaml

# Deploy Prometheus
helm install prometheus ./helm/prometheus \
  -f helm/prometheus/values-dev.yaml \
  -n monitoring

# Deploy Grafana
helm install grafana ./helm/grafana \
  -f helm/grafana/values-dev.yaml \
  -n monitoring
```

**Access:**
```bash
# Prometheus
kubectl port-forward -n monitoring svc/prometheus 9090:9090
# Visit http://localhost:9090

# Grafana dashboards
kubectl port-forward -n monitoring svc/grafana 3000:3000
# Visit http://localhost:3000 (admin/changeme)
```

### Deploy to AWS EKS (Staging/Prod)

See [MONITORING_SETUP.md](./MONITORING_SETUP.md) Step 6-8 for detailed AWS deployment.

```bash
# Switch cluster
aws eks update-kubeconfig --name year4-project-{staging|prod} --region eu-west-1

# Create namespace
kubectl create namespace monitoring

# Deploy
helm install prometheus ./helm/prometheus \
  -f helm/prometheus/values-{staging|prod}.yaml \
  -n monitoring

helm install grafana ./helm/grafana \
  -f helm/grafana/values-{staging|prod}.yaml \
  -n monitoring
```

## Key Metrics Collected

### From Fluent Bit (Logging Pipeline)
```
fluentbit_input_records_total       # Records flowing in
fluentbit_output_errors_total       # Send failures
fluentbit_output_retries_total      # Retry attempts
fluentbit_processor_bytes           # Data processed
fluentbit_uptime                    # Pod uptime
```

### From Kubernetes
```
kube_pod_status_phase               # Pod state (running/failed/pending)
kube_deployment_status_replicas     # Ready replicas
kube_node_status_condition          # Node health
```

### From Container Runtime
```
container_cpu_usage_seconds_total   # CPU utilization
container_memory_usage_bytes        # Memory usage
container_network_receive_bytes     # Network I/O
```

## Pre-built Dashboards

### Cluster Overview
**What it shows:**
- Cluster total CPU usage %
- Cluster total memory usage %
- Pod distribution by namespace
- Container restart rate

**Use case:** Daily health check

**Panels:** 4 graphs

### Fluent Bit Monitoring
**What it shows:**
- Input records/sec (how much data flowing)
- Success rate (% of logs delivered)
- Error rate (send failures)
- Retry count (resilience tracking)
- Uptime (pod stability)

**Use case:** Verify logging pipeline health

**Panels:** 5 graphs

### Infrastructure Health
**What it shows:**
- Per-node CPU usage %
- Per-node memory available %
- Disk I/O (read/write MB/s)
- Network interface stats

**Use case:** Capacity planning and debugging

**Panels:** 4 graphs

### Pod Status
**What it shows:**
- Pod restarts (how many crashed)
- Pod phase distribution (running vs failed)
- Pods per namespace

**Use case:** Investigate pod issues

**Panels:** 3 tables/graphs

### Application Services Dashboard (NEW)
**What it shows:**
- Total Kubernetes targets being monitored
- Number of healthy targets
- Scrape target status table (all monitored endpoints)
- Node memory availability over time
- Service-level CPU and memory usage

**Use case:** Monitor application services, resource consumption, target health

**Metrics tracked:**
- CPU usage by service
- Memory usage by service
- Pod restarts per service
- Service availability status

**Note:** Full application metrics (HTTP requests, latency, errors) require services to expose `/metrics` endpoint with Prometheus client libraries

**Panels:** 5 graphs and tables

### Application Alerts (Staging/Prod only)
**What it shows:**
- Failed pods count
- Top 5 high-memory pods
- Top 5 high-CPU pods

**Use case:** Spot performance problems

**Panels:** 3 graphs

## Alert Rules Configured

| Alert | Threshold | Severity | Environment |
|-------|-----------|----------|-------------|
| FluentBitHighErrors | >10 errors/sec | Warning (Critical in prod) | All |
| PodEndingPhase | Any Failed/Unknown pod | Warning | All |
| NodeNotReady | Node down >5m | Critical | All |
| HighMemoryUsage | >90% of limit | Warning | Staging/Prod |
| HighCPUUsage | >80% sustained | Warning (Critical prod) | Staging/Prod |
| PersistentVolumeLow | >85% full | Warning | Production only |
| HighErrorRateKubelet | >5% errors | Warning | All |

**Current Status**: Rules defined but no routing. Alerts will still fire internally.

## Environment Differences

| Feature | Dev | Staging | Prod |
|---------|-----|---------|------|
| Prometheus Replicas | 1 | 2 HA | 3 HA |
| Storage Size | 10Gi | 50Gi | 100Gi |
| Retention | 7 days | 30 days | 90 days |
| Scrape Interval | 15s | 30s | 30s |
| Grafana Replicas | 1 | 2 HA | 3 HA |
| Pod Anti-Affinity | — | Preferred | Required |
| Dedicated Nodes | — | — | Yes (workload=monitoring) |
| Storage Class | standard | gp2 | gp3 |
| Node Selectors | — | — | workload: monitoring |

## Architecture

```
┌──────────────────────────────────────┐
│      Kubernetes Cluster              │
├──────────────────────────────────────┤
│                                      │
│  ELK Stack (Logging)                │
│  ├─ Fluent Bit (metrics on :2020)   │
│  ├─ Elasticsearch                    │
│  └─ Kibana                           │
│                                      │
│  Prometheus Stack (Metrics)         │ ◄─── NEW!
│  ├─ Prometheus (scrapes targets)    │
│  ├─ Grafana (dashboards)            │
│  └─ AlertManager (future)           │
│                                      │
│  App Services                        │
│  ├─ Auth Service                     │
│  ├─ User Service                     │
│  └─ ... (with prometheus.io/* annot) │
│                                      │
└──────────────────────────────────────┘
```

## Common Commands

### View Metrics
```bash
# Prometheus UI
kubectl port-forward -n monitoring svc/prometheus 9090:9090
# http://localhost:9090/graph

# Query directly
kubectl exec -n monitoring prometheus-0 -- \
  curl localhost:9090/api/v1/query?query=up
```

### View Dashboards
```bash
# Grafana UI
kubectl port-forward -n monitoring svc/grafana 3000:3000
# http://localhost:3000

# Check datasource status
kubectl logs -n monitoring -l app=grafana
```

### Monitor Progress
```bash
# Watch pods
watch kubectl get pods -n monitoring

# Check resource usage
kubectl top pods -n monitoring
kubectl top nodes

# Check storage
kubectl get pvc -n monitoring
```

### Troubleshooting
```bash
# Prometheus targets
curl http://prometheus:9090/api/v1/targets

# Grafana logs
kubectl logs -n monitoring -l app=grafana -f

# Prometheus alerts
curl http://prometheus:9090/api/v1/alerts

# Check Fluent Bit metrics
curl http://fluent-bit:2020/api/v1/metrics/prometheus
```

## Next Steps

### Immediate (Today)
- [ ] Deploy Prometheus + Grafana locally
- [ ] Verify dashboards display data
- [ ] Check Fluent Bit metrics are flowing
- [ ] Create custom dashboard for your app

### This Week
- [ ] Deploy to staging AWS EKS
- [ ] Verify metrics in staging
- [ ] Test alert rule triggers
- [ ] Configure Slack webhook for alerts

### Next Week
- [ ] Deploy to production AWS EKS
- [ ] Set up email notifications
- [ ] Create runbooks for alerts
- [ ] Document SLO targets

### Future
- [ ] Deploy AlertManager for complex routing
- [ ] Add application custom metrics
- [ ] Set up anomaly detection
- [ ] Implement log archival to S3

## Useful Resources

### Documentation (Your Repo)
- [MONITORING_SETUP.md](./MONITORING_SETUP.md) - Complete deployment guide
- [MONITORING_IMPLEMENTATION.md](./MONITORING_IMPLEMENTATION.md) - What was built
- [Prometheus README](./helm/prometheus/README.md) - Config reference
- [Grafana README](./helm/grafana/README.md) - Dashboard guide

### Official Docs
- [Prometheus Docs](https://prometheus.io/docs/)
- [PromQL Query Guide](https://prometheus.io/docs/prometheus/latest/querying/basics/)
- [Grafana Docs](https://grafana.com/docs/grafana/latest/)
- [Kubernetes Monitoring](https://kubernetes.io/docs/tasks/debug-application-cluster/resource-metrics-pipeline/)

### Learning
- [Prometheus Tutorial](https://prometheus.io/docs/prometheus/latest/getting_started/)
- [PromQL by Example](https://promlabs.com/promql-cheatsheet)
- [Grafana Dashboard Templates](https://grafana.com/grafana/dashboards/)

## Cost Impact

### Per Environment (Monthly)

**Dev (Local)**:
- Cost: $0 (local workstation)

**Staging (AWS)**:
- Prometheus: 2 pods = ~$50
- Grafana: 2 pods = ~$16
- Storage: 50Gi gp2 = ~$2.50
- **Total: ~$70/month**

**Production (AWS)**:
- Prometheus: 3 pods = ~$150
- Grafana: 3 pods = ~$51
- Storage: 100Gi gp3 = ~$10
- Optional S3 archival: ~$2/month
- **Total: ~$200/month**

## Is It Production Ready?

✅ **YES** for:
- Kubernetes metrics collection
- Fluent Bit pipeline monitoring
- Infrastructure health tracking
- Development dashboards
- Alert rule definition

⏳ **Action needed** for:
- Alert notification routing (configure AlertManager)
- Authentication (currently open to cluster)
- SSL/TLS (use Ingress controller)
- Custom app metrics (add prometheus.io/scrape annotations)
- High-scale deployments (>100 pods)

## Support

**Having issues?**

1. Check [MONITORING_SETUP.md](./MONITORING_SETUP.md#troubleshooting) troubleshooting section
2. View logs: `kubectl logs -n monitoring -l app=prometheus -f`
3. Check data: `kubectl port-forward -n monitoring svc/prometheus 9090:9090`
4. Verify RBAC: `kubectl get clusterrole prometheus -o yaml`

**Common solutions:**
- Charts won't deploy? → Check helm syntax: `helm lint ./helm/prometheus`
- No metrics? → Check targets at `http://prometheus:9090/targets`
- Dashboards empty? → Give Prometheus 2-3 minutes to collect data
- Pod crashes? → Check PVC availability and storage class

---

**Implementation Date**: April 20, 2026  
**Status**: ✅ Ready to deploy  
**Next Action**: Run helm install commands from MONITORING_SETUP.md
