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
		if ! argocd --core app wait "$ARGOCD_APP" --app-namespace "$ARGOCD_NAMESPACE" --sync --timeout "$ARGOCD_TIMEOUT"; then
			APP_STATUS_FILE="argocd-$ARGOCD_APP.json"
			argocd --core app get "$ARGOCD_APP" --app-namespace "$ARGOCD_NAMESPACE" -o json > "$APP_STATUS_FILE" || true
			cp "$APP_STATUS_FILE" argocd-production-app.json 2>/dev/null || true
			exit 1
		fi
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
health_status = status.get("health", {}).get("status") or "Unknown"
resources = status.get("resources") or []
out_of_sync = [resource for resource in resources if resource.get("status") != "Synced"]
degraded = [resource for resource in resources if (resource.get("health") or {}).get("status") == "Degraded"]

namespace_only_drift = (
	len(out_of_sync) == 1
	and out_of_sync[0].get("kind") == "Namespace"
	and out_of_sync[0].get("name") == "year4-project"
	and not out_of_sync[0].get("group")
	and not out_of_sync[0].get("namespace")
)

if sync_status == "Synced":
	print(f"Production Argo CD application is Synced; current health is {health_status}")
	if degraded:
		print("Degraded resources will be diagnosed by the rollout health gate:", file=sys.stderr)
		for resource in degraded:
			group = resource.get("group") or "core"
			namespace = resource.get("namespace") or "cluster"
			kind = resource.get("kind") or "unknown"
			name = resource.get("name") or "unknown"
			print(f"Degraded: {group}/{kind} {namespace}/{name}", file=sys.stderr)
elif namespace_only_drift:
	print(f"Production Argo CD application health is {health_status}; tolerating Namespace/year4-project metadata drift")
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
if ! sh scripts/deployment/wait-deployment-rollout.sh "$PROD_NAMESPACE" 300; then
	APP_STATUS_FILE="argocd-year4-project-production.json"
	argocd --core app get "year4-project-production" --app-namespace "$ARGOCD_NAMESPACE" -o json > "$APP_STATUS_FILE" || true
	cp "$APP_STATUS_FILE" argocd-production-app.json 2>/dev/null || true
	exit 1
fi

echo "Checking final production Argo CD health"
APP_STATUS_FILE="argocd-year4-project-production.json"
argocd --core app get "year4-project-production" --app-namespace "$ARGOCD_NAMESPACE" -o json > "$APP_STATUS_FILE"
python3 - "$APP_STATUS_FILE" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as status_file:
	app = json.load(status_file)

status = app.get("status", {})
sync_status = status.get("sync", {}).get("status")
health_status = status.get("health", {}).get("status") or "Unknown"
resources = status.get("resources") or []
unhealthy = [
	resource
	for resource in resources
	if (resource.get("health") or {}).get("status") not in (None, "Healthy")
]

if sync_status == "Synced" and health_status == "Healthy":
	print("Production Argo CD application is Synced and Healthy")
	sys.exit(0)

print(f"Production Argo CD application final status is sync={sync_status}, health={health_status}", file=sys.stderr)
for resource in unhealthy:
	group = resource.get("group") or "core"
	namespace = resource.get("namespace") or "cluster"
	kind = resource.get("kind") or "unknown"
	name = resource.get("name") or "unknown"
	health = (resource.get("health") or {}).get("status") or "Unknown"
	message = (resource.get("health") or {}).get("message") or ""
	print(f"Unhealthy: {group}/{kind} {namespace}/{name} health={health} {message}", file=sys.stderr)
sys.exit(1)
PY
cp "$APP_STATUS_FILE" argocd-production-app.json
echo "Argo CD production sync complete"