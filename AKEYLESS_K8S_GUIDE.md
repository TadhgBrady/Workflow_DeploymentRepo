# Akeyless & Kubernetes Integration Guide

## Overview

This document explains how Akeyless integrates with Kubernetes to securely manage and inject secrets into your applications.

**Key Components:**
- **Akeyless**: Centralized secret management platform
- **Akeyless CSI Driver**: Kubernetes plugin that fetches secrets from Akeyless
- **SecretProviderClass**: K8s resource that defines which secrets to fetch
- **Synced K8s Secrets**: Native K8s secrets created from Akeyless data

---

## Architecture Flow

```
┌─────────────────┐
│    Akeyless     │  (Stores: /prod/db/password, Redis_password)
└────────┬────────┘
         │
         │ CSI Driver requests secrets
         │
┌────────▼───────────────────────────┐
│  SecretProviderClass (K8s CRD)     │
│  - Defines secret paths             │
│  - Specifies auth method            │
└────────┬───────────────────────────┘
         │
         │ Creates/Updates
         │
┌────────▼──────────────────────────┐
│ K8s Native Secret                  │
│ (akeyless-secrets-synced)          │
│ - db-password                      │
│ - redis-password                   │
└────────┬──────────────────────────┘
         │
         │ Reference via env vars
         │
┌────────▼──────────────────────────┐
│ Pod/Container                      │
│ - REDIS_PASSWORD (injected)        │
│ - DB_PASSWORD (injected)           │
└────────────────────────────────────┘
```

---

## Setup Process

### 1. Install Akeyless CSI Driver

```bash
helm install akeyless-csi akeyless/akeyless-csi-provider -n kube-system
```

**Verify installation:**
```bash
kubectl get pods -n kube-system | grep akeyless
kubectl get csidriver | grep akeyless
```

### 2. Configure Authentication

Choose your authentication method in Akeyless:

#### Option A: Kubernetes Auth (Recommended)
```bash
# In Akeyless UI:
# 1. Auth Methods → Create New → Kubernetes
# 2. Set API Gateway URL
# 3. Bind Service Account (e.g., default)
```

**Pros:**
- No credentials stored in K8s
- Leverages K8s RBAC
- Better audit trail

#### Option B: API Key Auth
```bash
# In Akeyless UI:
# 1. Settings → API Keys
# 2. Create new API Key
# 3. Get Access ID and Secret Key
```

**Pros:**
- Simpler setup
- Works immediately

### 3. Create SecretProviderClass

File: `kubernetes/base/SecretProviderClass.yml`

```yaml
apiVersion: secrets-store.csi.x-k8s.io/v1
kind: SecretProviderClass
metadata:
  name: akeyless-secrets
  namespace: default
spec:
  provider: akeyless
  
  # Authentication configuration
  parameters:
    # API Gateway address
    gatewayAddress: "https://api.akeyless.io"
    
    # For Kubernetes Auth (recommended):
    # accessId: "p-123456789"  # Akeyless K8s Auth ID
    # accessKey: "YOUR_ACCESS_KEY"
    
    # Secret definitions
    objects: |
      - objectName: "/prod/db/password"
        objectType: "secret"
        objectAlias: "DB_PASSWORD"
      
      - objectName: "Redis_password"
        objectType: "secret"
        objectAlias: "REDIS_PASSWORD"
  
  # Sync to K8s Native Secret (optional but recommended)
  secretObjects:
  - data:
    - objectKey: "DB_PASSWORD"
      key: "db-password"
    - objectKey: "REDIS_PASSWORD"
      key: "redis-password"
    secretKey: akeyless-secrets-synced
    type: Opaque
```

### 4. Create Secrets in Akeyless

```bash
# Create DB password
akeyless create-secret \
  --path /prod/db/password \
  --secret-value "your-secure-db-password"

# Create Redis password
akeyless create-secret \
  --path Redis_password \
  --secret-value "your-secure-redis-password"
```

Or use Akeyless UI:
1. Secrets → Create Secret
2. Set path and value
3. Save

### 5. Mount Secrets in Pods

In your deployment (e.g., `redis-deployment.yml` or service deployments):

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: my-service
spec:
  template:
    spec:
      serviceAccountName: default  # Must exist
      
      # 1. Define CSI volume
      volumes:
      - name: secrets-store
        csi:
          driver: secrets-store.csi.akeyless.com
          readOnly: true
          volumeAttributes:
            secretProviderClass: "akeyless-secrets"
      
      containers:
      - name: my-service
        image: my-image:latest
        
        # 2. Mount CSI volume
        volumeMounts:
        - name: secrets-store
          mountPath: "/mnt/secrets-store"
          readOnly: true
        
        # 3. Reference synced K8s Secret in env vars
        env:
        - name: REDIS_PASSWORD
          valueFrom:
            secretKeyRef:
              name: akeyless-secrets-synced
              key: redis-password
        
        - name: DB_PASSWORD
          valueFrom:
            secretKeyRef:
              name: akeyless-secrets-synced
              key: db-password
```

---

## How Secrets Flow

### Within the Cluster

1. **Pod Creation**
   - K8s scheduler launches pod with SPC volume reference

2. **CSI Driver Invoked**
   - CSI Plugin intercepts volume mount request
   - Reads SecretProviderClass definition
   - Authenticates to Akeyless

3. **Secrets Fetched**
   - CSI Driver calls Akeyless API
   - Retrieves secret values
   - Mounts to `/mnt/secrets-store/` (optional)
   - Syncs to K8s Secret `akeyless-secrets-synced`

4. **Pod Receives Secrets**
   - Environment variables populated from K8s Secret
   - Application reads `$REDIS_PASSWORD` and `$DB_PASSWORD`

### Example: Redis Connection

```python
# Application code
import os
import redis

redis_host = os.getenv("REDIS_HOST", "redis-service")
redis_port = int(os.getenv("REDIS_PORT", 6379))
redis_password = os.getenv("REDIS_PASSWORD")

redis_client = redis.Redis(
    host=redis_host,
    port=redis_port,
    password=redis_password,
    decode_responses=True
)

# Successfully connected via Akeyless-managed password!
```

---

## File Locations

```
kubernetes/
├── base/
│   ├── SecretProviderClass.yml    ← Where CSI gets secret definitions
│   ├── redis-deployment.yml        ← Mounts and uses secrets
│   ├── admin-bl-service-deployment.yaml
│   ├── user-bl-service-deployment.yml
│   └── ... (other services)
│
└── kustomization.yaml              ← Lists SecretProviderClass
```

---

## Verification & Troubleshooting

### Verify Installation

```bash
# Check CSI driver
kubectl get csidriver
kubectl get pods -n kube-system -l app=akeyless-csi-provider

# Check SecretProviderClass
kubectl get secretproviderclass
kubectl describe spc akeyless-secrets
```

### Verify Secret Sync

```bash
# Check if synced K8s Secret was created
kubectl get secret akeyless-secrets-synced -o yaml

# Expected output:
# data:
#   db-password: WzBdPWFsaWFzZXMtc2VjcmV0... (base64)
#   redis-password: WzBdPWFsaWFzZXMtc2VjcmV0... (base64)
```

### Check Pod Status

```bash
# View pod details
kubectl describe pod <pod-name>

# Check environment variables
kubectl exec <pod-name> -- env | grep PASSWORD

# Check volume mounts
kubectl exec <pod-name> -- ls -la /mnt/secrets-store/
```

### View Akeyless CSI Logs

```bash
# Get CSI driver logs
kubectl logs -n kube-system -l app=akeyless-csi-provider -f

# Filter for your pod
kubectl logs -n kube-system -l app=akeyless-csi-provider | grep "Redis_password"
```

### Common Issues

| Issue | Solution |
|-------|----------|
| Secret not syncing | Check CSI driver logs, verify gatewayAddress, ensure secret path exists in Akeyless |
| Authorization denied | Verify Akeyless auth credentials (accessId/accessKey), check K8s auth binding |
| Pod can't connect to service | Ensure REDIS_HOST env var is set to service DNS name (redis-service) |
| Stale secrets in pod | Secrets sync automatically; restart pod to refresh `kubectl rollout restart` |

---

## Security Best Practices

### 1. **Use Kubernetes Auth** (Not API Keys)
- Eliminates hardcoded credentials in manifests
- Leverages K8s built-in RBAC
- Better audit trail

### 2. **Separate Credentials by Environment**
```bash
# Development
/dev/db/password
/dev/redis/password

# Staging
/staging/db/password
/staging/redis/password

# Production
/prod/db/password
/prod/redis/password
```

### 3. **Limit Secret Access with RBAC**
```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: secret-reader
rules:
- apiGroups: [""]
  resources: ["secrets"]
  resourceNames: ["akeyless-secrets-synced"]  # Only this secret
  verbs: ["get"]
```

### 4. **Enable Audit Logging**
- Enable Akeyless event logs
- Monitor who accessed which secrets and when
- Set up alerts for unauthorized attempts

### 5. **Rotate Secrets Regularly**
```bash
# Update in Akeyless
akeyless update-secret \
  --path /prod/db/password \
  --secret-value "new-secure-password"

# Restart pods to pick up new rotation
kubectl rollout restart deployment/<deployment-name>
```

### 6. **Never Commit Credentials**
- Add `secrets.yml` to `.gitignore`
- Never log secret values
- Use base64 encoding for K8s secrets (it's obfuscation, not encryption)

---

## Current Setup Summary

Your deployment uses:
- **SecretProviderClass**: `akeyless-secrets`
- **Synced Secret**: `akeyless-secrets-synced`
- **Secrets Managed**:
  - `/prod/db/password` → `DB_PASSWORD` env var
  - `Redis_password` → `REDIS_PASSWORD` env var
- **Services Using Secrets**: redis, admin-bl-service, user-bl-service, job-bl-service (and others as configured)

---

## References

- [Akeyless Official Docs](https://docs.akeyless.io/)
- [Kubernetes Secrets Store CSI Driver](https://secrets-store-csi-driver.sigs.k8s.io/)
- [Akeyless K8s Integration](https://docs.akeyless.io/docs/kubernetes)
- [K8s RBAC Documentation](https://kubernetes.io/docs/reference/access-authn-authz/rbac/)
