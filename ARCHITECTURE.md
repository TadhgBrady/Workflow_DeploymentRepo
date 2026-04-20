# Year 4 Project - Deployment Architecture

## Overview

This document outlines the logging and monitoring architecture for the Year 4 Project deployment across development, staging, and production environments.

## Logging Architecture

### Multi-Environment Strategy

```
┌─────────────────────────────────────────────────────────────┐
│                     Development (Local)                      │
├─────────────────────────────────────────────────────────────┤
│ Kind Cluster                                                │
│ ├── Application Pods (year4-project-dev namespace)         │
│ ├── Fluent Bit DaemonSet (elastic-system namespace)        │
│ │   └── Outputs: Local Elasticsearch + stdout              │
│ └── Elasticsearch 8.14.3 (ECK Operator)                    │
│     └── Visualized in: Kibana 8.14.3                       │
└─────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────┐
│                  Staging (AWS EKS)                          │
├─────────────────────────────────────────────────────────────┤
│ EKS Cluster (eu-west-1)                                    │
│ ├── Application Pods (year4-project-staging namespace)     │
│ ├── Fluent Bit DaemonSet (elastic-system namespace)        │
│ │   ├── 2 replicas                                         │
│ │   └── Outputs: AWS CloudWatch Logs + stdout              │
│ └── log group: /aws/eks/year4-project/staging/logs         │
│     └── Visualized in: CloudWatch Dashboard                │
└─────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────┐
│                Production (AWS EKS)                         │
├─────────────────────────────────────────────────────────────┤
│ EKS Cluster (eu-west-1)                                    │
│ ├── Application Pods (year4-project-prod namespace)        │
│ ├── Fluent Bit DaemonSet (elastic-system namespace)        │
│ │   ├── 3 replicas                                         │
│ │   ├── Dedicated nodes (workload=logging)                 │
│ │   └── Outputs: AWS CloudWatch Logs + stdout              │
│ └── log group: /aws/eks/year4-project/prod/logs            │
│     ├── Visualized in: CloudWatch Dashboard                │
│     └── Alarms: ErrorCount, Performance metrics            │
└─────────────────────────────────────────────────────────────┘
```

## Components

### 1. Fluent Bit (Log Collection)
- **Version**: 5.0.3
- **Deployment**: DaemonSet (one pod per node)
- **Configuration**: Helm chart with environment-specific values
- **Inputs**:
  - HTTP healthcheck on port 9880
  - Tail log files from `/var/log/containers/*_{namespace}_*.log`
- **Filters**:
  - `parser`: JSON parsing with docker fallback
  - `kubernetes`: Pod metadata enrichment
  - `record_modifier`: Add cluster/environment/hostname fields
- **Outputs**:
  - Development: Elasticsearch + stdout (debug)
  - Staging: CloudWatch Logs + stdout (healthcheck)
  - Production: CloudWatch Logs + stdout (healthcheck)

### 2. Elasticsearch (Log Storage - Development Only)
- **Version**: 8.14.3
- **Deployment**: ECK Operator
- **Namespace**: elastic-system
- **Storage**: 100Gi persistent volume
- **Indexes**: `app-logs-dev-YYYY.MM.DD` (daily rotation)

### 3. Kibana (Log Visualization - Development Only)
- **Version**: 8.14.3
- **Deployment**: ECK Operator
- **Namespace**: elastic-system
- **Access**: `http://localhost:5601` (via kubectl port-forward)
- **Usage**: Rich dashboards, complex queries, log exploration

### 4. AWS CloudWatch Logs (Log Storage - Staging/Production)
- **Log Groups**:
  - Staging: `/aws/eks/year4-project/staging/logs`
  - Production: `/aws/eks/year4-project/prod/logs`
- **Retention**:
  - Staging: 30 days
  - Production: 90 days
- **Auto-creation**: Enabled (Fluent Bit creates on first write)

### 5. AWS CloudWatch Dashboard (Visualization - Staging/Production)
- **AWS Console**: CloudWatch → Dashboards
- **Queries**: CloudWatch Insights for ad-hoc analysis
- **Alarms**: Error count, performance anomalies

## Application Services

### Microservices Deployed

```
Ingress (Nginx)
    │
    ├── Frontend (React SPA)
    │
    ├── Auth Service (JWT/OAuth)
    │
    ├── User BL Service
    │   └── User DB Access Service
    │
    ├── Customer BL Service
    │   └── Customer DB Access Service
    │
    ├── Job BL Service
    │   └── Job DB Access Service
    │
    ├── Admin BL Service
    │
    ├── Maps Access Service
    │
    └── Notification Service
```

## Deployment Structure

### Kubernetes Organization

```
kubernetes/
├── base/
│   ├── All microservice deployments
│   ├── Services
│   ├── Ingress
│   ├── RBAC
│   ├── Certificate issuers
│   └── External secrets
│
└── overlays/
    ├── dev/      (Development - local)
    ├── staging/  (AWS staging)
    └── production/ (AWS production)
```

### Helm Charts

```
helm/
├── fluent-bit/                   (Primary logging chart)
│   ├── values-dev.yaml          (1 replica, Elasticsearch)
│   ├── values-staging.yaml      (2 replicas, CloudWatch)
│   ├── values-prod.yaml         (3 replicas, CloudWatch)
│   ├── templates/               (7 template files)
│   └── README.md
│
└── wt-app/                       (Application chart - reference)
    ├── values.yaml
    ├── templates/
    └── README.md
```

## Configuration Management

### Secrets Management

**Development (Local)**:
- Kubernetes Secrets in dev overlay
- Hardcoded dev credentials (never production data)
- Location: `kubernetes/overlays/dev/secrets.yaml`

**Production/Staging (AWS)**:
- AWS Secrets Manager
- external-secrets-operator integration
- Automatic rotation support
- Location: `kubernetes/overlays/production/external-secrets.yaml`

### ConfigMaps

**Application Configuration**:
- Development: `kubernetes/overlays/dev/configmap.yaml`
- Contains: LOG_LEVEL, ENV, DEBUG, ELASTICSEARCH_ENABLED

**Fluent Bit Configuration**:
- Helm-templated: `helm/fluent-bit/templates/configmap.yaml`
- Rendered from environment-specific values

## Log Flow Examples

### Structured JSON Log

```json
{
  "log": "{\"timestamp\":\"2026-04-20T12:15:30.123Z\",\"level\":\"INFO\",\"service\":\"auth-service\",\"request_id\":\"req-123\",\"message\":\"User login successful\"}",
  "stream": "stdout",
  "kubernetes": {
    "pod_name": "auth-service-67f95d7d4f-77mtd",
    "namespace_name": "year4-project-dev",
    "labels": {
      "app": "auth-service",
      "version": "1.0.0"
    }
  },
  "hostname": "worker-node-1",
  "cluster": "dev",
  "environment": "development"
}
```

### Enriched Record in Elasticsearch

```json
{
  "@timestamp": "2026-04-20T12:15:30.123Z",
  "message": "User login successful",
  "level": "INFO",
  "service": "auth-service",
  "request_id": "req-123",
  "pod_name": "auth-service-67f95d7d4f-77mtd",
  "namespace": "year4-project-dev",
  "hostname": "worker-node-1",
  "cluster": "dev",
  "environment": "development"
}
```

## Observability Features

### Log Parsing
- **Primary**: JSON format (structured logs from applications)
- **Fallback 1**: Docker format (container runtime logs)
- **Fallback 2**: Regex fallback for unstructured logs

### Kubernetes Enrichment
- Pod name, namespace, labels
- Deployment, StatefulSet, DaemonSet owner references
- Annotations (if present)
- Container name

### Custom Fields
- `hostname`: Node hostname where pod runs
- `cluster`: Environment (dev/staging/prod)
- `environment`: Application environment label
- `region`: AWS region (if applicable)

## Monitoring & Alerting

### Development
- Manual log exploration via Kibana
- No production dependencies

### Staging/Production
- CloudWatch Logs Insights for ad-hoc queries
- CloudWatch Dashboard for visualization
- CloudWatch Alarms for:
  - Error rate spikes
  - Performance anomalies
  - Service health

### Fluent Bit Health
- Prometheus metrics on port 2020
- Metrics exposed at: `/api/v1/metrics/prometheus`
- Key metrics:
  - `fluentbit_input_records_total`: Records processed
  - `fluentbit_output_errors_total`: Send failures
  - `fluentbit_output_retries_total`: Retry attempts

## Security Considerations

### RBAC (Role-Based Access Control)
- `fluent-bit` ServiceAccount in elastic-system
- ClusterRole with minimal permissions:
  - `pods` (get, list, watch)
  - `pods/logs` (get)
  - `namespaces` (get, list, watch)
  - `replicasets` (get)

### Network Security
- Kubernetes internal APIs accessed via HTTPS
- CloudWatch API accessed via AWS IAM (IRSA)
- No credentials stored in pod manifests

### Data Protection
- PII/Sensitive data should be filtered at source (application level)
- CloudWatch encryption at rest (AWS KMS available)
- Log retention policies to manage data lifecycle

## Deployment Commands

### Development (Local)
```bash
# Deploy ELK stack
kubectl apply -f configs/

# Deploy Fluent Bit via Helm
helm install fluent-bit ./helm/fluent-bit -f helm/fluent-bit/values-dev.yaml

# Deploy applications
kubectl apply -k kubernetes/overlays/dev
```

### Staging (AWS)
```bash
# Configure IAM roles (see CLOUDWATCH_DEPLOYMENT.md)

# Deploy Fluent Bit
helm install fluent-bit ./helm/fluent-bit \
  --namespace elastic-system \
  -f helm/fluent-bit/values-staging.yaml

# Deploy applications
kubectl apply -k kubernetes/overlays/staging
```

### Production (AWS)
```bash
# Configure IAM roles (see CLOUDWATCH_DEPLOYMENT.md)

# Deploy Fluent Bit
helm install fluent-bit ./helm/fluent-bit \
  --namespace elastic-system \
  -f helm/fluent-bit/values-prod.yaml

# Deploy applications
kubectl apply -k kubernetes/overlays/production
```

## Cost Analysis

### Development (Local)
- **Cost**: $0 (assumes local Kind cluster)
- **Storage**: Limited to available disk space
- **Computation**: Shared with workstation

### Staging (AWS)
- **Fluent Bit**: ~0.05 $/node/day (2 replicas)
- **CloudWatch Logs**: ~$0.50/GB ingested + $0.005/GB scanned
- **Typical**: 50-100GB/month ingestion

### Production (AWS)
- **Fluent Bit**: ~0.08 $/node/day (3 replicas)
- **CloudWatch Logs**: ~$0.50/GB ingested + $0.005/GB scanned
- **Typical**: 500-1000GB/month ingestion (scales with traffic)

## Future Enhancements

### Phase 2: Metrics Collection
- Prometheus Agent (similar DaemonSet for metrics)
- Grafana for dashboard visualization
- Integration with Fluent Bit metrics (port 2020)

### Phase 3: Advanced Features
- Log transformation/redaction for PII
- Anomaly detection via CloudWatch Anomaly Detector
- Cross-service tracing (correlation IDs)
- Custom CloudWatch dashboards for business KPIs

### Phase 4: Cost Optimization
- S3 archival for long-term log storage
- Athena for complex historical queries
- Reserved capacity pricing for CloudWatch

## Troubleshooting Guide

### Logs Not Appearing

1. **Check Fluent Bit pods**:
   ```bash
   kubectl get pods -n elastic-system -l app=fluent-bit
   ```

2. **Check pod logs**:
   ```bash
   kubectl logs -n elastic-system -l app=fluent-bit --tail=50
   ```

3. **Verify IAM permissions** (AWS):
   ```bash
   # Check service account annotation
   kubectl get sa fluent-bit -n elastic-system -o yaml
   ```

4. **Check log group exists**:
   ```bash
   aws logs describe-log-groups --log-group-name-prefix "/aws/eks/"
   ```

### High CPU/Memory Usage

1. **Reduce flush interval** (less aggregation)
2. **Decrease Mem_Buf_Limit** in configuration
3. **Increase node resources** or shard to fewer nodes

### CloudWatch Costs High

1. **Increase retention period** (S3 archive older logs)
2. **Filter at Fluent Bit level** (send only ERROR+ to CloudWatch)
3. **Review log volume** (check for debug logs in production)

## References

- [Fluent Bit Documentation](https://docs.fluentbit.io/)
- [AWS CloudWatch Logs](https://docs.aws.amazon.com/AmazonCloudWatch/latest/logs/)
- [Kubernetes Logging Architecture](https://kubernetes.io/docs/concepts/cluster-administration/logging/)
- [IRSA (IAM Roles for Service Accounts)](https://docs.aws.amazon.com/eks/latest/userguide/iam-roles-for-service-accounts.html)
