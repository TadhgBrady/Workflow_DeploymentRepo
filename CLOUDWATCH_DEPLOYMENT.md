# AWS CloudWatch Deployment Guide

This guide covers deploying the Year4 Project with Fluent Bit CloudWatch integration to AWS EKS.

## Architecture

```
EKS Cluster
├── Fluent Bit DaemonSet (elastic-system)
│   ├── Collects pod logs
│   └── Streams to CloudWatch Logs
├── Application Microservices (year4-project-prod/staging)
│   ├── Auth Service
│   ├── User BL Service
│   ├── Customer BL Service
│   ├── Job BL Service
│   └── Notification Service
└── Nginx Ingress
    └── Routes to applications

CloudWatch
├── Log Groups (/aws/eks/year4-project/{env}/logs)
├── Metrics (Fluent Bit health)
├── Dashboards (visualization)
└── Alarms (error detection)
```

## Prerequisites

- AWS Account with appropriate permissions
- EKS cluster(s) created for staging and production
- `kubectl` configured to access EKS clusters
- `helm` 3.x installed
- `aws-cli` v2 installed and configured
- `eksctl` installed (optional but recommended)

## Step 1: Create IAM Role for Fluent Bit

```bash
# For each cluster/region:
CLUSTER_NAME="year4-project"
REGION="eu-west-1"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# Create trust policy
cat > trust-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::$ACCOUNT_ID:oidc-provider/oidc.eks.$REGION.amazonaws.com/id/$(aws eks describe-cluster --name $CLUSTER_NAME --region $REGION --query 'cluster.identity.oidc.issuer' --output text | cut -d'/' -f5)"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "oidc.eks.$REGION.amazonaws.com/id/$(aws eks describe-cluster --name $CLUSTER_NAME --region $REGION --query 'cluster.identity.oidc.issuer' --output text | cut -d'/' -f5):sub": "system:serviceaccount:elastic-system:fluent-bit"
        }
      }
    }
  ]
}
EOF

# Create role
aws iam create-role \
  --role-name fluent-bit-cloudwatch-role \
  --assume-role-policy-document file://trust-policy.json \
  --region $REGION

# Attach CloudWatch policy
aws iam attach-role-policy \
  --role-name fluent-bit-cloudwatch-role \
  --policy-arn arn:aws:iam::aws:policy/CloudWatchLogsFullAccess \
  --region $REGION

ROLE_ARN=$(aws iam get-role --role-name fluent-bit-cloudwatch-role --query 'Role.Arn' --output text)
```

## Step 2: Create elastic-system Namespace

```bash
# For staging
kubectl create namespace elastic-system
kubectl label namespace elastic-system environment=staging

# For production
kubectl create namespace elastic-system
kubectl label namespace elastic-system environment=production
```

## Step 3: Annotate Service Account (or use eksctl)

### Option A: Using eksctl (Recommended)
```bash
eksctl create iamserviceaccount \
  --cluster=$CLUSTER_NAME \
  --namespace=elastic-system \
  --name=fluent-bit \
  --attach-policy-arn=arn:aws:iam::aws:policy/CloudWatchLogsFullAccess \
  --approve \
  --region=$REGION
```

### Option B: Manual Annotation
```bash
kubectl annotate serviceaccount fluent-bit \
  -n elastic-system \
  eks.amazonaws.com/role-arn=$ROLE_ARN \
  --overwrite
```

## Step 4: Deploy Fluent Bit with Helm

### Staging Environment
```bash
helm install fluent-bit ./helm/fluent-bit \
  --namespace elastic-system \
  --values ./helm/fluent-bit/values-staging.yaml \
  --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"="$ROLE_ARN"
```

### Production Environment
```bash
helm install fluent-bit ./helm/fluent-bit \
  --namespace elastic-system \
  --values ./helm/fluent-bit/values-prod.yaml \
  --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"="$ROLE_ARN"
```

## Step 5: Verify Deployment

```bash
# Check Fluent Bit pods
kubectl get pods -n elastic-system -l app=fluent-bit

# Check logs
kubectl logs -n elastic-system -l app=fluent-bit -f

# Verify AWS CloudWatch access (may take 1-2 minutes)
aws logs describe-log-groups \
  --log-group-name-prefix "/aws/eks/year4-project/" \
  --region $REGION
```

## Step 6: Configure Log Group Retention

```bash
# Staging - 30 days
aws logs put-retention-policy \
  --log-group-name /aws/eks/year4-project/staging/logs \
  --retention-in-days 30 \
  --region $REGION

# Production - 90 days
aws logs put-retention-policy \
  --log-group-name /aws/eks/year4-project/prod/logs \
  --retention-in-days 90 \
  --region $REGION
```

## Step 7: Deploy Application Stack

```bash
# Create application namespace
kubectl create namespace year4-project-prod  # or year4-project-staging

# Deploy kustomize overlay
kubectl apply -k kubernetes/overlays/production/  # or staging
```

## Step 8: (Optional) Create CloudWatch Dashboard

```bash
# Create metrics for error tracking
aws logs put-metric-filter \
  --log-group-name /aws/eks/year4-project/prod/logs \
  --filter-name ErrorCount \
  --filter-pattern "[ERROR]" \
  --metric-transformations metricName=ErrorCount,metricNamespace=year4-project,metricValue=1 \
  --region $REGION

# Create dashboard (AWS Console or CDK/CloudFormation)
# Reference: https://docs.aws.amazon.com/AmazonCloudWatch/latest/APIReference/API_PutDashboard.html
```

## Step 9: (Optional) Set Up CloudWatch Alarms

```bash
# Create alarm for high error rate
aws cloudwatch put-metric-alarm \
  --alarm-name year4-project-prod-errors \
  --alarm-description "Alert when error count exceeds 100 in 5 minutes" \
  --metric-name ErrorCount \
  --namespace year4-project \
  --statistic Sum \
  --period 300 \
  --threshold 100 \
  --comparison-operator GreaterThanThreshold \
  --evaluation-periods 1 \
  --treat-missing-data notBreaching \
  --region $REGION
  
  # Add SNS topic for notifications (optional)
  # --alarm-actions arn:aws:sns:eu-west-1:ACCOUNT_ID:alerts
```

## Troubleshooting

### Fluent Bit Pods Not Starting
```bash
# Check service account
kubectl get sa fluent-bit -n elastic-system -o yaml

# Verify IAM role annotation
kubectl get sa fluent-bit -n elastic-system -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}'

# Check pod events
kubectl describe pod -n elastic-system -l app=fluent-bit
```

### Logs Not Appearing in CloudWatch
```bash
# Check Fluent Bit logs for errors
kubectl logs -n elastic-system -l app=fluent-bit --tail=50

# Common issues:
# 1. IAM role missing CloudWatch permissions
# 2. Pod using wrong IAM role (check IRSA setup)
# 3. Log group doesn't exist (Fluent Bit should auto-create)
# 4. Network connectivity issue to CloudWatch endpoint
```

### Check Application Logs
```bash
# Query staging logs
aws logs filter-log-events \
  --log-group-name /aws/eks/year4-project/staging/logs \
  --start-time $(($(date +%s)*1000-3600000)) \
  --region $REGION \
  | head -20

# Use CloudWatch Insights for complex queries
# AWS Console: CloudWatch → Log groups → query
```

## Monitoring Fluent Bit Health

The Fluent Bit service exposes metrics on port 2020:

```bash
# Port-forward to local machine
kubectl port-forward -n elastic-system svc/fluent-bit 2020:2020

# Access metrics
curl http://localhost:2020/api/v1/metrics/prometheus
```

Key metrics to monitor:
- `fluentbit_input_records_total` - Records processed
- `fluentbit_output_errors_total` - CloudWatch send failures
- `fluentbit_output_retries_total` - Retry attempts

## Scaling Fluent Bit

Fluent Bit runs as a DaemonSet (one pod per node). To adjust replicas for testing:

```bash
# Temporarily scale down (not recommended for production)
kubectl patch daemonset fluent-bit -n elastic-system \
  -p '{"spec": {"template": {"spec": {"nodeSelector": {"disk":"ssd"}}}}}'

# This effectively scales to 0 until you remove the nodeSelector
```

For production, adjust via Helm values:

```bash
helm upgrade fluent-bit ./helm/fluent-bit \
  --namespace elastic-system \
  --values ./helm/fluent-bit/values-prod.yaml \
  --set replicaCount=2  # Override for specific testing
```

## Cost Optimization

CloudWatch Logs pricing:
- Data ingestion: $0.50 per GB
- Data scanned by CloudWatch Insights: $0.005 per GB

### Cost-saving strategies:
1. Set appropriate retention periods (30d staging, 90d prod)
2. Use log group archival to S3 for long-term storage
3. Filter logs at Fluent Bit level (reduce volume)
4. Use CloudWatch Logs Insights sparingly in production

Example: filter only ERROR+ logs
```yaml
outputs: |
  [OUTPUT]
    Name cloudwatch_logs
    Match app.*
    region eu-west-1
    log_group_name /aws/eks/year4-project/prod/logs
    log_stream_prefix fluent-bit-
    # Only send ERROR and CRITICAL logs
    Filter_Regex log ^.*\[ERROR|CRITICAL\].*$
```

## Security Best Practices

1. **IAM Role**: Use least-privilege policy (consider creating custom policy vs CloudWatchLogsFullAccess)
2. **Encryption**: Enable encryption at rest in CloudWatch Logs via AWS KMS
3. **VPC Endpoints**: Route CloudWatch requests through VPC endpoints (no internet traffic)
4. **Log Filtering**: Remove sensitive data (PII, passwords, tokens) before CloudWatch

Example VPC Endpoint setup:
```bash
aws ec2 create-vpc-endpoint \
  --vpc-id vpc-xxxxx \
  --vpc-endpoint-type Interface \
  --service-name com.amazonaws.${REGION}.logs \
  --subnet-ids subnet-xxxxx \
  --security-group-ids sg-xxxxx
```

## Next Steps

1. ✅ Deploy Fluent Bit to staging first
2. ✅ Verify logs flow to CloudWatch
3. ✅ Test CloudWatch Insights queries
4. ✅ Set up alarms and dashboards
5. ✅ Deploy to production
6. ⏳ Monitor metrics and optimize

## References

- [Fluent Bit CloudWatch Output Plugin](https://docs.fluentbit.io/manual/pipeline/outputs/cloudwatch)
- [AWS CloudWatch Logs Insights Query Syntax](https://docs.aws.amazon.com/AmazonCloudWatch/latest/logs/CWL_QuerySyntax.html)
- [EKS IRSA Setup](https://docs.aws.amazon.com/eks/latest/userguide/iam-roles-for-service-accounts.html)
- [CloudWatch Logs Pricing](https://aws.amazon.com/cloudwatch/pricing/)
