#!/bin/sh
set -eu

ARGOCD_APP="${ARGOCD_APP:-year4-project-production}"
ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-argocd}"
ARGOCD_TIMEOUT="${ARGOCD_TIMEOUT:-900}"
PROD_NAMESPACE="${PROD_NAMESPACE:-year4-project}"

echo "Syncing Argo CD application: $ARGOCD_APP"
argocd --core --argocd-namespace "$ARGOCD_NAMESPACE" app get "$ARGOCD_APP"
argocd --core --argocd-namespace "$ARGOCD_NAMESPACE" app sync "$ARGOCD_APP" --revision main --prune --timeout "$ARGOCD_TIMEOUT"
argocd --core --argocd-namespace "$ARGOCD_NAMESPACE" app wait "$ARGOCD_APP" --sync --health --timeout "$ARGOCD_TIMEOUT"
argocd --core --argocd-namespace "$ARGOCD_NAMESPACE" app get "$ARGOCD_APP" -o json > argocd-production-app.json

echo "Waiting for production workloads after Argo CD sync"
sh scripts/deployment/wait-deployment-rollout.sh "$PROD_NAMESPACE" 300
echo "Argo CD production sync complete"