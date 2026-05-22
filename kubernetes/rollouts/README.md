# Production Canary Rollouts

Argo Rollouts is installed during the production GitOps bootstrap so production
uses controlled canaries.

The production Kustomize overlay converts the base Deployment resources into
Rollout resources with Istio request-level canary steps. Production workloads
run with two replicas for cost-aware HA, while the canary pod is held at one
replica and Istio owns the request split. The rollout moves through 5, 10, 25,
50, and 100 percent request weights before promotion.

Production Rollouts are wired to stable/canary Services and Istio
trafficRouting, so `setWeight` controls exact request weights through Istio
`VirtualService` routes. External traffic enters through the Istio
ingressgateway and routes to the internal nginx gateway.

Argo Rollouts updates Istio `VirtualService` weights so canary steps send exact
request percentages to stable and canary services. Each Rollout also references
the shared `istio-canary-analysis` AnalysisTemplate, which queries Prometheus
for canary request volume, canary 5xx rate, canary-vs-stable error regression,
and p95 latency. Failed analysis aborts the rollout and returns traffic to the
stable service.

The production service mesh manifests are also managed by Argo CD through the
`year4-project-service-mesh-production` Application. That Application ignores
Istio `VirtualService` route weight drift so Argo CD does not fight Argo
Rollouts while a canary is active.

See `ISTIO_SERVICE_MESH_PLAN.md` for the mesh implementation notes, security
target state, and dashboard strategy.

Do not canary ExternalSecrets, migration Jobs, or database schema changes.
Migrations must remain backward-compatible with both old and new application
versions.