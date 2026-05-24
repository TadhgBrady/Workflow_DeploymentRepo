# Local Production Rehearsal

Use this to rehearse the production GitOps path locally before touching AWS. The script resets a kind cluster to one exact old image version, then deploys one exact new image version through Argo CD and Argo Rollouts.

## What It Uses

The rehearsal intentionally uses the production deployment shape:

- Argo CD Applications
- Argo Rollouts canary resources
- Istio service mesh and traffic routing
- kube-prometheus-stack for canary analysis metrics
- production overlay via `production-local-rehearsal`
- exact image pins generated into Git rehearsal branches

AWS-only services are replaced locally:

- RDS is replaced by the local PostgreSQL container
- ElastiCache is replaced by the local Redis container
- Secrets Manager and External Secrets are replaced by local Kubernetes Secrets
- EKS and AWS load balancers are replaced by kind and port-forwarding

## Prerequisites

Install these locally:

```text
docker
kind
kubectl
helm
git
argocd
kubectl argo rollouts plugin
```

The default full run requires `argocd` and `kubectl argo rollouts` because production uses those tools. Use `-AllowCliFallback` only when you are doing a lower-fidelity local check.

## Run It

From `yr4-projectdeploymentrepo`:

```powershell
.\local\run-full-production-rehearsal.ps1 -OldVersion <OLD_SHA> -NewVersion <NEW_SHA>
```

Example:

```powershell
.\local\run-full-production-rehearsal.ps1 -OldVersion 097716b7 -NewVersion b0e4e6b
```

The script will:

1. Start local PostgreSQL, Redis, and Mailpit.
2. Create or reuse the `kind-local-dev` cluster.
3. Pull and load `<OLD_SHA>` images from the registry.
4. Build local development images, tag them as `<NEW_SHA>`, and load them into kind.
5. Push two GitOps rehearsal branches:
   - `local-production-rehearsal/old-<OLD_SHA>`
   - `local-production-rehearsal/new-<NEW_SHA>`
6. Install local observability, Istio, Argo CD, and Argo Rollouts.
7. Point Argo CD at the old branch and wait for the old version to become healthy.
8. Point Argo CD at the new branch and wait for the canary rollout to become healthy.
9. Smoke-test the app through the Istio ingress gateway.

## Dry Run

Use dry run first to confirm the exact reset and deployment plan:

```powershell
.\local\run-full-production-rehearsal.ps1 -OldVersion <OLD_SHA> -NewVersion <NEW_SHA> -DryRun
```

## Useful Commands

```powershell
kubectl get applications -n argocd
kubectl get rollouts -n year4-project
kubectl get pods -n year4-project
kubectl -n istio-system port-forward svc/istio-ingressgateway 18080:80
```

Then open:

```text
http://localhost:18080
```
