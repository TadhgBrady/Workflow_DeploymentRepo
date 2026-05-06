#!/bin/sh
set -eu

NAMESPACE="${1:?usage: sync-external-secrets.sh <namespace> [timeout-seconds]}"
TIMEOUT_SECONDS="${2:-180}"

if ! kubectl get externalsecret -n "$NAMESPACE" >/dev/null 2>&1; then
  echo "ℹ️  No ExternalSecret resources found in namespace $NAMESPACE"
  exit 0
fi

echo "Forcing ExternalSecrets to re-sync in $NAMESPACE..."
for es in $(kubectl get externalsecret -n "$NAMESPACE" -o name 2>/dev/null); do
  kubectl annotate "$es" -n "$NAMESPACE" force-sync="$(date +%s)" --overwrite >/dev/null 2>&1 || true
done

echo "Waiting for ExternalSecrets to report Ready=True..."
if ! kubectl wait --for=condition=Ready=True externalsecret \
  --all -n "$NAMESPACE" --timeout="${TIMEOUT_SECONDS}s"; then
  echo "❌ ExternalSecret sync timed out — diagnostics:"
  kubectl get externalsecrets -n "$NAMESPACE" || true
  kubectl describe externalsecrets -n "$NAMESPACE" || true
  kubectl logs -n external-secrets -l app.kubernetes.io/name=external-secrets --tail=80 --all-containers 2>/dev/null || true
  exit 1
fi

TARGET_SECRETS=$(kubectl get externalsecret -n "$NAMESPACE" \
  -o jsonpath='{range .items[*]}{.spec.target.name}{"\n"}{end}' 2>/dev/null | sed '/^$/d' || true)

if [ -z "$TARGET_SECRETS" ]; then
  echo "⚠️  ExternalSecrets are Ready, but no target secret names were found"
  exit 0
fi

echo "Verifying synced Kubernetes Secret data exists..."
DEADLINE=$(( $(date +%s) + TIMEOUT_SECONDS ))
MISSING=""
while :; do
  MISSING=""
  for secret in $TARGET_SECRETS; do
    data=$(kubectl get secret "$secret" -n "$NAMESPACE" -o jsonpath='{.data}' 2>/dev/null || true)
    if [ -z "$data" ] || [ "$data" = "{}" ]; then
      MISSING="$MISSING $secret"
    fi
  done

  if [ -z "$MISSING" ]; then
    echo "✅ All ExternalSecrets synced and target Secrets contain data"
    exit 0
  fi

  if [ "$(date +%s)" -ge "$DEADLINE" ]; then
    echo "❌ Target Secrets missing or empty after ${TIMEOUT_SECONDS}s:$MISSING"
    kubectl get externalsecrets,secrets -n "$NAMESPACE" || true
    exit 1
  fi

  echo "  Waiting for target Secret data:$MISSING"
  sleep 5
done
