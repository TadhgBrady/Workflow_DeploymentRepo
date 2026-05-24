#!/bin/sh
set -eu

ARGOCD_APPS="${ARGOCD_APPS:-year4-project-service-mesh-production year4-project-production}"
ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-argocd}"
ARGOCD_TIMEOUT="${ARGOCD_TIMEOUT:-900}"
PROD_NAMESPACE="${PROD_NAMESPACE:-year4-project}"

for ARGOCD_APP in $ARGOCD_APPS; do
	echo "Syncing Argo CD application: $ARGOCD_APP"
	argocd --core app get "$ARGOCD_APP" --app-namespace "$ARGOCD_NAMESPACE"
	argocd --core app sync "$ARGOCD_APP" --app-namespace "$ARGOCD_NAMESPACE" --revision main --prune --timeout "$ARGOCD_TIMEOUT"
	if [ "$ARGOCD_APP" = "year4-project-production" ]; then
		argocd --core app wait "$ARGOCD_APP" --app-namespace "$ARGOCD_NAMESPACE" --sync --health --timeout "$ARGOCD_TIMEOUT"
	else
		argocd --core app wait "$ARGOCD_APP" --app-namespace "$ARGOCD_NAMESPACE" --sync --timeout "$ARGOCD_TIMEOUT"
	fi
	argocd --core app get "$ARGOCD_APP" --app-namespace "$ARGOCD_NAMESPACE" -o json > "argocd-$ARGOCD_APP.json"
done

echo "Waiting for production workloads after Argo CD sync"
sh scripts/deployment/wait-deployment-rollout.sh "$PROD_NAMESPACE" 300
echo "Argo CD production sync complete"