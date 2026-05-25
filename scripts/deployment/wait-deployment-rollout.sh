#!/bin/sh
set -eu

NAMESPACE="${1:?usage: wait-deployment-rollout.sh <namespace> [timeout-seconds]}"
TIMEOUT_SECONDS="${2:-300}"

FAILED_WORKLOADS=""
WORKLOAD_COUNT=0

diagnose_workload() {
  RESOURCE="$1"
  NAME="$2"

  APP_KUBERNETES_NAME=$(kubectl get "$RESOURCE" -n "$NAMESPACE" -o jsonpath='{.spec.selector.matchLabels.app\.kubernetes\.io/name}' 2>/dev/null || true)
  APP_LABEL=$(kubectl get "$RESOURCE" -n "$NAMESPACE" -o jsonpath='{.spec.selector.matchLabels.app}' 2>/dev/null || true)

  if [ -n "$APP_KUBERNETES_NAME" ]; then
    LABEL_SELECTOR="app.kubernetes.io/name=$APP_KUBERNETES_NAME"
    EVENT_PATTERN="$NAME|$APP_KUBERNETES_NAME"
  elif [ -n "$APP_LABEL" ]; then
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

diagnose_analysis_runs() {
  ROLLOUT_NAME="$1"

  echo "-- Recent AnalysisRuns --"
  kubectl get analysisruns.argoproj.io -n "$NAMESPACE" --sort-by=.metadata.creationTimestamp 2>/dev/null | tail -10 || true
  echo "-- AnalysisRun details for $ROLLOUT_NAME --"
  FOUND_ANALYSIS_RUNS="false"
  for ANALYSIS_RUN in $(kubectl get analysisruns.argoproj.io -n "$NAMESPACE" -o name 2>/dev/null | grep -E "(^|/)$ROLLOUT_NAME(-|$)" | tail -5 || true); do
    FOUND_ANALYSIS_RUNS="true"
    kubectl describe "$ANALYSIS_RUN" -n "$NAMESPACE" || true
  done
  if [ "$FOUND_ANALYSIS_RUNS" = "false" ]; then
    echo "No AnalysisRuns with names matching $ROLLOUT_NAME were found"
  fi
}

diagnose_rollout() {
  ROLLOUT="$1"
  ROLLOUT_NAME="$2"

  echo "-- Rollout description --"
  kubectl describe "$ROLLOUT" -n "$NAMESPACE" || true
  if command -v kubectl-argo-rollouts >/dev/null 2>&1; then
    echo "-- Argo Rollouts tree --"
    kubectl argo rollouts get rollout "$ROLLOUT_NAME" -n "$NAMESPACE" || true
  fi
  diagnose_analysis_runs "$ROLLOUT_NAME"
  diagnose_workload "$ROLLOUT" "$ROLLOUT_NAME"
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

  echo "❌ $DEPLOY rollout failed — gathering diagnostics..."
  diagnose_workload "$DEPLOY" "$DEPLOY_NAME"
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

  echo "❌ $ROLLOUT rollout failed — gathering diagnostics..."
  diagnose_rollout "$ROLLOUT" "$ROLLOUT_NAME"
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
