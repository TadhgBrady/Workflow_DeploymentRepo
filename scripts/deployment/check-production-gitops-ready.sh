#!/bin/sh
set -eu

ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-argocd}"
ARGO_ROLLOUTS_NAMESPACE="${ARGO_ROLLOUTS_NAMESPACE:-argo-rollouts}"
ARGOCD_REPO_SECRET="${ARGOCD_REPO_SECRET:-year4-project-deployment-repo}"
ARGOCD_APPS="${ARGOCD_APPS:-year4-project-service-mesh-production year4-project-production}"
PROD_NAMESPACE="${PROD_NAMESPACE:-year4-project}"
ISTIO_NAMESPACE="${ISTIO_NAMESPACE:-istio-system}"
ISTIO_INGRESS_SERVICE="${ISTIO_INGRESS_SERVICE:-istio-ingressgateway}"
EXTERNAL_SECRET_STORE="${EXTERNAL_SECRET_STORE:-aws-secrets-manager}"

MISSING=0

check() {
  MESSAGE="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    echo "[OK] $MESSAGE"
  else
    echo "[ERROR] $MESSAGE"
    MISSING=1
  fi
}

check_rollout() {
  MESSAGE="$1"
  shift
  if "$@"; then
    echo "[OK] $MESSAGE"
  else
    echo "[ERROR] $MESSAGE"
    MISSING=1
  fi
}

echo "==============================================================="
echo "  Checking production GitOps foundation"
echo "==============================================================="

check "namespace/$PROD_NAMESPACE exists" kubectl get namespace "$PROD_NAMESPACE"
check "namespace/$ARGOCD_NAMESPACE exists" kubectl get namespace "$ARGOCD_NAMESPACE"
check "namespace/$ARGO_ROLLOUTS_NAMESPACE exists" kubectl get namespace "$ARGO_ROLLOUTS_NAMESPACE"
check "namespace/$ISTIO_NAMESPACE exists" kubectl get namespace "$ISTIO_NAMESPACE"

check "CRD applications.argoproj.io exists" kubectl get crd applications.argoproj.io
check "CRD rollouts.argoproj.io exists" kubectl get crd rollouts.argoproj.io
check "CRD externalsecrets.external-secrets.io exists" kubectl get crd externalsecrets.external-secrets.io
check "CRD certificates.cert-manager.io exists" kubectl get crd certificates.cert-manager.io

check_rollout "Argo CD repo server is available" kubectl rollout status deployment/argocd-repo-server -n "$ARGOCD_NAMESPACE" --timeout=60s
check_rollout "Argo CD application controller is ready" kubectl rollout status statefulset/argocd-application-controller -n "$ARGOCD_NAMESPACE" --timeout=60s
check_rollout "Argo Rollouts controller is available" kubectl rollout status deployment/argo-rollouts -n "$ARGO_ROLLOUTS_NAMESPACE" --timeout=60s
check_rollout "External Secrets Operator is available" kubectl rollout status deployment/external-secrets -n external-secrets --timeout=60s
check_rollout "cert-manager is available" kubectl rollout status deployment/cert-manager -n cert-manager --timeout=60s

check "ClusterSecretStore/$EXTERNAL_SECRET_STORE exists" kubectl get clustersecretstore "$EXTERNAL_SECRET_STORE"
if kubectl get clustersecretstore "$EXTERNAL_SECRET_STORE" >/dev/null 2>&1; then
  if kubectl wait --for=condition=Ready=True "clustersecretstore/$EXTERNAL_SECRET_STORE" --timeout=60s >/dev/null 2>&1; then
    echo "[OK] ClusterSecretStore/$EXTERNAL_SECRET_STORE is ready"
  else
    echo "[ERROR] ClusterSecretStore/$EXTERNAL_SECRET_STORE is not ready"
    MISSING=1
  fi
fi

check "service/$ISTIO_INGRESS_SERVICE exists in $ISTIO_NAMESPACE" kubectl -n "$ISTIO_NAMESPACE" get service "$ISTIO_INGRESS_SERVICE"

export ARGOCD_REQUIRE_PERSISTENT_REPO_CREDS="${ARGOCD_REQUIRE_PERSISTENT_REPO_CREDS:-true}"
if ! sh scripts/deployment/ensure-argocd-repo-credentials.sh; then
  echo "[ERROR] Persistent Argo CD repository credentials are not available"
  MISSING=1
fi
check "Argo CD repository secret/$ARGOCD_REPO_SECRET exists" kubectl -n "$ARGOCD_NAMESPACE" get secret "$ARGOCD_REPO_SECRET"

for ARGOCD_APP in $ARGOCD_APPS; do
  check "Argo CD application/$ARGOCD_APP exists" kubectl -n "$ARGOCD_NAMESPACE" get application "$ARGOCD_APP"
done

if [ "$MISSING" -ne 0 ]; then
  echo ""
  echo "Production GitOps foundation is incomplete."
  echo "Rerun this pipeline with PIPELINE_MODE=production-bootstrap or PRODUCTION_BOOTSTRAP=true."
  exit 1
fi

echo "[OK] Production GitOps foundation is ready"