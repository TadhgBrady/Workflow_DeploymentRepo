# Kiali Debug Flow

Kiali is the mesh debugging view, not the general platform dashboard. Use it for service-to-service traffic, mTLS, routing, retries, circuit breaking, and Istio config validation. Use Grafana, Prometheus, Loki, and CloudWatch for metrics, logs, alerts, and longer-term operational evidence.

## Namespace Scope

Kiali should stay focused on namespaces that help debug the mesh:

- `year4-project-staging` for staging application traffic.
- `year4-project` for production application traffic.
- `istio-system` for the Istio control plane and ingress gateway.
- `monitoring` for Prometheus/Grafana resources that scrape and explain mesh metrics.

Other platform namespaces such as `logging`, `cert-manager`, `external-secrets`, and `local-path-storage` are intentionally not the main Kiali view. They often do not have sidecars, so showing them in Kiali creates noisy `Missing Sidecar` entries that are not useful for application flow debugging.

## Recommended Kiali Views

1. Open `Traffic Graph`.
2. Select only the app namespace you are debugging, such as `year4-project-staging`.
3. Use `Graph Type: App`.
4. Enable service nodes.
5. Use `Box By: App` to show the architecture layers:
   - `gateway`
   - `business-layer`
   - `database-access-layer`
   - `database-layer`
6. Turn on security badges to confirm mTLS edges.

Use `Applications` as an inventory and health page, not as the main architecture diagram. The layer view belongs in the graph.

## Business Layer Split

The business layer is intentionally one architecture box, but it is still split into separate services:

- `auth-service`
- `admin-bl-service`
- `user-bl-service`
- `customer-bl-service`
- `job-bl-service`
- `maps-access-service`
- `notification-service`

Use `Graph Type: App` when you want the clean layered architecture view. Kiali collapses workloads that share the same `app` label, so this view shows a single `business-layer` app node plus the individual service nodes.

Use `Graph Type: Workload` when you need to debug a real request path service-by-service. This shows the separate business workloads inside the same `business-layer` box.

## Debug Workflows

### Request Fails Or Times Out

1. Start in `Traffic Graph` for the app namespace.
2. Follow the red or degraded edge from `gateway` through business and database-access layers.
3. Open the affected edge or service and check request rate, error rate, response time, and mTLS status.
4. Open the destination `Service` to inspect VirtualService and DestinationRule routing.
5. Use Grafana or Loki for detailed latency, error, and log evidence.

### Missing Or Unexpected Traffic

1. Confirm traffic exists in `Traffic Graph` for the selected time range.
2. Check whether the source and destination have sidecars.
3. Verify the destination Service selector and pod labels.
4. Check `Istio Config` validation for VirtualService, DestinationRule, PeerAuthentication, and AuthorizationPolicy problems.

### mTLS Or Authorization Failure

1. Confirm the namespace PeerAuthentication is `STRICT`.
2. Check the Kiali graph edge security badge.
3. Inspect AuthorizationPolicy for source namespace, principal, and destination selector.
4. Verify DestinationRule TLS mode is `ISTIO_MUTUAL` for internal mesh services.

### External API Calls

External calls should appear through configured ServiceEntries when the host is known. Current mapped external APIs are:

- `maps.googleapis.com`
- `api.twilio.com`

Unmapped external traffic can show up as passthrough traffic. Add a ServiceEntry only when the external host is intentional and known.
