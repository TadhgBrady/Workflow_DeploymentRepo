# CD Pipeline Plan — AWS Deployment with ArgoCD, Terraform & Canary Strategy

> **Status:** Planning / In Progress  
> **Last Updated:** March 2026  
> **Deployment Repo:** `yr4-projectdeploymentrepo`  
> **Dev Repo (CI):** `yr4-projectdevelopmentrepo`

---

## Overview

This document outlines the complete CD pipeline plan for deploying the Year 4 Project
microservices platform to AWS. The pipeline receives triggers from the existing dev repo
CI pipeline and deploys through staging (with full validation) to production using a
canary (slow switchover) strategy.

### Architecture Summary

```
Dev Repo CI (GitLab):
  Push → Lint → Test (×8, 80% cov) → Security → Integration → Build/Push → Manual Trigger
                                                                                  ↓
Deployment Repo CD (GitLab):                                                 ═══════════
  Validate → Update Tags → Deploy Staging → [Playwright + k6 + Smoke] → Promote → Deploy Prod → Validate
                                                                                  ↑
ArgoCD (on EKS):                                                             ═══════════
  Detect repo change → Canary rollout (Argo Rollouts) → Health checks → Done

Terraform:
  Scale staging/production up or down independently to minimise AWS cost
```

### How the Dev Repo Triggers the CD Pipeline

The dev repo's `.gitlab-ci.yml` final stage (`trigger-deploy`) fires a GitLab webhook:

```yaml
# Dev repo — trigger-deploy stage (main branch, manual gate)
curl --fail --request POST
  --form "token=${DEPLOY_REPO_TRIGGER_TOKEN}"
  --form "ref=main"
  --form "variables[IMAGE_TAG]=${IMAGE_TAG}"           # Docker Hub registry path
  --form "variables[IMAGE_VERSION]=${IMAGE_VERSION}"   # Short SHA (e.g., a1b2c3d4)
  --form "variables[SOURCE_COMMIT]=${CI_COMMIT_SHA}"   # Full SHA
  --form "variables[SOURCE_BRANCH]=${CI_COMMIT_BRANCH}"
  "${DEPLOY_REPO_TRIGGER_URL}"
```

Image naming convention from dev repo build stage:
- `$IMAGE_TAG:{service}-{IMAGE_VERSION}` (SHA-tagged, immutable)
- `$IMAGE_TAG:{service}-latest` (rolling latest)

---

## CD Pipeline Stages

### Stage 1: Validate

**Jobs:** `validate-manifests`, `validate-terraform`, `validate-helm` (run in parallel)

| Job | Tool | What it checks |
|-----|------|---------------|
| validate-manifests | `kubeconform` | Kustomize overlays produce valid K8s YAML for staging + production |
| validate-terraform | `terraform validate` + `fmt --check` | Terraform configs for both environments are syntactically valid |
| validate-helm | `helm template --debug` | All Helm value files render without errors |

**Gate:** Hard — all three must pass.

### Stage 2: Update Image Tags

**Job:** `update-image-tags`

- Patches `kubernetes/overlays/staging/kustomization.yaml` `newTag` with received `IMAGE_VERSION`
- Commits the change back to the deployment repo
- ArgoCD watches this repo — the commit triggers automatic staging sync

### Stage 3: Deploy Staging

**Job:** `deploy-staging`

- Uses ArgoCD CLI to force-sync the staging application
- Waits for all resources to become healthy (600s timeout)
- Canary rollout (via Argo Rollouts) progresses through steps:
  - **Staging (fast):** 10% → 50% → 100% with shorter pauses

### Stage 4: Staging Tests (3 parallel jobs)

All three jobs run simultaneously against the staging environment:

#### 4a. Smoke Tests (`smoke-tests-staging`) — HARD GATE
- Hits `/health` endpoint of all 9 backend services + frontend
- Must all return 200 to proceed

#### 4b. Playwright E2E Tests (`playwright-e2e-staging`) — SOFT GATE (placeholder)
> **Status:** 🔲 To be implemented

Browser-based end-to-end tests covering critical user journeys:
- Authentication (login, logout, token refresh)
- Customer CRUD operations
- Job scheduling & conflict detection
- Calendar view rendering
- Admin panel & user management
- Multi-tenant data isolation

**Setup required:**
1. Create `tests/e2e/` directory with Playwright project
2. Write test specs for each critical journey
3. Configure `playwright.config.ts` with `baseURL` from env
4. Remove `allow_failure: true` once tests are stable

#### 4c. Grafana k6 Load Tests (`k6-load-tests-staging`) — SOFT GATE (placeholder)
> **Status:** 🔲 To be implemented

Performance/load tests validating the deployment handles expected traffic:

**Suggested scenarios:**
- Baseline: 10 VUs × 1 minute (health check)
- Ramp-up: 1 → 50 VUs over 3 minutes (normal load)
- Spike: 50 → 100 VUs × 1 minute (burst traffic)

**Suggested thresholds:**
- `http_req_duration` p(95) < 500ms
- `http_req_failed` rate < 1%
- `http_reqs` count > 1000 (minimum throughput)

**Endpoints to test:**
- All 9 service health endpoints
- Auth flow (login → token → refresh)
- Customer list + search (read-heavy)
- Job creation + scheduling (write-heavy)
- Mixed realistic workload

**Setup required:**
1. Create `tests/k6/` directory with k6 test scripts
2. Write `staging-load-test.js` with scenarios above
3. Configure `BASE_URL` from environment variable
4. Remove `allow_failure: true` once thresholds are tuned

### Stage 5: Promote to Production (Manual Gate)

**Job:** `promote-to-production` — requires manual click (same pattern as dev repo `trigger-deploy`)

- Updates `kubernetes/overlays/production/kustomization.yaml` `newTag` with validated `IMAGE_VERSION`
- Commits to repo → ArgoCD detects change
- Prints reminder: "Approve sync in ArgoCD UI"

### Stage 6: Deploy Production

**Job:** `deploy-production`

- ArgoCD CLI force-syncs production application
- Waits for healthy (900s timeout — conservative canary takes longer)
- Canary rollout steps:
  - **Production (conservative):** 10% → pause 2m → 30% → pause 2m → 60% → pause 2m → 100%
- Argo Rollouts AnalysisTemplates auto-rollback on:
  - HTTP 5xx rate > 5%
  - Pod restart count > 2
  - Health endpoint failures

### Stage 7: Production Validation

**Job:** `smoke-tests-production`

- Same health check suite as staging
- All 9 services + frontend must return 200
- Failure triggers notification stage

### Stage 8: Notify

**Jobs:** `notify-success` / `notify-failure` (conditional)

- Prints deployment summary (version, commit, pipeline URL)
- TODO: Webhook to Slack/Teams

---

## Infrastructure Scale-Up / Scale-Down

Both staging and production can be brought up or down independently via manual GitLab CI jobs:

| Job | Effect |
|-----|--------|
| `scale-up-staging` | `terraform apply -var="enabled=true"` — EKS nodes + RDS + Redis up |
| `scale-down-staging` | `terraform apply -var="enabled=false"` — EKS nodes=0, RDS stopped |
| `scale-up-production` | `terraform apply -var="enabled=true"` — production infra up |
| `scale-down-production` | `terraform apply -var="enabled=false"` — production infra down |

**Typical cost-saving workflow:**
1. `scale-up-staging` → bring staging up
2. Pipeline deploys & validates in staging
3. `scale-up-production` → bring prod up
4. Promote → canary rollout to production
5. `scale-down-staging` → no longer needed
6. After demo/active use → `scale-down-production`

**Caveats:**
- EKS control plane ($0.10/hr) still bills even when nodes = 0
- RDS auto-restarts after 7 days when stopped — re-run scale-down if needed

---

## Infrastructure To Be Created (Terraform)

```
terraform/
├── modules/
│   ├── vpc/              # VPC, 2 AZs, public + private subnets, NAT gateway
│   ├── eks/              # EKS cluster, managed node groups, OIDC/IRSA
│   ├── rds/              # RDS PostgreSQL 15 (managed, not in K8s)
│   ├── elasticache/      # ElastiCache Redis 7 (managed, not in K8s)
│   └── iam/              # IAM roles for EKS, ArgoCD, External Secrets
├── environments/
│   ├── staging/          # t3.medium spots, db.t3.micro, cache.t3.micro
│   └── production/       # t3.large on-demand, db.t3.small multi-AZ, cache.t3.small
└── bootstrap/            # One-time: S3 state bucket + DynamoDB lock table
```

## ArgoCD Configuration To Be Created

```
argocd/
├── install/values.yaml          # ArgoCD Helm values
├── applications/
│   ├── staging.yaml             # Auto-sync, points to overlays/staging
│   └── production.yaml          # Manual sync, points to overlays/production
├── appproject.yaml              # RBAC scoping for both envs
└── repository-secret.yaml       # Git repo credentials (encrypted)
```

## Kubernetes Manifests To Be Updated

| Resource | Status | Notes |
|----------|--------|-------|
| Deployments → Rollouts | 🔲 TODO | Convert all 11 `kind: Deployment` to `kind: Rollout` with canary strategy |
| ExternalSecrets | 🔲 TODO | Pull DATABASE_URL, REDIS_URL, SECRET_KEY from AWS Secrets Manager |
| Migration Job | 🔲 TODO | Alembic migration as sync wave -1 (runs before app services) |
| Network Policies | 🔲 TODO | Default deny + allow nginx→BL→DB-access→RDS/Redis |
| Service Accounts | 🔲 TODO | Per-service SA with IRSA annotations |
| HPA | 🔲 TODO | Already in Helm values, need Kustomize manifests |
| Canary Services | 🔲 TODO | `-stable` and `-canary` Service per Rollout |

---

## GitLab CI/CD Variables Required

Set these in the deployment repo's GitLab Settings → CI/CD → Variables:

| Variable | Description |
|----------|-------------|
| `AWS_ACCESS_KEY_ID` | AWS IAM credentials (or use OIDC federation) |
| `AWS_SECRET_ACCESS_KEY` | AWS IAM credentials |
| `AWS_DEFAULT_REGION` | e.g., `eu-west-1` |
| `ARGOCD_SERVER` | ArgoCD server URL |
| `ARGOCD_AUTH_TOKEN` | ArgoCD API token for CLI |
| `STAGING_URL` | Staging ALB/ingress URL (set after infra provisioned) |
| `PROD_URL` | Production ALB/ingress URL (set after infra provisioned) |
| `SLACK_WEBHOOK_URL` | (Optional) Notification webhook |

---

## Decisions

- **Kustomize** as primary ArgoCD source (overlays more complete than Helm for this project)
- **Single EKS cluster** with namespace isolation (staging + prod) — cost-effective
- **Docker Hub** stays as image registry (already wired in dev repo CI)
- **External Secrets Operator** for secrets (AWS IRSA integration)
- **Argo Rollouts** for canary strategy (lighter than Istio/Linkerd, native ArgoCD integration)
- **RDS + ElastiCache** (AWS-managed) — databases NOT running in K8s pods
- **Playwright** for E2E (modern, reliable, CI-friendly)
- **Grafana k6** for load testing (scriptable, supports thresholds, lightweight)
