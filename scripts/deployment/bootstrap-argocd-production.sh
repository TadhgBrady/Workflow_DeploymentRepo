#!/bin/sh
set -eu

ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-argocd}"
ARGO_ROLLOUTS_NAMESPACE="${ARGO_ROLLOUTS_NAMESPACE:-argo-rollouts}"
PROD_NAMESPACE="${PROD_NAMESPACE:-year4-project}"
ARGOCD_CHART_VERSION="${ARGOCD_CHART_VERSION:-7.6.12}"
ARGO_ROLLOUTS_CHART_VERSION="${ARGO_ROLLOUTS_CHART_VERSION:-2.37.6}"
ARGOCD_REPO_URL="${ARGOCD_REPO_URL:-${CI_PROJECT_URL:-https://gitlab.comp.dkit.ie/finalproject/Prototypes/yr4-projectdeploymentrepo}.git}"
export ARGOCD_REQUIRE_PERSISTENT_REPO_CREDS="${ARGOCD_REQUIRE_PERSISTENT_REPO_CREDS:-true}"

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
    sleep "$DELAY"
    TRY=$((TRY + 1))
  done
}

echo "Bootstrapping Argo CD production GitOps controllers"
kubectl create namespace "$ARGOCD_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace "$ARGO_ROLLOUTS_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace "$PROD_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

retry_cmd 4 10 helm repo add argo https://argoproj.github.io/argo-helm
retry_cmd 4 10 helm repo update argo

helm upgrade --install argocd argo/argo-cd \
  --version "$ARGOCD_CHART_VERSION" \
  --namespace "$ARGOCD_NAMESPACE" \
  --create-namespace \
  --set configs.params."server\.insecure"=true \
  --set server.service.type=ClusterIP \
  --wait --timeout 600s

helm upgrade --install argo-rollouts argo/argo-rollouts \
  --version "$ARGO_ROLLOUTS_CHART_VERSION" \
  --namespace "$ARGO_ROLLOUTS_NAMESPACE" \
  --create-namespace \
  --wait --timeout 300s

sh scripts/deployment/ensure-argocd-repo-credentials.sh

kubectl apply -k kubernetes/argocd

kubectl rollout status deployment/argocd-repo-server -n "$ARGOCD_NAMESPACE" --timeout=300s
kubectl rollout status statefulset/argocd-application-controller -n "$ARGOCD_NAMESPACE" --timeout=300s
kubectl rollout status deployment/argo-rollouts -n "$ARGO_ROLLOUTS_NAMESPACE" --timeout=300s

echo "Argo CD production bootstrap complete"