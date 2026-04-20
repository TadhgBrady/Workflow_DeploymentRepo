# Deployment Checklist & Next Steps

## Current Status: ✅ Logging Infrastructure Ready

Your logging infrastructure is now production-ready with multi-environment support:
- ✅ Fluent Bit DaemonSet configured (v5.0.3)
- ✅ Development: Elasticsearch + Kibana (local)
- ✅ Staging/Prod: AWS CloudWatch Logs configured
- ✅ Helm charts with environment-specific values
- ✅ Kubernetes manifests with RBAC
- ✅ Documentation complete

---

## Next Steps

### Phase 1: Verify Development Setup ⏳

**Goal**: Ensure logs flow from applications → Fluent Bit → Elasticsearch → Kibana

**1. Verify Fluent Bit Running**
```bash
# Check pods
kubectl get pods -n elastic-system -l app=fluent-bit

# Both should be Ready (2/2)
# Monitor logs
kubectl logs -n elastic-system -l app=fluent-bit -f
```

**Expected output**:
```
[info] [...] Starting fluent bit
[info] [...] HTTP Server listening on...
[info] [...] DB file ...
[info] [...] Starting engine
```

**2. Verify Elasticsearch & Kibana**
```bash
# Check services
kubectl get svc -n elastic-system

# Port-forward Elasticsearch
kubectl port-forward -n elastic-system svc/quickstart-es-http 9200:9200 &

# Check indices
curl -u elastic:$password http://localhost:9200/_cat/indices
```

**Expected output**: List of indices including `app-logs-dev-*`

**3. Port-Forward Kibana**
```bash
# New terminal
kubectl port-forward -n elastic-system svc/quickstart-kb-http 5601:5601

# Visit: http://localhost:5601
# Create index pattern: app-logs-*
# Browse recent logs
```

**4. Verify Application Pods Generating Logs**
```bash
# Check app pods
kubectl get pods -n year4-project-dev

# If any show CreateContainerConfigError or CrashLoopBackOff:
kubectl describe pod -n year4-project-dev <pod-name>
kubectl logs -n year4-project-dev <pod-name>
```

---

### Phase 2: Fix Application Pod Issues 🔧

**If application pods are failing**, run these diagnostics:

**Option A: Check Secrets/ConfigMaps**
```bash
# List secrets
kubectl get secrets -n year4-project-dev

# Check what's missing
kubectl get cm -n year4-project-dev
```

**Option B: Examine Pod Events**
```bash
# Detailed pod status
kubectl describe pod -n year4-project-dev auth-service-<hash>

# Look for "Unable to attach or mount volumes" or "Key ... not found"
```

**Option C: View Init Container Logs**
```bash
# If pod has init container
kubectl logs -n year4-project-dev auth-service-<hash> --previous
```

**Fix: Update Secrets & ConfigMaps**
```bash
# Edit and add missing values
kubectl edit secret app-secrets -n year4-project-dev
kubectl edit configmap app-config -n year4-project-dev

# Restart pods to pick up changes
kubectl rollout restart deployment/auth-service -n year4-project-dev
```

---

### Phase 3: Test AWS CloudWatch (Pre-Deployment) ✅

**Before deploying to EKS, test locally:**

**1. Verify Fluent Bit can write to CloudWatch**
```bash
# Install AWS CLI
aws --version

# Configure credentials
aws configure set aws_access_key_id YOUR_KEY
aws configure set aws_secret_access_key YOUR_SECRET
aws configure set region eu-west-1

# Test CloudWatch access
aws logs create-log-group --log-group-name /test-year4/test --region eu-west-1
aws logs put-log-events \
  --log-group-name /test-year4/test \
  --log-stream-name test-stream \
  --log-events timestamp=$(date +%s000),message="Test message" \
  --region eu-west-1

# Verify in AWS Console
aws logs filter-log-events --log-group-name /test-year4/test --region eu-west-1
```

**2. Review Fluent Bit Configuration Before Deployment**
```bash
# Check values are correct
cat helm/fluent-bit/values-staging.yaml | grep -A 10 cloudwatch_logs

# Should show:
# Name cloudwatch_logs
# region eu-west-1
# log_group_name /aws/eks/year4-project/staging/logs
# auto_create_group true
```

---

### Phase 4: Deploy to AWS EKS 🚀

**Prerequisite**: AWS EKS cluster already created

**1. Set Up IAM for Fluent Bit**
```bash
# Follow CLOUDWATCH_DEPLOYMENT.md in detail:
# - Create IAM role with CloudWatch permissions
# - Associate with EKS service account
# - Verify OIDC provider is enabled

# Command overview:
eksctl create iamserviceaccount \
  --cluster=year4-project \
  --namespace=elastic-system \
  --name=fluent-bit \
  --attach-policy-arn=arn:aws:iam::aws:policy/CloudWatchLogsFullAccess \
  --approve
```

**2. Create Namespace**
```bash
# For staging
kubectl create namespace elastic-system
kubectl create namespace year4-project-staging

# For production
kubectl create namespace elastic-system
kubectl create namespace year4-project-prod
```

**3. Deploy Fluent Bit**
```bash
# Staging
helm install fluent-bit ./helm/fluent-bit \
  --namespace elastic-system \
  -f helm/fluent-bit/values-staging.yaml

# Production
helm install fluent-bit ./helm/fluent-bit \
  --namespace elastic-system \
  -f helm/fluent-bit/values-prod.yaml
```

**4. Verify Deployment**
```bash
# Check pods
kubectl get pods -n elastic-system -l app=fluent-bit

# Check logs for errors
kubectl logs -n elastic-system -l app=fluent-bit

# Verify logs in CloudWatch (wait 2-3 minutes for first batch)
aws logs describe-log-groups --log-group-name-prefix "/aws/eks/year4-project/"
```

**5. Deploy Application Microservices**
```bash
# Staging
kubectl apply -k kubernetes/overlays/staging

# Production
kubectl apply -k kubernetes/overlays/production

# Verify pods running
kubectl get pods -n year4-project-staging
kubectl get pods -n year4-project-prod
```

---

### Phase 5: Verify CloudWatch Logs 📊

**After deployment to EKS:**

**1. Check Log Groups Created**
```bash
aws logs describe-log-groups --region eu-west-1 | grep year4-project
```

**2. View Recent Logs**
```bash
# Get recent log events
aws logs filter-log-events \
  --log-group-name /aws/eks/year4-project/staging/logs \
  --start-time $(($(date +%s)*1000-3600000)) \
  --region eu-west-1 \
  | head -20
```

**3. Query with CloudWatch Insights**
```bash
# AWS Console: CloudWatch → Log groups → Select log group → Insights

# Example queries:
# Find all errors
fields @timestamp, @message, kubernetes.pod_name
| filter @message like /ERROR/
| stats count() by kubernetes.pod_name

# Request rates by service
fields kubernetes.labels.app
| stats count() as requests by kubernetes.labels.app
```

**4. Create Dashboard**
```bash
# AWS Console: CloudWatch → Dashboards → Create dashboard
# Add widgets to visualize:
# - Log message counts
# - Error rates per service
# - Log volume over time
```

---

### Phase 6: Set Up Monitoring & Alarms 🚨

**Deploy Prometheus metrics collection and Grafana dashboards:**

**6.1: Deploy Prometheus (Development)**
```bash
# Create monitoring namespace
kubectl create namespace monitoring

# Deploy Prometheus
helm install prometheus ./helm/prometheus \
  -f helm/prometheus/values-dev.yaml \
  -n monitoring

# Verify
kubectl get pods -n monitoring -l app=prometheus
kubectl port-forward -n monitoring svc/prometheus 9090:9090
# Check http://localhost:9090 - should show targets
```

**6.2: Deploy Grafana (Development)**
```bash
# Deploy Grafana
helm install grafana ./helm/grafana \
  -f helm/grafana/values-dev.yaml \
  -n monitoring

# Verify
kubectl port-forward -n monitoring svc/grafana 3000:3000
# Visit http://localhost:3000 (admin/changeme)
# Verify dashboards appear
```

**6.3: Verify Metrics Collection**
```bash
# Check if Fluent Bit metrics are scraped
kubectl port-forward -n monitoring svc/prometheus 9090:9090

# In another terminal, query:
curl 'http://localhost:9090/api/v1/query?query=fluentbit_uptime'

# Should return metrics from Fluent Bit pods
```

**6.4: Deploy to AWS EKS (Staging)**
```bash
# Switch to staging cluster
aws eks update-kubeconfig --name year4-project-staging --region eu-west-1

# Create namespace and deploy
kubectl create namespace monitoring

helm install prometheus ./helm/prometheus \
  -f helm/prometheus/values-staging.yaml \
  -n monitoring

helm install grafana ./helm/grafana \
  -f helm/grafana/values-staging.yaml \
  -n monitoring

# Verify both 2 replicas running
kubectl get pods -n monitoring
kubectl logs -n monitoring -l app=prometheus --tail=20
```

**6.5: Set Up CloudWatch Metric Filters (Optional)**

For additional alerts beyond Prometheus:

```bash
# Create metric filter for errors
aws logs put-metric-filter \
  --log-group-name /aws/eks/year4-project/prod/logs \
  --filter-name ErrorCount \
  --filter-pattern "[ERROR]" \
  --metric-transformations metricName=ErrorCount,metricNamespace=year4-project,metricValue=1 \
  --region eu-west-1

# Create alarm (trigger if > 100 errors in 5 minutes)
aws cloudwatch put-metric-alarm \
  --alarm-name year4-project-prod-errors \
  --metric-name ErrorCount \
  --namespace year4-project \
  --statistic Sum \
  --period 300 \
  --threshold 100 \
  --comparison-operator GreaterThanThreshold \
  --evaluation-periods 1 \
  --region eu-west-1
```

---

## Quick Reference Commands

### Local Development

```bash
# View Elasticsearch indices
curl -u elastic:password http://localhost:9200/_cat/indices

# Access Kibana
kubectl port-forward -n elastic-system svc/quickstart-kb-http 5601:5601

# Check Fluent Bit health
kubectl exec -n elastic-system <pod> -- curl localhost:2020/api/v1/metrics/prometheus

# Tail Fluent Bit logs
kubectl logs -n elastic-system -l app=fluent-bit -f

# Describe pod for errors
kubectl describe pod -n year4-project-dev <pod-name>
```

### AWS CloudWatch

```bash
# List all logs in project
aws logs describe-log-groups --log-group-name-prefix "/aws/eks/year4-project/"

# Tail recent logs (last hour)
aws logs filter-log-events \
  --log-group-name /aws/eks/year4-project/prod/logs \
  --start-time $(($(date +%s)*1000-3600000)) \
  | head -50

# Search for specific message
aws logs filter-log-events \
  --log-group-name /aws/eks/year4-project/prod/logs \
  --filter-pattern "ERROR"

# Create log group
aws logs create-log-group --log-group-name /aws/eks/year4-project/test

# Delete log group (careful!)
aws logs delete-log-group --log-group-name /aws/eks/year4-project/test
```

---

## Decision Points & Recommendations

### 1. Application Logging Format
- **Current**: DaemonSet can parse JSON, Docker, or regex
- **Recommendation**: Update microservices to emit JSON logs
- **Example**:
  ```json
  {"timestamp":"2026-04-20T12:15:30Z","level":"INFO","service":"auth","message":"Login successful"}
  ```

### 2. Log Retention
- **Dev (Local)**: Keep indefinitely (disk space permitting)
- **Staging**: 30 days (recommendation)
- **Prod**: 90 days (recommendation)
- Can change via: `aws logs put-retention-policy`

### 3. CloudWatch Cost Control
- **Issue**: High volumes can spike costs ($0.50/GB ingestion)
- **Solutions**:
  - Archive to S3 after retention period
  - Filter INFO/DEBUG logs at Fluent Bit level
  - Use sampled logging (1% of INFO logs)
- **Current Setup**: No filtering, will send all logs

### 4. Metrics & Alerting
- **Current**: Only logs are collected
- **Recommendation**: Add Prometheus + Grafana for:
  - CPU/Memory usage
  - Network metrics
  - Request latency
  - Custom application metrics
- **Timeline**: Phase 2 (after logging stable)

---

## Common Issues & Solutions

### Issue: "CreateContainerConfigError" in Pods
**Cause**: Missing secrets or configmaps
**Solution**: 
```bash
# Check what's needed
kubectl describe pod <pod-name> -n year4-project-dev

# Create missing resources
kubectl create secret generic <name> --from-literal=key=value -n year4-project-dev
kubectl create configmap <name> --from-file=path -n year4-project-dev
```

### Issue: "No Logs in CloudWatch After 5 Minutes"
**Causes to check**:
1. Fluent Bit pods not running: `kubectl get pods -n elastic-system`
2. IAM role not attached: `kubectl get sa fluent-bit -n elastic-system -o yaml`
3. Log group not created: `aws logs describe-log-groups`
4. Pods not writing logs: `kubectl logs <pod-name>`

### Issue: "High Memory Usage on Fluent Bit Pods"
**Solutions**:
- Decrease `Mem_Buf_Limit` in values YAML
- Increase flush frequency (reduce buffering)
- Split across more nodes (reduce Mem_Buf_Limit by nodes)

### Issue: "CloudWatch Logs Costs Too High"
**Solutions**:
1. Set retention policy (deletes old logs)
2. Filter at source: Only send ERROR+ logs
3. Sample logs: Send 1% of DEBUG/INFO
4. Archive to S3 for long-term storage

---

## Timeline & Milestones

### Week 1 (This Week)
- [ ] Verify local logging setup (Dev)
- [ ] Fix any application pod issues
- [ ] Test Kibana dashboard
- [ ] Review CloudWatch configuration

### Week 2
- [ ] Set up AWS EKS cluster (if not done)
- [ ] Configure IAM roles for CloudWatch
- [ ] Deploy to staging EKS
- [ ] Verify logs flow to CloudWatch Staging

### Week 3
- [ ] Deploy to production EKS
- [ ] Verify logs flow to production CloudWatch
- [ ] Set up CloudWatch dashboards
- [ ] Create alarms for critical errors

### Week 4+
- [ ] Phase 2: Add Prometheus + Grafana
- [ ] Implement custom application metrics
- [ ] Optimize log volumes & costs
- [ ] Document runbook for operations team

---

## Success Criteria

✅ **Logging Infrastructure Complete When**:
1. Logs appear in Kibana for local dev environment
2. All microservices are deployed and running (dev)
3. CloudWatch integration tested (with AWS credentials)
4. Helm charts deploy successfully to EKS
5. Logs flow to CloudWatch Logs in staging/prod
6. CloudWatch dashboards show real data
7. Alarms trigger on ERROR conditions

---

## Resources & Documentation

- [CLOUDWATCH_DEPLOYMENT.md](./CLOUDWATCH_DEPLOYMENT.md) - Step-by-step AWS setup
- [ARCHITECTURE.md](./ARCHITECTURE.md) - System design & components
- [helm/fluent-bit/README.md](./helm/fluent-bit/README.md) - Fluent Bit configuration
- [configs/](./configs/) - Kubernetes manifests for local ELK stack
- [kubernetes/overlays/](./kubernetes/overlays/) - Environment-specific deployments

---

## Support & Questions

If you encounter issues:
1. Check logs: `kubectl logs -n elastic-system -l app=fluent-bit`
2. Review errors in pod descriptions: `kubectl describe pod <pod>`
3. Verify configuration: `helm get values fluent-bit -n elastic-system`
4. Check AWS IAM: `aws sts get-caller-identity`
5. Consult [CLOUDWATCH_DEPLOYMENT.md](./CLOUDWATCH_DEPLOYMENT.md) troubleshooting section

---

**Last Updated**: April 20, 2026
**Status**: Ready for AWS Deployment
**Next Action**: Verify local setup, then proceed to AWS EKS deployment
