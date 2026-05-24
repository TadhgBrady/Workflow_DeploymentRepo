#!/bin/sh
set -eu

ARGOCD_APPS="${ARGOCD_APPS:-year4-project-service-mesh-production year4-project-production}"
ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-argocd}"
ARGOCD_TIMEOUT="${ARGOCD_TIMEOUT:-900}"
PROD_NAMESPACE="${PROD_NAMESPACE:-year4-project}"
export ARGOCD_REQUIRE_PERSISTENT_REPO_CREDS="${ARGOCD_REQUIRE_PERSISTENT_REPO_CREDS:-true}"

# In --core mode the Argo CD CLI discovers argocd-cm from the current kube
# context namespace. GitLab's fresh kubeconfig defaults to "default", so point
# it at the Argo CD control-plane namespace before invoking argocd.
kubectl config set-context --current --namespace "$ARGOCD_NAMESPACE" >/dev/null

# Refresh repo credentials in this job as well. If the bootstrap job used a
# GitLab CI job token, that token may expire before deploy-production runs.
sh scripts/deployment/ensure-argocd-repo-credentials.sh

for ARGOCD_APP in $ARGOCD_APPS; do
	echo "Syncing Argo CD application: $ARGOCD_APP"
	argocd --core app get "$ARGOCD_APP" --app-namespace "$ARGOCD_NAMESPACE"
	argocd --core app sync "$ARGOCD_APP" --app-namespace "$ARGOCD_NAMESPACE" --revision main --prune --timeout "$ARGOCD_TIMEOUT"
	if [ "$ARGOCD_APP" = "year4-project-production" ]; then
		argocd --core app wait "$ARGOCD_APP" --app-namespace "$ARGOCD_NAMESPACE" --sync --health --timeout "$ARGOCD_TIMEOUT"
	else
		argocd --core app wait "$ARGOCD_APP" --app-namespace "$ARGOCD_NAMESPACE" --sync --timeout "$ARGOCD_TIMEOUT"
	fi
	APP_STATUS_FILE="argocd-$ARGOCD_APP.json"
	argocd --core app get "$ARGOCD_APP" --app-namespace "$ARGOCD_NAMESPACE" -o json > "$APP_STATUS_FILE"
	if [ "$ARGOCD_APP" = "year4-project-production" ]; then
		cp "$APP_STATUS_FILE" argocd-production-app.json
	fi
done

echo "Waiting for production workloads after Argo CD sync"
sh scripts/deployment/wait-deployment-rollout.sh "$PROD_NAMESPACE" 300
echo "Argo CD production sync complete"