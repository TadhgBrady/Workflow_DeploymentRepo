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
		argocd --core app wait "$ARGOCD_APP" --app-namespace "$ARGOCD_NAMESPACE" --health --timeout "$ARGOCD_TIMEOUT"
	else
		argocd --core app wait "$ARGOCD_APP" --app-namespace "$ARGOCD_NAMESPACE" --sync --timeout "$ARGOCD_TIMEOUT"
	fi
	APP_STATUS_FILE="argocd-$ARGOCD_APP.json"
	argocd --core app get "$ARGOCD_APP" --app-namespace "$ARGOCD_NAMESPACE" -o json > "$APP_STATUS_FILE"
	if [ "$ARGOCD_APP" = "year4-project-production" ]; then
		python3 - "$APP_STATUS_FILE" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as status_file:
	app = json.load(status_file)

status = app.get("status", {})
sync_status = status.get("sync", {}).get("status")
resources = status.get("resources") or []
out_of_sync = [resource for resource in resources if resource.get("status") != "Synced"]

namespace_only_drift = (
	len(out_of_sync) == 1
	and out_of_sync[0].get("kind") == "Namespace"
	and out_of_sync[0].get("name") == "year4-project"
	and not out_of_sync[0].get("group")
	and not out_of_sync[0].get("namespace")
)

if sync_status == "Synced":
	print("Production Argo CD application is Synced and Healthy")
elif namespace_only_drift:
	print("Production Argo CD application is Healthy; tolerating Namespace/year4-project metadata drift")
else:
	print(f"Production Argo CD application sync status is {sync_status}", file=sys.stderr)
	for resource in out_of_sync:
		group = resource.get("group") or "core"
		namespace = resource.get("namespace") or "cluster"
		kind = resource.get("kind") or "unknown"
		name = resource.get("name") or "unknown"
		status_value = resource.get("status") or "unknown"
		print(f"OutOfSync: {group}/{kind} {namespace}/{name} status={status_value}", file=sys.stderr)
	sys.exit(1)
PY
		cp "$APP_STATUS_FILE" argocd-production-app.json
	fi
done

echo "Waiting for production workloads after Argo CD sync"
sh scripts/deployment/wait-deployment-rollout.sh "$PROD_NAMESPACE" 300
echo "Argo CD production sync complete"