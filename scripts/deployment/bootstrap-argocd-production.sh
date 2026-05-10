#!/bin/sh
set -eu

ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-argocd}"
ARGO_ROLLOUTS_NAMESPACE="${ARGO_ROLLOUTS_NAMESPACE:-argo-rollouts}"
PROD_NAMESPACE="${PROD_NAMESPACE:-year4-project}"
ARGOCD_CHART_VERSION="${ARGOCD_CHART_VERSION:-7.6.12}"
ARGO_ROLLOUTS_CHART_VERSION="${ARGO_ROLLOUTS_CHART_VERSION:-2.37.6}"
ARGOCD_REPO_URL="${ARGOCD_REPO_URL:-${CI_PROJECT_URL:-https://gitlab.comp.dkit.ie/finalproject/Prototypes/yr4-projectdeploymentrepo}.git}"

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

if [ -n "${ARGOCD_REPO_USERNAME:-}" ] && [ -n "${ARGOCD_REPO_PASSWORD:-}" ]; then
  kubectl -n "$ARGOCD_NAMESPACE" create secret generic year4-project-deployment-repo \
    --from-literal=type=git \
    --from-literal=url="$ARGOCD_REPO_URL" \
    --from-literal=username="$ARGOCD_REPO_USERNAME" \
    --from-literal=password="$ARGOCD_REPO_PASSWORD" \
    --dry-run=client -o yaml | kubectl apply -f -
  kubectl -n "$ARGOCD_NAMESPACE" label secret year4-project-deployment-repo \
    argocd.argoproj.io/secret-type=repository --overwrite
  echo "Configured Argo CD repository credentials for $ARGOCD_REPO_URL"
else
  echo "WARN: ARGOCD_REPO_USERNAME/ARGOCD_REPO_PASSWORD not set. Argo CD can sync only if the repo is public or credentials already exist."
fi

kubectl apply -f kubernetes/argocd/project-production.yaml
kubectl apply -f kubernetes/argocd/application-production.yaml

kubectl rollout status deployment/argocd-repo-server -n "$ARGOCD_NAMESPACE" --timeout=300s
kubectl rollout status statefulset/argocd-application-controller -n "$ARGOCD_NAMESPACE" --timeout=300s
kubectl rollout status deployment/argo-rollouts -n "$ARGO_ROLLOUTS_NAMESPACE" --timeout=300s

echo "Argo CD production bootstrap complete"