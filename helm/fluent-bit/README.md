# Fluent Bit Helm Chart

Fluent Bit log aggregation and forwarding to Elasticsearch for the Year4 Project.

## Installation

### Add the Helm Repository
```bash
helm repo add fluent https://fluent.github.io/helm-charts
helm repo update
```

### Deploy for Development
```bash
helm install fluent-bit ./helm/fluent-bit \
  --namespace elastic-system \
  --create-namespace \
  -f ./helm/fluent-bit/values-dev.yaml
```

### Deploy for Staging
```bash
helm install fluent-bit ./helm/fluent-bit \
  --namespace elastic-system \
  --create-namespace \
  -f ./helm/fluent-bit/values-staging.yaml \
  --set config.outputs="[OUTPUT]..." # Override Elasticsearch endpoint
```

### Deploy for Production
```bash
helm install fluent-bit ./helm/fluent-bit \
  --namespace elastic-system \
  --create-namespace \
  -f ./helm/fluent-bit/values-prod.yaml \
  --set config.outputs="[OUTPUT]..." # Override Elasticsearch endpoint
```

## Configuration

Each environment has its own values file:

- **values-dev.yaml** - Local Kind cluster, single replica
- **values-staging.yaml** - AWS staging, 2 replicas, pod anti-affinity
- **values-prod.yaml** - AWS production, 3 replicas, dedicated node labels

### Key Parameters

```yaml
replicaCount: 1  # Number of Fluent Bit pods
image:
  repository: fluent/fluent-bit
  tag: "5.0.3"
  pullPolicy: IfNotPresent

resources:
  limits:
    cpu: 200m
    memory: 128Mi
  requests:
    cpu: 100m
    memory: 64Mi

config:
  service: |
    [SERVICE]
      Parsers_File parsers.conf
      ...
  inputs: |
    [INPUT]
      ...
  filters: |
    [FILTER]
      ...
  outputs: |
    [OUTPUT]
      ...
  parsers: |
    [PARSER]
      ...
```

## Checking Status

```bash
# List pods
kubectl get pods -n elastic-system -l app.kubernetes.io/name=fluent-bit

# View logs
kubectl logs -n elastic-system -l app.kubernetes.io/name=fluent-bit --tail 50

# Check metrics endpoint
kubectl port-forward -n elastic-system svc/fluent-bit 2020:2020
curl http://localhost:2020/api/v1/metrics/prometheus
```

## Upgrading

```bash
helm upgrade fluent-bit ./helm/fluent-bit \
  --namespace elastic-system \
  -f ./helm/fluent-bit/values-prod.yaml
```

## Uninstalling

```bash
helm uninstall fluent-bit -n elastic-system
```

## Environment-Specific Notes

### Development (Local)
- Collects logs only from `year4-project-dev` namespace
- Outputs to local Elasticsearch
- Debug output enabled (removes in production)
- Single replica for resource efficiency
- View logs in Kibana: `http://localhost:5601`

### Staging (AWS)
- Collects logs from `year4-project-staging` namespace
- **Outputs to AWS CloudWatch Logs** (`/aws/eks/year4-project/staging/logs`)
- 2 replicas with pod anti-affinity
- Higher memory limits (100MB buffer)
- View logs in AWS CloudWatch Logs console
- Set up CloudWatch Insights queries for analysis

### Production (AWS)
- Collects all pod logs
- **Outputs to AWS CloudWatch Logs** (`/aws/eks/year4-project/prod/logs`)
- 3 replicas across multiple nodes
- Dedicated node scheduling with tolerations
- High memory limits (256MB buffer)
- Reduced log level (warnings only)
- View logs in AWS CloudWatch Logs console
- CloudWatch alarms for anomaly detection

## AWS CloudWatch Integration

### Prerequisites

1. **EKS Cluster with IAM Add-on:**
```bash
# Install EKS Pod Identity Agent
kubectl apply -k github.com/aws/eks-pod-identity-webhook/deployment/amazon-linux-2
```

2. **IAM Role for Fluent Bit:**
```bash
# Create IAM role with CloudWatch permissions
aws iam create-role --role-name fluent-bit-cloudwatch-role \
  --assume-role-policy-document file://trust-policy.json

aws iam attach-role-policy --role-name fluent-bit-cloudwatch-role \
  --policy-arn arn:aws:iam::aws:policy/CloudWatchLogsFullAccess
```

3. **Associate IAM role with service account:**
```bash
eksctl associate-iam-oidc-provider --cluster=year4-project --approve

eksctl create iamserviceaccount \
  --cluster=year4-project \
  --namespace=elastic-system \
  --name=fluent-bit \
  --attach-policy-arn=arn:aws:iam::aws:policy/CloudWatchLogsFullAccess \
  --approve
```

### Querying Logs in CloudWatch

**CloudWatch Insights query examples:**

```sql
-- Find all errors in production
fields @timestamp, @message, kubernetes.pod_name
| filter @message like /ERROR|error/
| stats count() by kubernetes.pod_name

-- Latency analysis
fields @duration_ms
| filter ispresent(@duration_ms)
| stats avg(@duration_ms), max(@duration_ms), pct(@duration_ms, 95)

-- Request rates by service
fields kubernetes.labels.app
| stats count() as requests by kubernetes.labels.app
```

### Setting Up Alarms

```bash
aws logs put-metric-filter \
  --log-group-name /aws/eks/year4-project/prod/logs \
  --filter-name ErrorCount \
  --filter-pattern "[ERROR]" \
  --metric-transformations metricName=ErrorCount,metricNamespace=year4-project,metricValue=1

aws cloudwatch put-metric-alarm \
  --alarm-name prod-error-spike \
  --metric-name ErrorCount \
  --namespace year4-project \
  --statistic Sum \
  --period 300 \
  --threshold 100 \
  --comparison-operator GreaterThanThreshold \
  --evaluation-periods 1 \
  --alarm-actions arn:aws:sns:eu-west-1:123456789:alerts
```

### Log Retention

```bash
# Set 30-day retention for staging
aws logs put-retention-policy \
  --log-group-name /aws/eks/year4-project/staging/logs \
  --retention-in-days 30

# Set 90-day retention for production
aws logs put-retention-policy \
  --log-group-name /aws/eks/year4-project/prod/logs \
  --retention-in-days 90
```

## Logs Sent to Elasticsearch

Each log document includes:

```json
{
  "timestamp": "2026-04-20T12:15:30.123Z",
  "level": "INFO",
  "service": "auth-service",
  "message": "User login successful",
  "kubernetes": {
    "namespace_name": "year4-project-dev",
    "pod_name": "auth-service-...",
    "container_name": "auth-service",
    "node_name": "worker-node-1",
    "labels": {...}
  },
  "hostname": "fluent-bit-abc123",
  "cluster": "year4-project-dev",
  "environment": "dev"
}
```

Indices are created daily with format: `app-logs-{env}-%Y.%m.%d`
