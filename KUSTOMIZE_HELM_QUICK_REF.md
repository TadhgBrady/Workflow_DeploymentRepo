# Kustomize and Helm Quick Reference

Fast lookup guide for common tasks.

## Kustomize Commands

### View Configuration

```powershell
# View dev configuration
kubectl kustomize kubernetes/overlays/dev

# View staging configuration
kubectl kustomize kubernetes/overlays/staging

# View production configuration
kubectl kustomize kubernetes/overlays/production

# Save to file for review
kubectl kustomize kubernetes/overlays/production > manifests.yaml
```

### Deploy to Environment

```powershell
# Deploy to development
kubectl apply -k kubernetes/overlays/dev

# Deploy to staging
kubectl apply -k kubernetes/overlays/staging

# Deploy to production
kubectl apply -k kubernetes/overlays/production
```

### Verify Deployment

```powershell
# Check deployments in namespace
kubectl get deployments -n year4-project-dev
kubectl get deployments -n year4-project-staging
kubectl get deployments -n year4-project

# Check services
kubectl get services -n year4-project-dev

# Check pods
kubectl get pods -n year4-project-dev

# View pod logs
kubectl logs -n year4-project-dev -f deployment/auth-service
```

### Update Deployment

```powershell
# Modify base configs or overlays, then:
kubectl apply -k kubernetes/overlays/dev

# Or manually patch:
kubectl patch deployment auth-service -n year4-project-dev -p '{"spec":{"replicas":2}}'
```

### Delete Deployment

```powershell
# Delete environment
kubectl delete -k kubernetes/overlays/dev

# Or delete namespace (removes all resources)
kubectl delete namespace year4-project-dev
```

### Dry-Run (Test without applying)

```powershell
# Test configuration
kubectl apply -k kubernetes/overlays/dev --dry-run=client

# See what would change
kubectl diff -k kubernetes/overlays/dev
```

---

## Helm Commands

### Installation

```powershell
# Install Helm
choco install kubernetes-helm

# Or from: https://github.com/helm/helm/releases

# Verify
helm version
```

### Chart Validation

```powershell
# Lint chart
helm lint helm/year4-project

# See rendered templates
helm template my-release helm/year4-project -f helm/year4-project/values-prod.yaml

# Dry-run install
helm install year4-prod helm/year4-project `
  --namespace year4-project `
  --create-namespace `
  --values helm/year4-project/values-prod.yaml `
  --dry-run
```

### Deploy

```powershell
# Development
helm install year4-dev helm/year4-project `
  --namespace year4-project-dev `
  --create-namespace `
  --values helm/year4-project/values-dev.yaml

# Staging
helm install year4-staging helm/year4-project `
  --namespace year4-project-staging `
  --create-namespace `
  --values helm/year4-project/values-staging.yaml

# Production
helm install year4-prod helm/year4-project `
  --namespace year4-project `
  --create-namespace `
  --values helm/year4-project/values-prod.yaml
```

### Update/Upgrade

```powershell
# Upgrade existing release
helm upgrade year4-dev helm/year4-project `
  --namespace year4-project-dev `
  --values helm/year4-project/values-dev.yaml

# Upgrade or install if not exists
helm upgrade --install year4-dev helm/year4-project `
  --namespace year4-project-dev `
  --values helm/year4-project/values-dev.yaml
```

### Release Management

```powershell
# List releases
helm list -A

# Get release status
helm status year4-dev -n year4-project-dev

# Get release values (what was used)
helm get values year4-dev -n year4-project-dev

# Get release manifest (rendered YAML)
helm get manifest year4-dev -n year4-project-dev

# View deployment history
helm history year4-dev -n year4-project-dev
```

### Rollback

```powershell
# Rollback to previous revision
helm rollback year4-dev -n year4-project-dev

# Rollback to specific revision
helm rollback year4-dev 1 -n year4-project-dev
```

### Delete

```powershell
# Uninstall release
helm uninstall year4-dev -n year4-project-dev

# Uninstall and delete namespace
helm uninstall year4-dev -n year4-project-dev
kubectl delete namespace year4-project-dev
```

### Override Values

```powershell
# Override single values from command line
helm install year4-dev helm/year4-project `
  --namespace year4-project-dev `
  --create-namespace `
  --values helm/year4-project/values-dev.yaml `
  --set nginx.replicaCount=2 `
  --set image.tag=v1.5.0 `
  --set env.LOG_LEVEL=DEBUG

# Override with multiple values files
helm install year4-custom helm/year4-project `
  --namespace custom-ns `
  --create-namespace `
  --values helm/year4-project/values-dev.yaml `
  --values custom-overrides.yaml
```

---

## Environment Comparison

### Development

**Kustomize:**
```powershell
kubectl apply -k kubernetes/overlays/dev
```

**Helm:**
```powershell
helm upgrade --install year4-dev helm/year4-project `
  -n year4-project-dev `
  --create-namespace `
  -f helm/year4-project/values-dev.yaml
```

**Result:**
- Namespace: `year4-project-dev`
- Replicas: 1 per service
- Image: `dev` tag
- Resources: Low (128Mi memory, 100m CPU)
- Log level: DEBUG

### Staging

**Kustomize:**
```powershell
kubectl apply -k kubernetes/overlays/staging
```

**Helm:**
```powershell
helm upgrade --install year4-staging helm/year4-project `
  -n year4-project-staging `
  --create-namespace `
  -f helm/year4-project/values-staging.yaml
```

**Result:**
- Namespace: `year4-project-staging`
- Replicas: 2 per service
- Image: `staging` tag
- Resources: Medium (256Mi memory, 250m CPU)
- Log level: INFO
- Nginx: LoadBalancer type
- Autoscaling: 2-5 replicas

### Production

**Kustomize:**
```powershell
kubectl apply -k kubernetes/overlays/production
```

**Helm:**
```powershell
helm upgrade --install year4-prod helm/year4-project `
  -n year4-project `
  --create-namespace `
  -f helm/year4-project/values-prod.yaml
```

**Result:**
- Namespace: `year4-project`
- Replicas: 3 per service
- Image: `latest` tag
- Resources: High (512Mi memory, 500m CPU)
- Log level: WARN
- Nginx: LoadBalancer type
- Autoscaling: 3-10 replicas
- Ingress: Enabled for domain routing
- Pod disruption budgets: Enabled

---

## Common Troubleshooting

### Kustomize

```powershell
# Check kustomization syntax
kubectl kustomize kubernetes/overlays/dev

# Validate before applying
kubectl apply -k kubernetes/overlays/dev --dry-run=client -v 10

# Check resources
kubectl get all -n year4-project-dev

# View specific resource
kubectl describe deployment auth-service -n year4-project-dev
```

### Helm

```powershell
# Validate chart
helm lint helm/year4-project

# Debug template rendering
helm template year4-dev helm/year4-project `
  --namespace year4-project-dev `
  --values helm/year4-project/values-dev.yaml

# Check what's deployed
helm get manifest year4-dev -n year4-project-dev

# Check current values
helm get values year4-dev -n year4-project-dev

# Re-render with debug
helm template year4-dev helm/year4-project `
  -n year4-project-dev `
  -f helm/year4-project/values-dev.yaml `
  --debug
```

### Common Issues

**Port conflicts:**
```powershell
# Check if service already exists
kubectl get services -A | grep nginx-gateway

# Delete old deployment
kubectl delete -k kubernetes/overlays/dev
```

**Image pull errors:**
```powershell
# Verify image exists
docker pull bencev04/4th-year-proj-tadgh-bence:dev

# Check pod events
kubectl describe pod <pod-name> -n <namespace>
```

**Resource limits:**
```powershell
# Check node capacity
kubectl describe nodes

# Check pod resource usage
kubectl top pods -n year4-project-dev
```

---

## File Locations

**Important files to know:**

| File | Purpose |
|------|---------|
| `kubernetes/base/` | Base Kubernetes manifests |
| `kubernetes/kustomization.yaml` | Root kustomize config |
| `kubernetes/overlays/dev/kustomization.yaml` | Dev environment config |
| `kubernetes/overlays/staging/kustomization.yaml` | Staging environment config |
| `kubernetes/overlays/production/kustomization.yaml` | Production environment config |
| `helm/year4-project/Chart.yaml` | Helm chart metadata |
| `helm/year4-project/values.yaml` | Default Helm values |
| `helm/year4-project/values-dev.yaml` | Dev environment values |
| `helm/year4-project/values-staging.yaml` | Staging values |
| `helm/year4-project/values-prod.yaml` | Production values |
| `helm/year4-project/templates/` | Helm template files |

---

For complete documentation, see:
- [KUSTOMIZE_HELM_GUIDE.md](KUSTOMIZE_HELM_GUIDE.md) - Detailed guide
- [README.md](README.md) - Main deployment documentation
