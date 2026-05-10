#!/bin/sh
set -eu

ENVIRONMENT="${1:?usage: bootstrap-istio.sh <staging|production> <app-namespace>}"
APP_NAMESPACE="${2:?usage: bootstrap-istio.sh <staging|production> <app-namespace>}"

ISTIO_NAMESPACE="${ISTIO_NAMESPACE:-istio-system}"
ISTIO_VERSION="${ISTIO_VERSION:-1.23.2}"
ISTIO_GATEWAY_RELEASE="${ISTIO_GATEWAY_RELEASE:-istio-ingressgateway}"
KIALI_RELEASE="${KIALI_RELEASE:-kiali}"
MONITORING_NAMESPACE="${MONITORING_NAMESPACE:-monitoring}"
PROMETHEUS_SERVICE="${PROMETHEUS_SERVICE:-kube-prometheus-stack-prometheus}"
MESH_MANIFEST_DIR="kubernetes/service-mesh/$ENVIRONMENT"

case "$ENVIRONMENT" in
  staging|production) ;;
  *)
    echo "ERROR: environment must be staging or production, got: $ENVIRONMENT"
    exit 1
    ;;
esac

if [ ! -d "$MESH_MANIFEST_DIR" ]; then
  echo "ERROR: service mesh manifest directory not found: $MESH_MANIFEST_DIR"
  exit 1
fi

retry_cmd() {
  ATTEMPTS="$1"
  DELAY="$2"
  shift 2
  TRY=1
  until "$@"; do
    if [ "$TRY" -ge "$ATTEMPTS" ]; then
      echo "ERROR: command failed after ${ATTEMPTS} attempts: $*"
      return 1
    fi
    echo "WARN: command failed (attempt ${TRY}/${ATTEMPTS}): $*"
    echo "      retrying in ${DELAY}s..."
    sleep "$DELAY"
    TRY=$((TRY + 1))
  done
}

clear_pending_helm_release() {
  RELEASE="$1"
  NAMESPACE="$2"
  STATUS=$(helm status "$RELEASE" -n "$NAMESPACE" -o json 2>/dev/null | grep -o '"status":"[^"]*"' | head -1 | cut -d'"' -f4 || true)
  case "$STATUS" in
    pending-install|pending-upgrade|pending-rollback|failed)
      echo "WARN: Helm release $RELEASE in $NAMESPACE is $STATUS; clearing stale state"
      helm rollback "$RELEASE" 0 -n "$NAMESPACE" 2>/dev/null || true
      helm uninstall "$RELEASE" -n "$NAMESPACE" 2>/dev/null || true
      sleep 10
      ;;
  esac
}

echo "============================================================"
echo "  Bootstrapping Istio service mesh for $ENVIRONMENT"
echo "============================================================"
echo "Istio namespace:      $ISTIO_NAMESPACE"
echo "App namespace:        $APP_NAMESPACE"
echo "Istio version:        $ISTIO_VERSION"
echo "Mesh manifests:       $MESH_MANIFEST_DIR"
echo "Prometheus service:   $PROMETHEUS_SERVICE.$MONITORING_NAMESPACE"

kubectl create namespace "$ISTIO_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace "$APP_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

retry_cmd 4 10 helm repo add istio https://istio-release.storage.googleapis.com/charts
retry_cmd 4 10 helm repo add kiali-server https://kiali.org/helm-charts
retry_cmd 4 10 helm repo update istio
retry_cmd 4 10 helm repo update kiali-server

clear_pending_helm_release istio-base "$ISTIO_NAMESPACE"
retry_cmd 4 20 helm upgrade --install istio-base istio/base \
  --version "$ISTIO_VERSION" \
  --namespace "$ISTIO_NAMESPACE" --create-namespace \
  --wait --timeout 300s

kubectl wait --for=condition=Established crd/peerauthentications.security.istio.io --timeout=180s
kubectl wait --for=condition=Established crd/telemetries.telemetry.istio.io --timeout=180s
kubectl wait --for=condition=Established crd/virtualservices.networking.istio.io --timeout=180s
kubectl wait --for=condition=Established crd/gateways.networking.istio.io --timeout=180s

clear_pending_helm_release istiod "$ISTIO_NAMESPACE"
retry_cmd 4 30 helm upgrade --install istiod istio/istiod \
  --version "$ISTIO_VERSION" \
  --namespace "$ISTIO_NAMESPACE" \
  -f kubernetes/service-mesh/istiod-values.yaml \
  --wait --timeout 600s

clear_pending_helm_release "$ISTIO_GATEWAY_RELEASE" "$ISTIO_NAMESPACE"
retry_cmd 4 30 helm upgrade --install "$ISTIO_GATEWAY_RELEASE" istio/gateway \
  --version "$ISTIO_VERSION" \
  --namespace "$ISTIO_NAMESPACE" \
  -f kubernetes/service-mesh/gateway-values.yaml \
  --skip-schema-validation \
  --wait --timeout 600s

clear_pending_helm_release "$KIALI_RELEASE" "$ISTIO_NAMESPACE"
retry_cmd 4 30 helm upgrade --install "$KIALI_RELEASE" kiali-server/kiali-server \
  --namespace "$ISTIO_NAMESPACE" \
  -f kubernetes/service-mesh/kiali-values.yaml \
  --set "external_services.prometheus.url=http://$PROMETHEUS_SERVICE.$MONITORING_NAMESPACE:9090" \
  --wait --timeout 600s

kubectl label namespace "$APP_NAMESPACE" istio-injection=enabled --overwrite
kubectl label namespace "$APP_NAMESPACE" app.kubernetes.io/part-of=year4-project --overwrite
kubectl annotate namespace "$APP_NAMESPACE" mesh.year4-project/environment="$ENVIRONMENT" --overwrite

kubectl apply -k "$MESH_MANIFEST_DIR"

kubectl rollout status deployment/istiod -n "$ISTIO_NAMESPACE" --timeout=300s
kubectl rollout status deployment/"$ISTIO_GATEWAY_RELEASE" -n "$ISTIO_NAMESPACE" --timeout=300s
kubectl rollout status deployment/"$KIALI_RELEASE" -n "$ISTIO_NAMESPACE" --timeout=300s

if kubectl get deployment -n "$APP_NAMESPACE" >/dev/null 2>&1; then
  echo "Restarting existing app deployments so Envoy sidecars are injected..."
  kubectl rollout restart deployment -n "$APP_NAMESPACE"
fi

echo "Istio resources:"
kubectl get pods,svc -n "$ISTIO_NAMESPACE" -o wide
kubectl get peerauthentication,telemetry,gateway,virtualservice -n "$APP_NAMESPACE" || true
kubectl get podmonitor,servicemonitor -n "$MONITORING_NAMESPACE" | grep -E 'istio|NAME' || true

echo "SUCCESS: Istio service mesh installed for $ENVIRONMENT"