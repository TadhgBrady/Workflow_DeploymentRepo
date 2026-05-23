# Istio Service Mesh And Canary Plan

This plan documents the target state for production canaries and service mesh
operations.

## GitOps Ownership

- Argo CD owns production workload manifests through `year4-project-production`.
- Argo CD owns production mesh manifests through `year4-project-service-mesh-production`.
- The mesh Application ignores Istio `VirtualService` route weights because Argo
  Rollouts mutates those weights during active canaries.
- Bootstrap scripts install controllers and CRDs; steady-state manifests should
  be reconciled from Git.

## Canary Rollouts

- Production canaries use Istio request-level traffic routing, not pod-only
  traffic approximation.
- Rollout steps are 5, 10, 25, 50, and 100 percent request weight.
- Each Rollout references the shared `istio-canary-analysis` AnalysisTemplate.
- Prometheus abort gates cover request volume, 5xx rate, canary-vs-stable error
  regression, and p95 latency.
- Synthetic traffic from k6 or smoke workflows should be used during quiet
  canaries so analysis has enough samples.

## Security Target State

- Application namespaces now enforce STRICT mTLS.
- AuthorizationPolicy now uses an enforced default-deny baseline with explicit
  ALLOW rules for Istio ingress, same-namespace mesh workloads, and monitoring
  scrapes.
- Add method and path restrictions where API contracts are stable enough.
- Keep migration and k6 Jobs compatible by disabling sidecar injection or adding
  explicit policy exceptions.

## Resilience Target State

- Add per-route VirtualService timeouts and bounded retries.
- Split the wildcard DestinationRule into service-specific policies where needed.
- Use DestinationRule connection pools, pending request limits, and outlier
  detection as circuit breakers for auth, nginx, job/customer workflows, and
  DB-access services.
- Test circuit breakers and retry behavior under controlled staging failures
  before enabling stricter production settings.

## Observability Strategy

- Grafana is the primary operator view for SLOs, canary health, release
  evidence, capacity, policy-deny metrics, circuit-breaker events, and links to
  logs and traces.
- Kiali is the primary mesh inspection view for topology, mTLS edge validation,
  Istio config validation, policy troubleshooting, and service-to-service flow
  debugging.
- Prometheus, CloudWatch/Loki, and tracing backends remain data sources behind
  Grafana and Kiali.

## Verification Gates

- Render and validate production overlays and service mesh kustomizations.
- Confirm Argo CD syncs mesh before workloads and does not revert active canary
  weights.
- Confirm Rollouts move VirtualService weights through the staged canary steps.
- Force a bad metric in staging and prove Argo Rollouts aborts automatically.
- Run `istioctl analyze`, `istioctl authn tls-check`, Kiali mTLS validation,
  k6, and Playwright after policy changes to prove all intended traffic still
  flows and policy-deny signals are understood.