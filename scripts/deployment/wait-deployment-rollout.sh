#!/bin/sh
set -eu

NAMESPACE="${1:?usage: wait-deployment-rollout.sh <namespace> [timeout-seconds]}"
TIMEOUT_SECONDS="${2:-300}"

FAILED_DEPLOYS=""

echo "Waiting for deployments in $NAMESPACE to become ready..."
for DEPLOY in $(kubectl get deployments -n "$NAMESPACE" -o name); do
  echo "  Waiting for $DEPLOY..."
  if kubectl rollout status "$DEPLOY" -n "$NAMESPACE" --timeout="${TIMEOUT_SECONDS}s"; then
    continue
  fi

  DEPLOY_NAME=$(echo "$DEPLOY" | sed 's|deployment.apps/||; s|deployment/||')
  APP_LABEL=$(kubectl get "$DEPLOY" -n "$NAMESPACE" -o jsonpath='{.spec.selector.matchLabels.app}' 2>/dev/null || true)
  if [ -n "$APP_LABEL" ]; then
    LABEL_SELECTOR="app=$APP_LABEL"
    EVENT_PATTERN="$DEPLOY_NAME|$APP_LABEL"
  else
    LABEL_SELECTOR="app=$DEPLOY_NAME"
    EVENT_PATTERN="$DEPLOY_NAME"
  fi

  echo "❌ $DEPLOY rollout failed — gathering diagnostics..."
  echo "── Deployment selector ──"
  kubectl get "$DEPLOY" -n "$NAMESPACE" -o jsonpath='{.spec.selector.matchLabels}' 2>/dev/null || true
  echo ""
  echo "── Pod status ──"
  kubectl get pods -n "$NAMESPACE" -l "$LABEL_SELECTOR" -o wide 2>/dev/null || true
  echo "── Recent events ──"
  kubectl get events -n "$NAMESPACE" --sort-by=.lastTimestamp --field-selector involvedObject.kind=Pod 2>/dev/null | grep -E "$EVENT_PATTERN" | tail -20 || true
  echo "── Container logs (last 40 lines) ──"
  kubectl logs -n "$NAMESPACE" -l "$LABEL_SELECTOR" --tail=40 --all-containers 2>/dev/null || true
  echo ""
  FAILED_DEPLOYS="$FAILED_DEPLOYS $DEPLOY_NAME"
done

if [ -n "$FAILED_DEPLOYS" ]; then
  echo ""
  echo "❌ FAILED DEPLOYMENTS:$FAILED_DEPLOYS"
  echo ""
  echo "Common causes: ImagePullBackOff, CrashLoopBackOff, Pending due to CPU/memory, or probe failures."
  exit 1
fi

echo "✅ All deployments in $NAMESPACE are ready"
