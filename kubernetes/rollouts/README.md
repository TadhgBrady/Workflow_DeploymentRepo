# Production Canary Rollouts

Argo Rollouts is installed during the production GitOps bootstrap so production
uses controlled canaries.

The production Kustomize overlay converts the base Deployment resources into
Rollout resources with conservative pod-level canary steps. Production app
workloads run with two replicas to reduce steady-state cost, so the current
pod-level canary uses a simple 50 percent step before moving to 100 percent.
Production Rollouts are wired to stable/canary Services and Istio
trafficRouting, so `setWeight` controls request-level traffic weights through
Istio `VirtualService` routes. External traffic enters through the Istio
ingressgateway and routes to the internal nginx gateway.

Argo Rollouts updates Istio `VirtualService` weights so canary steps send exact
request percentages to stable and canary services. See
`ISTIO_SERVICE_MESH_PLAN.md` for the mesh implementation notes and dashboard
strategy.

Do not canary ExternalSecrets, migration Jobs, or database schema changes.
Migrations must remain backward-compatible with both old and new application
versions.