# Plan: Fix All Staging Deployment Issues

## TL;DR
Fix 8 issues across 3 repos (infra, deployment, development) discovered during manual staging deployment. The changes ensure future pipeline deployments work without manual intervention. Grouped into 3 phases by repo, with Phase A (development) and Phase B (deployment) parallelizable.

---

## Phase A — Development Repo (frontend hardcoded ports)

**Goal:** Replace hardcoded service URLs in `service_client.py` and `main.py` with config-driven values that read environment variables.

**Steps:**

1. **Update `service_client.py` to use shared config settings** — *independent*
   - Replace 4 hardcoded module-level constants with `settings.*` from `common.config`
   - `_JOB_BL_URL` → `settings.job_bl_service_url`
   - `_USER_BL_URL` → `settings.user_bl_service_url`
   - `_CUSTOMER_BL_URL` → `settings.customer_bl_service_url`
   - `_AUTH_SERVICE_URL` → `settings.auth_service_url`
   - Since `settings` is a pydantic `BaseSettings`, these read env vars automatically (e.g. `AUTH_SERVICE_URL`)
   - File: `services/frontend/app/service_client.py` lines 34-45
   - Note: Use lazy access via `get_settings()` or import `settings` singleton to avoid circular imports

2. **Update `main.py` readiness check** — *independent, parallel with step 1*
   - Replace hardcoded `"http://auth-service:8005"` in `check_services` dict with `settings.auth_service_url`
   - File: `services/frontend/app/main.py` line 173

3. **Verify docker-compose.yml env vars match config.py field names** — *depends on 1*
   - docker-compose sets `AUTH_SERVICE_URL`, `JOB_SERVICE_URL`, `USER_SERVICE_URL`, `CUSTOMER_SERVICE_URL`
   - config.py expects `auth_service_url`, `job_bl_service_url`, `user_bl_service_url`, `customer_bl_service_url`
   - Mismatch: docker-compose uses `JOB_SERVICE_URL` but config.py field is `job_bl_service_url` (env var `JOB_BL_SERVICE_URL`)
   - Fix: Update docker-compose.yml to use `JOB_BL_SERVICE_URL`, `USER_BL_SERVICE_URL`, `CUSTOMER_BL_SERVICE_URL` (or add aliases in config.py)
   - File: `docker-compose.yml` frontend service env section

4. **Add auth guard to `/` and `/calendar` routes** — *independent, parallel with 1-3*
   - Currently unauthenticated users reach `/calendar` and see an empty page. `/` always redirects to `/calendar`.
   - In `main.py` `index()` (~line 137): if `get_current_user(request)` returns None → redirect to `/login`
   - In `routes/calendar.py` `calendar_page()` (~line 765): add auth check at top, redirect to `/login` if no valid user
   - Files: `services/frontend/app/main.py`, `services/frontend/app/routes/calendar.py`

**Relevant files:**
- `services/frontend/app/service_client.py` — replace hardcoded URLs (lines 34-45) with `get_settings()`
- `services/frontend/app/main.py` — replace hardcoded auth URL (line 173) + add auth redirect on `/`
- `services/frontend/app/routes/calendar.py` — add auth guard to `/calendar`
- `services/shared/common/config.py` — reference for settings field names (lines 72-89)
- `docker-compose.yml` — update frontend env vars to match config field names

---

## Phase B — Deployment Repo (K8s manifests)

**Goal:** Add missing staging resources (migration job, app-config configmap) and persist the service port fix properly in manifests.

**Steps:**

4. **Add service port patches for staging overlay** — *independent*
   - Until Phase A is deployed (new Docker images built), the frontend still needs container ports on services
   - Create staging patch files to add legacy container ports to 4 services
   - After Phase A is deployed, these patches can be removed
   - Services: auth-service (8005), job-bl-service (8006), user-bl-service (8004), customer-bl-service (8007)
   - Create: `kubernetes/overlays/staging/service-ports-patch.yaml`
   - Add to: `kubernetes/overlays/staging/kustomization.yaml` patches list

5. **Add migration job to staging overlay** — *independent, parallel with 4*
   - Copy `kubernetes/overlays/local/migration-job.yaml` to `kubernetes/overlays/staging/migration-job.yaml`
   - Adjust `imagePullPolicy` from `IfNotPresent` to `Always` for staging
   - Add to staging `kustomization.yaml` resources list
   - Note: Pipeline should apply the job before waiting for rollout

6. **Add app-config configmap to staging overlay** — *independent, parallel with 4, 5*
   - Add `configMapGenerator` to `kubernetes/overlays/staging/kustomization.yaml`
   - Set `ENVIRONMENT=staging`, `LOG_LEVEL=INFO`, `CORS_ORIGINS=*`
   - Reference: `kubernetes/overlays/local/kustomization.yaml` lines 81-92

7. **Update frontend-deployment.yml env vars** — *depends on Phase A step 3*
   - Update env var names to match config.py field names:
     - `USER_SERVICE_URL` → `USER_BL_SERVICE_URL`
     - `CUSTOMER_SERVICE_URL` → `CUSTOMER_BL_SERVICE_URL`
     - `JOB_SERVICE_URL` → `JOB_BL_SERVICE_URL`
   - File: `kubernetes/base/frontend-deployment.yml` lines 25-50

---

## Phase C — Infrastructure Repo (Terraform SG fix)

**Goal:** Fix security group rules so RDS and Redis allow traffic from EKS node SG instead of cluster SG.

> ⚠️ **CAUTION:** Adding a launch_template to an existing node group FORCES NODE GROUP REPLACEMENT. All pods will be rescheduled. Plan for downtime or do this during a maintenance window.

**Steps:**

8. **Create explicit node security group in EKS module** — *independent*
   - Add `aws_security_group.node` resource with:
     - Ingress from cluster SG (ports 1025-65535)
     - Self-referencing ingress (node-to-node)
     - All outbound egress
   - Add `aws_launch_template.node` with `vpc_security_group_ids = [aws_security_group.node.id]`
   - Update `aws_eks_node_group.main` to use `launch_template { id = aws_launch_template.node.id, version = "$Latest" }`
   - File: `modules/eks/main.tf` (add after line 141)

9. **Export node SG from EKS module** — *depends on 8*
   - Add output `node_security_group_id` = `aws_security_group.node.id`
   - File: `modules/eks/outputs.tf` (add new output)

10. **Update RDS module to use node SG** — *depends on 9*
    - Change variable name from `eks_security_group_id` to `eks_node_security_group_id` (for clarity)
    - Update `aws_security_group_rule.rds_ingress` source to use the new variable
    - Files: `modules/rds/variables.tf` (line 17-20), `modules/rds/main.tf` (line 58)

11. **Update ElastiCache module to use node SG** — *parallel with 10, depends on 9*
    - Same variable rename and source SG update
    - Files: `modules/elasticache/variables.tf` (line 17-20), `modules/elasticache/main.tf` (line 58)

12. **Update root module to pass node SG** — *depends on 9, 10, 11*
    - Change `module.rds.eks_security_group_id` → `module.eks.node_security_group_id`
    - Change `module.elasticache.eks_security_group_id` → `module.eks.node_security_group_id`
    - File: `terraform/main.tf` lines 122 and 145

13. **Run `terraform plan` to validate** — *depends on 12*
    - Verify plan shows: new node SG, new launch template, node group replacement, updated SG rules
    - Review for any unexpected changes before applying

---

## Verification

1. **Phase A** — Run existing frontend unit/integration tests locally with `docker-compose up` to verify service URLs still resolve (docker-compose env vars override defaults)
2. **Phase B** — `kubectl apply -k kubernetes/overlays/staging --dry-run=client` to validate manifests render correctly
3. **Phase B** — After apply: verify migration job completes, app-config configmap exists, services have both port 80 and legacy ports
4. **Phase C** — `terraform plan` in `terraform/` directory — verify expected changes (node SG creation, node group replacement, SG rule updates)
5. **End-to-end** — After all phases: test login as `owner@demo.com` and `superadmin@system.local` via browser
6. **Cleanup** — After Phase A images are deployed: remove service port patches from step 4 (no longer needed)

---

## Decisions

- **Phase A before Phase C**: Frontend code fix is low-risk and doesn't cause downtime. Terraform changes require node group replacement (brief downtime). Do Phase A + B first, then Phase C during a maintenance window.
- **Service port patches (step 4) are temporary**: They bridge the gap until new Docker images with config-driven URLs are deployed. After that, services only need port 80.
- **Variable rename in Terraform**: Renaming `eks_security_group_id` → `eks_node_security_group_id` improves clarity. Both modules use the same variable name so the rename is consistent.
- **docker-compose env var names**: Aligning to `*_BL_SERVICE_URL` to match config.py. Alternative: add `validation_alias` in config.py to accept both, but that adds complexity.

## Scope Boundaries

**Included:**
- All 8 issues from STAGING_TROUBLESHOOTING.md sections 1-8
- Env var naming alignment across docker-compose, K8s manifests, and config.py

**Excluded:**
- TLS/cert-manager setup (production concern)
- Google Maps API key provisioning
- Automated seed data (beyond migration job)
- CI/CD pipeline changes (pipeline already uses `kubectl apply -k`)
- EKS cluster access entry automation (one-time IAM setup)
