# Kustomize and Helm Configuration Guide

This directory contains configurations for deploying the Year 4 Project using two popular Kubernetes package managers:

1. **Kustomize** - Built-in Kubernetes templating tool (included with kubectl)
2. **Helm** - A more feature-rich Kubernetes package manager

## Table of Contents

1. [Directory Structure](#directory-structure)
2. [Using Kustomize](#using-kustomize)
3. [Using Helm](#using-helm)
4. [Comparison](#comparison)
5. [Deployment Workflows](#deployment-workflows)

---

## Directory Structure

```
kubernetes/
├── base/                          # Base Kubernetes manifests
│   ├── *-deployment.yml
│   ├── *-svc.yml
│   └── configmaps/
├── kustomization.yaml            # Kustomize base config
└── overlays/                      # Environment-specific overlays
    ├── dev/
    │   ├── kustomization.yaml
    │   └── patches/
    ├── staging/
    │   ├── kustomization.yaml
    │   └── patches/
    └── production/
        ├── kustomization.yaml
        └── patches/

helm/
└── year4-project/                # Helm chart
    ├── Chart.yaml
    ├── values.yaml               # Default values
    ├── values-dev.yaml           # Dev environment values
    ├── values-staging.yaml       # Staging environment values
    ├── values-prod.yaml          # Production environment values
    └── templates/                # Helm templates
        ├── _helpers.tpl
        ├── namespace.yaml
        ├── nginx-configmap.yaml
        └── ...
```

---

## Using Kustomize

Kustomize is a native Kubernetes tool for customizing YAML manifests using layering and patching.

### Prerequisites

Kustomize comes built-in with kubectl 1.14+:
```powershell
kubectl version --client
```

### Building from Base

View what **kustomize** would deploy:

```powershell
# Build base configuration (no environment overrides)
kubectl kustomize kubernetes/base

# Pipe to a file for review
kubectl kustomize kubernetes/base > kustomize-output.yaml
```

### Deploying Development

Deploy to development environment with reduced resources:

```powershell
# View dev configuration
kubectl kustomize kubernetes/overlays/dev

# Deploy dev environment
kubectl apply -k kubernetes/overlays/dev

# Or using kustomize directly
kustomize build kubernetes/overlays/dev | kubectl apply -f -
```

**What it does:**
- Creates namespace: `year4-project-dev`
- Uses image tag: `dev`
- Sets replicas: 1 (single pod per service)
- Adds prefix: `dev-` to resource names
- Reduced resource limits for cost savings

### Deploying Staging

Deploy to staging environment:

```powershell
# View staging configuration
kubectl kustomize kubernetes/overlays/staging

# Deploy staging environment
kubectl apply -k kubernetes/overlays/staging

# Or using kustomize directly
kustomize build kubernetes/overlays/staging | kubectl apply -f -
```

**What it does:**
- Creates namespace: `year4-project-staging`
- Uses image tag: `staging`
- Sets replicas: 2 (balanced configuration)
- Converts nginx to LoadBalancer
- Adds prefix: `staging-` to resource names

### Deploying Production

Deploy to production environment with full replicas:

```powershell
# View production configuration
kubectl kustomize kubernetes/overlays/production

# Deploy production environment
kubectl apply -k kubernetes/overlays/production

# Or using kustomize directly
kustomize build kubernetes/overlays/production | kubectl apply -f -
```

**What it does:**
- Creates namespace: `year4-project`
- Uses image tag: `latest`
- Sets replicas: 3 (high availability)
- Increases resource limits for production
- Converts nginx to LoadBalancer
- Adds prefix: `prod-` to resource names

### Updating Kustomization

To modify environment-specific settings:

1. **Change replicas** - Edit `replicas:` section in overlay `kustomization.yaml`
2. **Update resources** - Create new patch file in overlay directory
3. **Change image tags** - Edit `images:` section in overlay `kustomization.yaml`
4. **Add environment variables** - Create `env.yaml` patch file

Example patch file (`overlays/dev/resource-patch.yaml`):
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: auth-service
spec:
  template:
    spec:
      containers:
      - name: auth-service
        resources:
          requests:
            memory: "128Mi"
            cpu: "50m"
          limits:
            memory: "256Mi"
            cpu: "100m"
```

Then reference in `kustomization.yaml`:
```yaml
patchesStrategicMerge:
  - resource-patch.yaml
```

### Kustomize Commands Summary

```powershell
# Validate configuration
kubectl apply -k kubernetes/overlays/dev --dry-run=client

# Deploy
kubectl apply -k kubernetes/overlays/dev

# Update/patch deployment
kubectl apply -k kubernetes/overlays/dev

# Delete deployment
kubectl delete -k kubernetes/overlays/dev

# Diff from current state
kubectl diff -k kubernetes/overlays/dev
```

---

## Using Helm

Helm is a full package manager for Kubernetes with templating, versioning, and rollback capabilities.

### Prerequisites

Install Helm:
```powershell
choco install kubernetes-helm  # Using chocolatey
# or download from https://github.com/helm/helm/releases
```

Verify installation:
```powershell
helm version
```

### Helm Chart Structure

The chart is located in `helm/year4-project/`:

- **Chart.yaml** - Chart metadata (name, version, dependencies)
- **values.yaml** - Default configuration values
- **values-*.yaml** - Environment-specific value overrides
- **templates/** - Go templates for generating Kubernetes manifests

### Basic Helm Commands

```powershell
# Validate chart syntax
helm lint helm/year4-project

# Dry-run (see what would be deployed)
helm install my-release helm/year4-project --namespace year4-project --create-namespace --dry-run

# Template rendering (see generated YAML)
helm template my-release helm/year4-project --values helm/year4-project/values.yaml
```

### Deploying with Helm

#### Development Environment

```powershell
# Install to dev environment
helm install year4-dev helm/year4-project `
  --namespace year4-project-dev `
  --create-namespace `
  --values helm/year4-project/values-dev.yaml

# Or upgrade if already exists
helm upgrade --install year4-dev helm/year4-project `
  --namespace year4-project-dev `
  --create-namespace `
  --values helm/year4-project/values-dev.yaml
```

**What it does:**
- Creates release: `year4-dev`
- Namespace: `year4-project-dev`
- 1 replica per service
- Image tag: `dev`
- DEBUG log level
- Lower resource requests/limits

#### Staging Environment

```powershell
# Install to staging
helm install year4-staging helm/year4-project `
  --namespace year4-project-staging `
  --create-namespace `
  --values helm/year4-project/values-staging.yaml

# Upgrade existing
helm upgrade --install year4-staging helm/year4-project `
  --namespace year4-project-staging `
  --create-namespace `
  --values helm/year4-project/values-staging.yaml
```

**What it does:**
- Creates release: `year4-staging`
- Namespace: `year4-project-staging`
- 2 replicas per service
- Image tag: `staging`
- INFO log level
- Autoscaling enabled (2-5 replicas)

#### Production Environment

```powershell
# Install to production
helm install year4-prod helm/year4-project `
  --namespace year4-project `
  --create-namespace `
  --values helm/year4-project/values-prod.yaml

# Upgrade existing
helm upgrade --install year4-prod helm/year4-project `
  --namespace year4-project `
  --create-namespace `
  --values helm/year4-project/values-prod.yaml
```

**What it does:**
- Creates release: `year4-prod`
- Namespace: `year4-project`
- 3 replicas per service
- Image tag: `latest`
- WARN log level (production)
- Autoscaling enabled (3-10 replicas)
- Ingress enabled for domain access
- Pod disruption budgets enabled

### Managing Helm Releases

```powershell
# List installed releases
helm list -A

# Get release status
helm status year4-dev -n year4-project-dev

# Get release values
helm get values year4-dev -n year4-project-dev

# Get release manifest
helm get manifest year4-dev -n year4-project-dev

# Upgrade release
helm upgrade year4-dev helm/year4-project `
  -n year4-project-dev `
  -f helm/year4-project/values-dev.yaml

# Rollback to previous version
helm rollback year4-dev 1 -n year4-project-dev

# Delete release
helm uninstall year4-dev -n year4-project-dev

# Delete namespace too
helm uninstall year4-dev -n year4-project-dev
kubectl delete namespace year4-project-dev
```

### Customizing Values

Override values from command line:

```powershell
# Override specific values
helm install year4-dev helm/year4-project `
  --namespace year4-project-dev `
  --create-namespace `
  --values helm/year4-project/values-dev.yaml `
  --set nginx.replicaCount=2 `
  --set image.tag=v1.2.0 `
  --set env.LOG_LEVEL=TRACE
```

Create custom values file:

```powershell
# custom-values.yaml
replicaCount: 1
image:
  tag: custom-tag
env:
  ENVIRONMENT: staging
  LOG_LEVEL: DEBUG

helm install year4-custom helm/year4-project `
  --namespace custom-ns `
  --create-namespace `
  --values custom-values.yaml
```

### Helm Release Naming Convention

```
helm install <release-name> <chart-path>
             year4-dev     helm/year4-project
```

- **year4-dev**: Development release
- **year4-staging**: Staging release  
- **year4-prod**: Production release

### Helm Template Development

To develop Helm templates, place template files in `helm/year4-project/templates/`:

```powershell
# Test template rendering (dry-run)
helm template year4-dev helm/year4-project `
  --values helm/year4-project/values-dev.yaml

# Install with debug output
helm install year4-dev helm/year4-project `
  --namespace year4-project-dev `
  --create-namespace `
  --values helm/year4-project/values-dev.yaml `
  --debug
```

---

## Comparison

| Feature | Kustomize | Helm |
|---------|-----------|------|
| Installation | Built-in kubectl | Separate install |
| Learning Curve | Simpler | Steeper |
| Templating | Strategic merge patches | Go templating |
| Package Management | No | Yes (versioning, repos) |
| Rollback | Manual | Automatic |
| Values Override | Via overlays/patches | Via values files |
| Chart Reusability | Limited | Excellent |
| Community Charts | None | Extensive marketplace |
| CI/CD Integration | Good | Excellent |
| **Best for** | **Simple overlays** | **Complex apps** |

### When to Use Kustomize

- Simple environment-specific overrides
- Patch-based configuration
- Minimal learning curve
- No external dependencies
- Local/internal deployment

### When to Use Helm

- Complex multi-service applications
- Package versioning needed
- Sharing charts across teams/orgs
- Rich templating requirements
- Production-grade deployments
- CI/CD pipelines with rollback

---

## Deployment Workflows

### Kustomize Workflow

```powershell
# 1. Develop and test locally
kubectl kustomize kubernetes/overlays/dev

# 2. Deploy to dev
kubectl apply -k kubernetes/overlays/dev

# 3. Test changes
kubectl get pods -n year4-project-dev
kubectl logs -n year4-project-dev <pod-name>

# 4. Update base manifests or patches as needed

# 5. Deploy to staging
kubectl apply -k kubernetes/overlays/staging

# 6. Deploy to production
kubectl apply -k kubernetes/overlays/production
```

### Helm Workflow

```powershell
# 1. Lint and validate
helm lint helm/year4-project

# 2. Test render
helm template test-release helm/year4-project -f helm/year4-project/values-dev.yaml

# 3. Install to dev
helm install year4-dev helm/year4-project `
  -n year4-project-dev --create-namespace `
  -f helm/year4-project/values-dev.yaml

# 4. Verify
helm status year4-dev -n year4-project-dev
kubectl get pods -n year4-project-dev

# 5. Upgrade with changes
helm upgrade year4-dev helm/year4-project `
  -n year4-project-dev `
  -f helm/year4-project/values-dev.yaml

# 6. Rollback if needed
helm rollback year4-dev -n year4-project-dev

# 7. Deploy to staging
helm upgrade --install year4-staging helm/year4-project `
  -n year4-project-staging --create-namespace `
  -f helm/year4-project/values-staging.yaml

# 8. Deploy to production
helm upgrade --install year4-prod helm/year4-project `
  -n year4-project --create-namespace `
  -f helm/year4-project/values-prod.yaml
```

### Combined Workflow (Using Both)

Deploy base infrastructure with Helm, environment overrides with Kustomize:

```powershell
# Install core services via Helm
helm install year4-core helm/year4-project -n year4-project

# Apply environment-specific patches via Kustomize
kubectl apply -k kubernetes/overlays/production
```

---

## Troubleshooting

### Kustomize Issues

```powershell
# Validate kustomization syntax
kustomize build kubernetes/overlays/dev

# Check if resources reference correctly
kubectl apply -k kubernetes/overlays/dev --dry-run=client -v 10

# Check namespace
kubectl get namespace year4-project-dev

# View configured resources
kubectl get all -n year4-project-dev
```

### Helm Issues

```powershell
# Validate chart
helm lint helm/year4-project

# Check values rendering
helm template year4-dev helm/year4-project -f helm/year4-project/values-dev.yaml

# Check release status
helm status year4-dev -n year4-project-dev

# View previous values
helm get values year4-dev -n year4-project-dev

# Get release history
helm history year4-dev -n year4-project-dev
```

---

## Additional Resources

- [Kustomize Documentation](https://kustomize.io/)
- [Helm Documentation](https://helm.sh/docs/)
- [Kubernetes Package Management](https://kubernetes.io/docs/tasks/manage-kubernetes-objects/declarative-config/)
