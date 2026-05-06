#!/usr/bin/env sh
set -eu

CLUSTER_NAME="${1:-}"
NAMESPACE="${2:-amazon-cloudwatch}"
TIMEOUT="${3:-300s}"
ADDON_NAME="amazon-cloudwatch-observability"

echo "--- Checking Amazon CloudWatch Observability add-on ---"

ADDON_STATUS=""
if [ -n "$CLUSTER_NAME" ] && command -v aws >/dev/null 2>&1; then
  ADDON_STATUS=$(aws eks describe-addon \
    --cluster-name "$CLUSTER_NAME" \
    --addon-name "$ADDON_NAME" \
    --query 'addon.status' \
    --output text 2>/dev/null || true)

  if [ -z "$ADDON_STATUS" ] || [ "$ADDON_STATUS" = "None" ]; then
    echo "ℹ️  $ADDON_NAME is not installed on $CLUSTER_NAME; skipping readiness check."
    exit 0
  fi

  echo "CloudWatch Observability add-on status: $ADDON_STATUS"
  case "$ADDON_STATUS" in
    ACTIVE|CREATING|UPDATING)
      ;;
    *)
      echo "❌ $ADDON_NAME is in unexpected status: $ADDON_STATUS"
      aws eks describe-addon --cluster-name "$CLUSTER_NAME" --addon-name "$ADDON_NAME" --output table || true
      exit 1
      ;;
  esac
fi

if ! kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
  if [ -n "$ADDON_STATUS" ]; then
    echo "Waiting for namespace $NAMESPACE to be created by $ADDON_NAME..."
    ATTEMPT=1
    while [ "$ATTEMPT" -le 30 ]; do
      if kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
        break
      fi
      if [ "$ATTEMPT" -eq 30 ]; then
        echo "❌ $ADDON_NAME is present, but namespace $NAMESPACE was not created in time."
        exit 1
      fi
      sleep 10
      ATTEMPT=$((ATTEMPT + 1))
    done
  else
    echo "ℹ️  Namespace $NAMESPACE not present; CloudWatch Observability add-on is disabled or not applied yet."
    exit 0
  fi
fi

kubectl get pods -n "$NAMESPACE" -o wide || true
if ! kubectl wait --for=condition=Ready pods --all -n "$NAMESPACE" --timeout="$TIMEOUT"; then
  echo "❌ Amazon CloudWatch Observability add-on pods are not ready. Diagnostics:"
  kubectl describe pods -n "$NAMESPACE" || true
  kubectl get events -n "$NAMESPACE" --sort-by=.lastTimestamp | tail -80 || true
  exit 1
fi

echo "✅ Amazon CloudWatch Observability add-on is ready"