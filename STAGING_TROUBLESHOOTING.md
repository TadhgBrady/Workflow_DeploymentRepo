# Staging Deployment Troubleshooting Guide

This document records all issues encountered during the first manual deployment to the AWS EKS staging environment and their resolutions. Use it as a reference when deploying via the CI/CD pipeline or debugging staging issues.

## Environment Details

| Component | Value |
|-----------|-------|
| EKS Cluster | `yr4-project-staging-eks` |
| Region | `eu-west-1` |
| Nodes | 2x `t3.medium` |
| Namespace | `year4-project-staging` |
| RDS Host | `yr4-project-staging-postgres.cxmw8skaythd.eu-west-1.rds.amazonaws.com` |
| RDS Database | `crm_calendar_staging` |
| Redis Host | `yr4-project-staging-redis.ftr3sw.ng.0001.euw1.cache.amazonaws.com:6379` |
| App URL | Via NLB provisioned by NGINX Ingress Controller |
| AWS Account | `156041414798` |

---

## 1. EKS Cluster Access

### Problem
`kubectl` could not authenticate to the cluster — `Unauthorized` errors.

### Root Cause
The EKS cluster was created with `authenticationMode: API` but no access entry existed for the IAM user being used (`BENCE_PC`).

### Fix
```bash
# Update cluster auth mode to API_AND_CONFIG_MAP
aws eks update-cluster-config --name yr4-project-staging-eks \
  --access-config authenticationMode=API_AND_CONFIG_MAP

# Create access entry for the IAM user
aws eks create-access-entry --cluster-name yr4-project-staging-eks \
  --principal-arn arn:aws:iam::156041414798:user/BENCE_PC \
  --type STANDARD

# Associate cluster admin policy
aws eks associate-access-policy --cluster-name yr4-project-staging-eks \
  --principal-arn arn:aws:iam::156041414798:user/BENCE_PC \
  --policy-arn arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy \
  --access-scope type=cluster

# Update kubeconfig
aws eks update-kubeconfig --name yr4-project-staging-eks --region eu-west-1
```

---

## 2. Resource Exhaustion (Pods Pending)

### Problem
After initial deployment, several pods stayed in `Pending` state with `Insufficient cpu` / `Insufficient memory` errors.

### Root Cause
Default replica count was 2 per deployment. Two `t3.medium` nodes (2 vCPU, 4 GiB each) couldn't schedule 24 pods.

### Fix
Reduced all deployments to 1 replica in the staging kustomization overlay:
```yaml
# kubernetes/overlays/staging/kustomization.yaml
replicas:
  - name: auth-service
    count: 1
  # ... (all 12 services set to count: 1)
```

---

## 3. Placeholder Secrets → Real Credentials

### Problem
Initial deployment used placeholder secrets (`changeme`, `your-secret-key-here`). Services couldn't connect to RDS or Redis.

### Root Cause
The kustomization didn't include real credentials from AWS Secrets Manager.

### Fix
Retrieved real credentials from AWS Secrets Manager and created proper K8s secrets:

```bash
# Get credentials from AWS
aws secretsmanager get-secret-value --secret-id yr4-project/staging/db-credentials
aws secretsmanager get-secret-value --secret-id yr4-project/staging/redis-credentials
aws secretsmanager get-secret-value --secret-id yr4-project/staging/app-secrets

# Create K8s secrets (example for db-credentials)
kubectl create secret generic db-credentials -n year4-project-staging \
  --from-literal=DATABASE_URL="postgresql+asyncpg://yr4admin:<password>@<rds-host>:5432/crm_calendar_staging" \
  --dry-run=client -o yaml | kubectl apply -f -

# Create app-config ConfigMap
kubectl create configmap app-config -n year4-project-staging \
  --from-literal=ENVIRONMENT=staging \
  --from-literal=LOG_LEVEL=INFO \
  --from-literal=CORS_ORIGINS="*" \
  --dry-run=client -o yaml | kubectl apply -f -
```

**Required secrets:**
- `db-credentials` — `DATABASE_URL` (PostgreSQL async connection string)
- `redis-credentials` — `REDIS_URL_*` per service (7 URLs with DB numbers 0-6)
- `app-secrets` — `SECRET_KEY`, `NOTIFICATION_ENCRYPTION_KEY`
- `app-config` (ConfigMap) — `ENVIRONMENT`, `LOG_LEVEL`, `CORS_ORIGINS`

After updating secrets, restart all pods:
```bash
kubectl rollout restart deployment -n year4-project-staging
```

---

## 4. RDS / Redis Connectivity Timeout

### Problem
Migration runner and service pods timed out connecting to RDS and Redis. `psql` from a debug pod also timed out.

### Root Cause
The RDS and Redis security groups only allowed inbound traffic from the **old/wrong cluster security group** (`sg-09060e6c94cc33dd1`), not the actual EKS node security group (`sg-0bc23544cc544e822`).

### Identifying the SGs
```bash
# Find the node security group
aws ec2 describe-instances --filters "Name=tag:eks:cluster-name,Values=yr4-project-staging-eks" \
  --query "Reservations[].Instances[].SecurityGroups[]" --output table

# Check RDS security group rules
aws ec2 describe-security-groups --group-ids sg-00510246875c06bd4 \
  --query "SecurityGroups[].IpPermissions"
```

### Fix
```bash
# Add node SG to RDS security group
aws ec2 authorize-security-group-ingress --group-id sg-00510246875c06bd4 \
  --protocol tcp --port 5432 --source-group sg-0bc23544cc544e822

# Add node SG to Redis security group
aws ec2 authorize-security-group-ingress --group-id sg-0745c69ffce8adcdc \
  --protocol tcp --port 6379 --source-group sg-0bc23544cc544e822
```

> **IMPORTANT**: The Terraform `modules/rds/` and `modules/elasticache/` create SG rules pointing to the cluster SG, not the node SG. If you run `terraform apply`, it may revert this fix. Update the Terraform module to reference the correct node SG.

---

## 5. 502 Bad Gateway — Ingress Host Restriction

### Problem
Accessing the app via the NLB hostname returned 502 Bad Gateway.

### Root Cause
The Ingress resource had `host: localhost`, so the NGINX Ingress Controller only matched requests with `Host: localhost`. Requests via the NLB hostname (`af81162ae...elb.amazonaws.com`) didn't match and returned 404, which became 502 to the client.

### Fix
Created a staging overlay patch to remove the host restriction:

```yaml
# kubernetes/overlays/staging/ingress-patch.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: app-ingress
  annotations:
    nginx.ingress.kubernetes.io/ssl-redirect: "false"
    nginx.ingress.kubernetes.io/force-ssl-redirect: "false"
spec:
  tls: []
  rules:
    - http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: nginx-gateway
                port:
                  number: 80
```

Add to kustomization.yaml:
```yaml
patches:
  - path: ingress-patch.yaml
```

---

## 6. 502 Bad Gateway — Nginx Gateway server_name

### Problem
Even after removing the Ingress host restriction, requests still returned 502.

### Root Cause
The `nginx-configmap.yaml` had TWO server blocks:
1. `server { server_name _; return 444; }` — default catch-all that **drops** connections
2. `server { server_name localhost; ... }` — the main routing server

The NLB hostname didn't match `localhost`, so all requests hit the default server and got connection dropped (444), which NGINX Ingress reported as 502.

### Fix
Merged into a single server block with `server_name _` (accept any hostname):

```nginx
server {
    listen 8080;
    server_name _;

    # ... all proxy_pass rules ...
}
```

Removed the default server block entirely.

---

## 7. Service Port Mismatch (Docker Compose vs K8s)

### Problem
Superadmin login bounced back to `/login?next=/admin` in a loop. Auth returned 200 but the admin page could not verify the session.

### Root Cause
The frontend's `service_client.py` hardcodes service URLs with container ports:
```python
_AUTH_SERVICE_URL = "http://auth-service:8005"
_JOB_BL_URL = "http://job-bl-service:8006"
_USER_BL_URL = "http://user-bl-service:8004"
_CUSTOMER_BL_URL = "http://customer-bl-service:8007"
```

In docker-compose, containers communicate directly on their container ports (8004, 8005, etc.).

In K8s, the ClusterIP services expose **port 80** and map to the target port internally. So `auth-service:8005` times out because the ClusterIP only listens on port 80.

The login proxy worked because `api_proxy.py` uses `settings.auth_service_url` from the env var `AUTH_SERVICE_URL=http://auth-service` (port 80 by default). But `service_client.py` bypasses settings and hardcodes the ports.

### Quick Fix (Applied)
Added the container ports as additional service ports:
```bash
# For each service, add its container port to the K8s service
kubectl patch svc auth-service -n year4-project-staging --type=json \
  --patch-file <(echo '[{"op":"add","path":"/spec/ports/-","value":{"name":"legacy","port":8005,"targetPort":8005,"protocol":"TCP"}}]')
```

Services patched: `auth-service` (8005), `job-bl-service` (8006), `user-bl-service` (8004), `customer-bl-service` (8007)

### Proper Fix (TODO)
Update `service_client.py` to use environment variables or `settings.*` instead of hardcoded URLs. The K8s deployment already provides `AUTH_SERVICE_URL`, `JOB_SERVICE_URL`, `USER_SERVICE_URL`, `CUSTOMER_SERVICE_URL` as env vars without ports.

---

## 8. Database Migrations

### Problem
No migration job was defined in the staging overlay. The database had no tables.

### Fix
Ran the migration-runner image manually as a one-shot pod:
```bash
kubectl run migration-runner \
  --image=bencev04/4th-year-proj-tadgh-bence:migration-runner-latest \
  --namespace=year4-project-staging \
  --restart=Never \
  --env="DATABASE_URL=postgresql+asyncpg://yr4admin:<password>@<rds-host>:5432/crm_calendar_staging" \
  --command -- alembic upgrade head

# Monitor progress
kubectl logs -f migration-runner -n year4-project-staging

# Clean up
kubectl delete pod migration-runner -n year4-project-staging
```

All 9 Alembic migrations applied successfully.

### Seeding Demo Data
The seed SQL file wasn't baked into the image. Piped via stdin:
```bash
# From where seed-demo-data.sql is available
kubectl run seed-runner \
  --image=python:3.11-slim \
  --namespace=year4-project-staging \
  --restart=Never \
  -i --rm \
  --command -- python3 -c "
import sys, psycopg2
conn = psycopg2.connect('postgresql://yr4admin:<password>@<rds-host>:5432/crm_calendar_staging')
cur = conn.cursor()
cur.execute(sys.stdin.read())
conn.commit()
print('Seed complete')
" < scripts/seed-demo-data.sql
```

---

## 9. Login Validation Results

### owner@demo.com (Organization Owner)
- **Status**: Login successful
- **Redirects to**: `/calendar` — Monthly calendar view
- **Features visible**: Calendar (Month/Week/Day), New Job button, Job Queue, Status legend
- **Notes**: No jobs displayed (empty calendar). "Failed to reach" warnings for BL services in frontend logs (expected during first load with no data)

### superadmin@system.local (Platform Admin)
- **Status**: Login successful (after port mismatch fix)
- **Redirects to**: `/admin` — Admin Portal
- **Features visible**: Organizations tab (Default Organization, Second Organization), Users, Audit Logs, Settings tabs
- **Notes**: Shows GDPR consent dialog on first login. Both organizations show Active status with correct plan limits.

---

## Quick Reference — Common Commands

```bash
# Check all pods
kubectl get pods -n year4-project-staging

# Check pod logs
kubectl logs deployment/<name> -n year4-project-staging --tail=50

# Restart all pods (after secret changes)
kubectl rollout restart deployment -n year4-project-staging

# Check service ports
kubectl get svc -n year4-project-staging

# Exec into a pod for debugging
kubectl exec -it deployment/<name> -n year4-project-staging -- /bin/sh

# Check events for failed pods
kubectl get events -n year4-project-staging --sort-by='.lastTimestamp'

# View secrets
kubectl get secret <name> -n year4-project-staging -o jsonpath='{.data.DATABASE_URL}' | base64 -d
```

---

## Known Issues / TODO

1. **Terraform SG rules**: The RDS and Redis Terraform modules create SG rules pointing to the wrong (cluster) security group instead of the node SG. Manual fix applied; needs Terraform update.
2. **Frontend hardcoded ports**: `service_client.py` hardcodes container ports (8004-8007) instead of using env vars. Quick-fixed with extra K8s service ports; needs code fix.
3. **Migration job**: No migration job in staging overlay. Should add a Kubernetes Job to run migrations automatically during deployment.
4. **Seed data**: Not automated. Consider adding a seed Job or init container.
5. **TLS**: Staging currently runs on HTTP only. For production, configure cert-manager and TLS on the Ingress.
6. **Google Maps API key**: Console warnings about invalid key. Need to provision a valid API key for the maps-access-service.
