# Production Canary Rollouts

Argo Rollouts is installed during the production GitOps bootstrap so production
uses controlled canaries.

The production Kustomize overlay converts the base Deployment resources into
Rollout resources with conservative pod-level canary steps. Production app
workloads run with two replicas to reduce steady-state cost, so the current
pod-level canary uses a simple 50 percent step before moving to 100 percent.
Because the cluster currently exposes the app through the existing Kubernetes
Services rather than an Argo Rollouts traffic router, `setWeight` is approximated
by canary/stable pod counts instead of precise request-level traffic weighting.

The planned industry-level upgrade is Istio traffic routing. In that model,
Argo Rollouts updates Istio `VirtualService` weights so canary steps send exact
request percentages to stable and canary services. See
`ISTIO_SERVICE_MESH_PLAN.md` for the implementation plan and dashboard strategy.

Do not canary ExternalSecrets, migration Jobs, or database schema changes.
Migrations must remain backward-compatible with both old and new application
versions.