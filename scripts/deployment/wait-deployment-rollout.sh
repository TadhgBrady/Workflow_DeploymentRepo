#!/bin/sh
set -eu

NAMESPACE="${1:?usage: wait-deployment-rollout.sh <namespace> [timeout-seconds]}"
TIMEOUT_SECONDS="${2:-300}"

FAILED_WORKLOADS=""
WORKLOAD_COUNT=0

diagnose_workload() {
  RESOURCE="$1"
  NAME="$2"
  APP_LABEL="$3"

  if [ -n "$APP_LABEL" ]; then
    LABEL_SELECTOR="app=$APP_LABEL"
    EVENT_PATTERN="$NAME|$APP_LABEL"
  else
    LABEL_SELECTOR="app=$NAME"
    EVENT_PATTERN="$NAME"
  fi

  echo "── Workload selector ──"
  kubectl get "$RESOURCE" -n "$NAMESPACE" -o jsonpath='{.spec.selector.matchLabels}' 2>/dev/null || true
  echo ""
  echo "── Pod status ──"
  kubectl get pods -n "$NAMESPACE" -l "$LABEL_SELECTOR" -o wide 2>/dev/null || true
  echo "── Recent events ──"
  kubectl get events -n "$NAMESPACE" --sort-by=.lastTimestamp --field-selector involvedObject.kind=Pod 2>/dev/null | grep -E "$EVENT_PATTERN" | tail -20 || true
  echo "── Container logs (last 40 lines) ──"
  kubectl logs -n "$NAMESPACE" -l "$LABEL_SELECTOR" --tail=40 --all-containers 2>/dev/null || true
  echo ""
}

wait_rollout_without_plugin() {
  ROLLOUT="$1"
  ROLLOUT_NAME="$2"
  DEADLINE=$(( $(date +%s) + TIMEOUT_SECONDS ))

  while [ "$(date +%s)" -le "$DEADLINE" ]; do
    PHASE=$(kubectl get "$ROLLOUT" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || true)
    MESSAGE=$(kubectl get "$ROLLOUT" -n "$NAMESPACE" -o jsonpath='{.status.message}' 2>/dev/null || true)

    case "$PHASE" in
      Healthy)
        echo "  $ROLLOUT is Healthy"
        return 0
        ;;
      Degraded|Error)
        echo "  $ROLLOUT is $PHASE: $MESSAGE"
        return 1
        ;;
      *)
        echo "  $ROLLOUT phase: ${PHASE:-unknown} ${MESSAGE:-}"
        sleep 10
        ;;
    esac
  done

  echo "  Timed out waiting for $ROLLOUT_NAME to become Healthy"
  return 1
}

echo "Waiting for deployments in $NAMESPACE to become ready..."
for DEPLOY in $(kubectl get deployments -n "$NAMESPACE" -o name); do
  WORKLOAD_COUNT=$((WORKLOAD_COUNT + 1))
  echo "  Waiting for $DEPLOY..."
  if kubectl rollout status "$DEPLOY" -n "$NAMESPACE" --timeout="${TIMEOUT_SECONDS}s"; then
    continue
  fi

  DEPLOY_NAME=$(echo "$DEPLOY" | sed 's|deployment.apps/||; s|deployment/||')
  APP_LABEL=$(kubectl get "$DEPLOY" -n "$NAMESPACE" -o jsonpath='{.spec.selector.matchLabels.app}' 2>/dev/null || true)

  echo "❌ $DEPLOY rollout failed — gathering diagnostics..."
  diagnose_workload "$DEPLOY" "$DEPLOY_NAME" "$APP_LABEL"
  FAILED_WORKLOADS="$FAILED_WORKLOADS deployment/$DEPLOY_NAME"
done

echo "Waiting for Argo Rollouts in $NAMESPACE to become healthy..."
for ROLLOUT in $(kubectl get rollouts.argoproj.io -n "$NAMESPACE" -o name 2>/dev/null || true); do
  WORKLOAD_COUNT=$((WORKLOAD_COUNT + 1))
  ROLLOUT_NAME=$(echo "$ROLLOUT" | sed 's|.*/||')
  echo "  Waiting for $ROLLOUT..."

  if command -v kubectl-argo-rollouts >/dev/null 2>&1; then
    if kubectl argo rollouts status "$ROLLOUT_NAME" -n "$NAMESPACE" --timeout="${TIMEOUT_SECONDS}s"; then
      continue
    fi
  elif wait_rollout_without_plugin "$ROLLOUT" "$ROLLOUT_NAME"; then
    continue
  fi

  APP_LABEL=$(kubectl get "$ROLLOUT" -n "$NAMESPACE" -o jsonpath='{.spec.selector.matchLabels.app}' 2>/dev/null || true)
  echo "❌ $ROLLOUT rollout failed — gathering diagnostics..."
  kubectl describe "$ROLLOUT" -n "$NAMESPACE" || true
  if command -v kubectl-argo-rollouts >/dev/null 2>&1; then
    kubectl argo rollouts get rollout "$ROLLOUT_NAME" -n "$NAMESPACE" || true
  fi
  diagnose_workload "$ROLLOUT" "$ROLLOUT_NAME" "$APP_LABEL"
  FAILED_WORKLOADS="$FAILED_WORKLOADS rollout/$ROLLOUT_NAME"
done

if [ "$WORKLOAD_COUNT" -eq 0 ]; then
  echo "❌ No Deployments or Argo Rollouts found in namespace $NAMESPACE"
  exit 1
fi

if [ -n "$FAILED_WORKLOADS" ]; then
  echo ""
  echo "❌ FAILED WORKLOADS:$FAILED_WORKLOADS"
  echo ""
  echo "Common causes: ImagePullBackOff, CrashLoopBackOff, Pending due to CPU/memory, or probe failures."
  exit 1
fi

echo "✅ All Deployments/Rollouts in $NAMESPACE are ready"
