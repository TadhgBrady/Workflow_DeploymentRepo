#!/bin/sh
set -eu

APP_NAMESPACE="${1:-${PROD_NAMESPACE:-year4-project}}"
ISTIO_NAMESPACE="${ISTIO_NAMESPACE:-istio-system}"
MONITORING_NAMESPACE="${MONITORING_NAMESPACE:-monitoring}"
PROMETHEUS_SERVICE="${PROMETHEUS_SERVICE:-kube-prometheus-stack-prometheus}"
PROMETHEUS_STATEFULSET="${PROMETHEUS_STATEFULSET:-prometheus-kube-prometheus-stack-prometheus}"
MESH_PRIORITY_CLASS="${MESH_PRIORITY_CLASS:-year4-mesh-critical}"
OBS_PRIORITY_CLASS="${OBS_PRIORITY_CLASS:-year4-observability-critical}"

wait_for_service_endpoints() {
  CHECK_NAMESPACE="$1"
  SERVICE_NAME="$2"
  TIMEOUT_SECONDS="$3"
  END_TIME=$(( $(date +%s) + TIMEOUT_SECONDS ))

  echo "Waiting for service endpoints: $SERVICE_NAME.$CHECK_NAMESPACE"
  while [ "$(date +%s)" -lt "$END_TIME" ]; do
    ENDPOINTS="$(kubectl -n "$CHECK_NAMESPACE" get endpoints "$SERVICE_NAME" -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null || true)"
    if [ -n "$ENDPOINTS" ]; then
      return 0
    fi
    sleep 5
  done

  echo "ERROR: service $SERVICE_NAME in namespace $CHECK_NAMESPACE has no ready endpoints" >&2
  kubectl -n "$CHECK_NAMESPACE" get svc,endpoints "$SERVICE_NAME" -o wide >&2 || true
  return 1
}

patch_workload_priority() {
  TARGET_NAMESPACE="$1"
  WORKLOAD_KIND="$2"
  WORKLOAD_NAME="$3"
  PRIORITY_CLASS="$4"

  if kubectl -n "$TARGET_NAMESPACE" get "$WORKLOAD_KIND" "$WORKLOAD_NAME" >/dev/null 2>&1; then
    kubectl -n "$TARGET_NAMESPACE" patch "$WORKLOAD_KIND" "$WORKLOAD_NAME" --type merge \
      -p "{\"spec\":{\"template\":{\"spec\":{\"priorityClassName\":\"$PRIORITY_CLASS\"}}}}}"
  fi
}

echo "============================================================"
echo "  Ensuring production canary dependencies"
echo "============================================================"
echo "App namespace:        $APP_NAMESPACE"
echo "Istio namespace:      $ISTIO_NAMESPACE"
echo "Monitoring namespace: $MONITORING_NAMESPACE"

kubectl apply -f kubernetes/base/priority-classes.yaml

kubectl label namespace "$APP_NAMESPACE" istio-injection=enabled --overwrite

kubectl get mutatingwebhookconfiguration istio-sidecar-injector >/dev/null


echo "--- Hardening istiod scheduling and availability ---"
patch_workload_priority "$ISTIO_NAMESPACE" deployment istiod "$MESH_PRIORITY_CLASS"

if kubectl -n "$ISTIO_NAMESPACE" get hpa istiod >/dev/null 2>&1; then
  kubectl -n "$ISTIO_NAMESPACE" patch hpa istiod --type merge \
    -p '{"spec":{"minReplicas":2,"maxReplicas":5}}'
fi

cat <<EOF | kubectl apply -f -
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: istiod
  namespace: $ISTIO_NAMESPACE
  labels:
    app.kubernetes.io/part-of: year4-project-service-mesh
spec:
  minAvailable: 1
  selector:
    matchLabels:
      app: istiod
EOF

kubectl -n "$ISTIO_NAMESPACE" rollout status deployment/istiod --timeout=300s
wait_for_service_endpoints "$ISTIO_NAMESPACE" istiod 180


echo "--- Hardening Prometheus scheduling and availability ---"
if kubectl -n "$MONITORING_NAMESPACE" get prometheus.monitoring.coreos.com >/dev/null 2>&1; then
  PROMETHEUS_NAMES="$(kubectl -n "$MONITORING_NAMESPACE" get prometheus.monitoring.coreos.com -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')"
  for PROMETHEUS_NAME in $PROMETHEUS_NAMES; do
    kubectl -n "$MONITORING_NAMESPACE" patch prometheus.monitoring.coreos.com "$PROMETHEUS_NAME" --type merge \
      -p "{\"spec\":{\"priorityClassName\":\"$OBS_PRIORITY_CLASS\"}}"
  done
fi

patch_workload_priority "$MONITORING_NAMESPACE" statefulset "$PROMETHEUS_STATEFULSET" "$OBS_PRIORITY_CLASS"
patch_workload_priority "$MONITORING_NAMESPACE" deployment kube-prometheus-stack-operator "$OBS_PRIORITY_CLASS"
patch_workload_priority "$MONITORING_NAMESPACE" deployment monitoring-grafana "$OBS_PRIORITY_CLASS"
patch_workload_priority "$MONITORING_NAMESPACE" deployment monitoring-kube-state-metrics "$OBS_PRIORITY_CLASS"
patch_workload_priority "$MONITORING_NAMESPACE" daemonset monitoring-prometheus-node-exporter "$OBS_PRIORITY_CLASS"

if kubectl -n "$MONITORING_NAMESPACE" get statefulset "$PROMETHEUS_STATEFULSET" >/dev/null 2>&1; then
  kubectl -n "$MONITORING_NAMESPACE" rollout status statefulset/"$PROMETHEUS_STATEFULSET" --timeout=300s
fi
wait_for_service_endpoints "$MONITORING_NAMESPACE" "$PROMETHEUS_SERVICE" 300

echo "SUCCESS: production canary dependencies are ready"