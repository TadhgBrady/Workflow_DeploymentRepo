# Istio Service Mesh and Progressive Delivery Plan

## Decision

Add Istio as the production service mesh so Argo Rollouts can move from
pod-level canary behavior to request-level traffic shifting. Do not remove
Grafana, Fluent Bit, Prometheus, CloudWatch, Argo CD, or Argo Rollouts.

Kiali should be added as the mesh topology and traffic-flow dashboard. It should
not replace Grafana. Grafana remains the primary time-series dashboard for
metrics, SLOs, k6 evidence, rollout analysis, and long-term trend views.

## Implemented State

The mesh foundation is now wired into the deployment repository:

- `scripts/deployment/bootstrap-istio.sh` installs Istio base, istiod, the Istio
  ingress gateway, and Kiali with Helm.
- `install-service-mesh-staging` runs after staging observability and before the
  staging app deploy.
- `install-service-mesh-production` runs after production observability and
  before Argo CD/Rollouts bootstrap.
- `kubernetes/service-mesh/staging` and `kubernetes/service-mesh/production`
  define namespace-scoped `PeerAuthentication`, `Telemetry`, `Gateway`,
  `VirtualService`, `PodMonitor`, and `ServiceMonitor` resources.
- The app nginx gateway service is internal `ClusterIP`; external traffic enters
  through `istio-ingressgateway` and routes to `nginx-gateway` with Istio.
- Production Rollouts define stable/canary Services and Istio traffic routing so
  `setWeight` controls request-level traffic weights, not only pod counts.
- Live Grafana Operations Hub and Istio Mesh dashboards are applied as
  `grafana_dashboard` ConfigMaps by the observability jobs.
- Baseline `DestinationRule` resources make sidecar-to-sidecar application
  traffic use `ISTIO_MUTUAL`; audit-mode `AuthorizationPolicy` resources are in
  place as non-breaking policy scaffolding.
- Migration and k6 Jobs opt out of sidecar injection so one-shot Jobs can finish.

This implements the staging and production mesh foundation plus production
request-level canary routing. Prometheus-backed automated analysis, `STRICT`
mTLS, and enforcing authorization policies remain the next hardening phase.

## Why Istio Helps This Project

The current production Rollout implementation uses Argo Rollouts with canary
steps. Because traffic still flows through standard Kubernetes Services, the
traffic split is approximate and based on pod counts.

Istio adds an explicit traffic-control plane:

1. Argo CD syncs the production overlay from Git.
2. Argo Rollouts creates stable and canary ReplicaSets.
3. Istio `VirtualService` routes exact percentages of HTTP traffic to stable or
   canary services.
4. Prometheus scrapes Istio metrics such as request volume, 5xx rate, and p95
   latency.
5. Argo Rollouts `AnalysisTemplate` decides whether to continue, pause, or abort.

This gives a clear industry-level progressive delivery story: GitOps plus exact
traffic-weighted canaries plus metric-based rollback.

## Dashboard Strategy

### Keep Grafana

Grafana should stay because it is the best place for:

- Prometheus metrics dashboards.
- k6 load-test dashboards and release evidence.
- Cluster/node/pod resource dashboards.
- Fluent Bit health dashboards.
- SLO panels such as availability, error rate, latency, and saturation.
- Argo Rollouts analysis metric panels.

Removing Grafana would make the observability stack weaker. Kiali does not
replace general Prometheus dashboards.

### Add Kiali

Kiali should be added for:

- Service graph and live traffic topology.
- Mesh health checks.
- mTLS visibility.
- Istio `VirtualService`, `DestinationRule`, and Gateway validation.
- Per-service request rate, error rate, and latency views.

Kiali should be treated as a mesh operations dashboard, not the single source of
truth for all monitoring.

### Keep Argo Dashboards Separate

Argo CD provides a UI for:

- Application sync state.
- Git revision deployed.
- Resource health.
- Drift detection.

Argo Rollouts provides rollout-focused views through the kubectl plugin and can
run a local dashboard for rollout debugging. It should be used for deployment
state, while Grafana should show operational metrics and release evidence.

### Keep Fluent Bit and CloudWatch

Istio does not replace logs. Fluent Bit should continue shipping application,
container, migration, and sidecar logs to CloudWatch. Istio will add Envoy
sidecar logs, so Fluent Bit filters may need tuning to avoid unnecessary log
costs.

## Target Production Architecture

```text
GitLab pipeline
  -> deployment repo image pins
  -> Argo CD production Application
  -> Argo Rollouts
  -> Istio VirtualService traffic weights
  -> stable/canary services
  -> application pods with Envoy sidecars

Observability:
  Prometheus -> Grafana dashboards and Argo AnalysisTemplates
  Istio telemetry -> Prometheus -> Grafana/Kiali
  Fluent Bit -> CloudWatch Logs
  Argo CD UI -> GitOps state
  Argo Rollouts plugin/dashboard -> rollout state
```

## Implementation Phases

### Phase 1: Mesh Foundation in Staging - Implemented

Install Istio in staging first, before production.

Required changes:

- Add an `install-istio-staging` pipeline job after staging cluster readiness and
  before staging app deployment.
- Install with Helm charts:
  - `istio/base`
  - `istio/istiod`
  - `istio/gateway`
  - `kiali-server/kiali-server`
- Label only the application namespace for injection:
  - `istio-injection=enabled`
- Do not inject sidecars into `kube-system`, `argocd`, `monitoring`,
  `external-secrets`, `cert-manager`, or logging namespaces.
- Start mTLS in `PERMISSIVE` mode to avoid breaking current service calls.
- Confirm all staging smoke tests, k6 tests, and Playwright tests still pass.

Acceptance criteria:

- All app pods in staging have an Envoy sidecar.
- Kiali shows the application service graph.
- Prometheus receives Istio request metrics.
- Existing Fluent Bit logs still reach CloudWatch.
- Staging release gates still pass.

### Phase 2: Production Mesh Bootstrap - Implemented

Add production mesh install after production add-ons and observability, but
before Argo CD syncs the application.

Recommended pipeline order:

1. `wait-production-ready`
2. `install-addons-production`
3. `install-observability-production`
4. `install-service-mesh-production`
5. `install-argocd-production`
6. `deploy-production`
7. `smoke-tests-production`

Required changes:

- Add `scripts/deployment/bootstrap-istio-production.sh`.
- Add `kubernetes/service-mesh/production/` manifests for:
  - `PeerAuthentication` in `PERMISSIVE` mode.
  - `Gateway` for public HTTP entry.
  - initial `VirtualService` definitions.
  - Kiali access policy or port-forward instructions.
- Update the local pipeline validator to ensure service mesh bootstrap exists
  before production Argo CD sync.

Acceptance criteria:

- Production app namespace has sidecar injection enabled before Argo CD sync.
- Istio CRDs exist before Rollout traffic routing resources are applied.
- Kiali is installed but not publicly exposed without authentication.
- Production smoke tests pass through the Istio ingress path.

### Phase 3: Argo Rollouts Traffic Routing - Implemented

Move from pod-level canary to Istio request-level canary.

Required changes:

- For every production Rollout, define:
  - `stableService`
  - `canaryService`
  - `trafficRouting.istio.virtualService`
- Add generated or Kustomize-managed stable/canary Service resources for each
  app service.
- Add Istio `VirtualService` and `DestinationRule` resources for service traffic.
- Do not wire traffic-routing Rollout patches until the matching stable services,
  canary services, and Istio `VirtualService` routes exist. A Rollout that
  references missing routing resources will fail during rollout control.
- Keep staging traffic routing separate from production. Staging currently
  renders standard Deployments, so Rollout traffic-routing patches should not be
  included there unless staging is intentionally converted to Rollouts too.
- Keep conservative canary steps at first:
  - 5 percent for 2 minutes
  - 25 percent for 5 minutes
  - 50 percent for 5 minutes
  - 75 percent for 5 minutes
  - 100 percent

Acceptance criteria:

- Argo Rollouts updates Istio route weights during production canary.
- Kiali shows traffic moving between stable and canary versions.
- Existing service DNS names continue working for application code.
- Rollout abort restores traffic to the stable service.

### Phase 4: Metric-Based Rollback

Add Argo Rollouts `AnalysisTemplate` resources backed by Prometheus.

Recommended first metrics:

- 5xx rate below 1 percent during each canary step.
- p95 latency below a defined service-specific threshold.
- pod restart increase below a small threshold.
- ready pod count remains healthy.

Example Prometheus sources:

- `istio_requests_total`
- `istio_request_duration_milliseconds_bucket`
- `kube_pod_container_status_restarts_total`
- `kube_pod_status_ready`

Acceptance criteria:

- A bad canary can be aborted automatically by metrics.
- Analysis results are visible in Argo Rollouts status.
- Grafana has a rollout dashboard showing the same metrics used by the gate.

### Phase 4b: Policy Hardening - Next

The current policy baseline is intentionally safe for the existing release path:
`PeerAuthentication` stays `PERMISSIVE`, sidecar clients use `ISTIO_MUTUAL`, and
authorization policy starts in `AUDIT` mode. This lets staging collect Kiali and
Grafana evidence before the mesh begins rejecting traffic.

Recommended hardening order:

- Switch staging `PeerAuthentication` to `STRICT` first.
- Confirm smoke, k6, and Playwright pass through the Istio ingressgateway.
- Add explicit `ALLOW` policies for ingressgateway to nginx-gateway and known
  service-to-service paths.
- Add namespace default-deny only after the allow list is proven.
- Promote the same policy sequence to production after one clean staging gate.

### Phase 5: Production Hardening

After traffic routing and analysis are stable, harden the mesh.

Recommended changes:

- Move mTLS from `PERMISSIVE` to `STRICT` for the app namespace after staging
  proves all app traffic is mesh-compatible.
- Change `AuthorizationPolicy` from audit scaffolding to service-by-service
  enforced allow rules.
- Add outbound traffic policy for external calls, especially maps/email APIs.
- Add resource requests/limits for Envoy sidecars.
- Tune Fluent Bit to reduce noisy Envoy access logs if CloudWatch cost rises.
- Add dashboards for mesh saturation and sidecar resource use.

## Dashboard Ownership Matrix

| Need | Tool |
| --- | --- |
| Git revision deployed | Argo CD UI |
| App sync/drift/resource health | Argo CD UI |
| Rollout step and canary status | Argo Rollouts plugin/dashboard |
| Traffic graph and mTLS status | Kiali |
| SLOs, latency, errors, resource trends | Grafana |
| k6 and release evidence | Grafana |
| Application/container logs | CloudWatch via Fluent Bit |
| Log investigation | CloudWatch Logs Insights |

## Cost and Resource Impact

Istio itself is open source, but it increases cluster resource usage.

Expected added costs:

- Envoy sidecar CPU and memory on every app pod.
- Istiod, gateway, and Kiali control-plane pods.
- More Prometheus metrics volume from Istio telemetry.
- More Fluent Bit/CloudWatch log volume if Envoy logs are not filtered.
- Possible need for an additional EKS node in staging or production.
- Production app workloads now use two replicas to reduce steady-state cost.
  This helps offset future sidecar overhead, but it also means one failed pod is
  a larger capacity hit than it was with three replicas.

Cost controls:

- Inject sidecars only in the application namespace.
- Keep Kiali internal and access it with port-forward or authenticated ingress.
- Limit Envoy access logs in production unless debugging.
- Keep Prometheus retention appropriate for the project environment.
- Use staging to estimate sidecar overhead before enabling production.
- Keep the two-replica production canary at 50 percent then 100 percent until
  Prometheus-backed analysis and rollback thresholds are tuned.

## Risks and Mitigations

| Risk | Mitigation |
| --- | --- |
| Mesh breaks service-to-service calls | Start in staging, use `PERMISSIVE` mTLS first |
| Sidecars increase resource pressure | Add resource requests/limits and monitor node headroom |
| Dashboard sprawl | Define ownership: Grafana for metrics, Kiali for mesh, Argo for deployment |
| CloudWatch log cost rises | Filter noisy Envoy logs in Fluent Bit |
| Rollout routing misconfiguration | Validate VirtualServices locally and verify traffic in Kiali during staging/prod gates |
| Too much complexity for final delivery | Implement phases 1-3, document phases 4-5 as hardening if time runs out |

## Recommendation

The best implementation path is not to replace Grafana with Kiali. Keep Grafana
as the central observability dashboard, add Kiali for mesh-specific topology, and
use Argo CD/Rollouts dashboards for deployment state.

Istio, Kiali, and production Rollouts traffic routing are now wired. The next
step is automated Prometheus-backed analysis once exact traffic shifting is
proven in the staging and production gates.