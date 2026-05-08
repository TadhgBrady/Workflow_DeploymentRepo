#!/usr/bin/env sh
set -eu

BASE_URL="${1:-${STAGING_URL:-}}"
if [ -z "$BASE_URL" ]; then
  echo "❌ STAGING_URL is required"
  exit 1
fi

SCRIPT_PATH="${K6_SCRIPT_PATH:-tests/k6/staging-smoke-load.js}"
if [ ! -f "$SCRIPT_PATH" ]; then
  echo "❌ k6 script not found: $SCRIPT_PATH"
  exit 1
fi

STAGING_NAMESPACE="${STAGING_NAMESPACE:-year4-project-staging}"
MONITORING_NAMESPACE="${MONITORING_NAMESPACE:-monitoring}"
K6_ENVIRONMENT="${K6_ENVIRONMENT:-staging}"
K6_IMAGE="${K6_IMAGE:-grafana/k6:0.54.0}"
K6_JOB_TIMEOUT="${K6_JOB_TIMEOUT:-12m}"
K6_ITERATION_RATE="${K6_ITERATION_RATE:-1}"
K6_WARMUP_DURATION="${K6_WARMUP_DURATION:-30s}"
K6_DURATION="${K6_DURATION:-3m}"
K6_COOLDOWN_DURATION="${K6_COOLDOWN_DURATION:-30s}"
K6_PRE_ALLOCATED_VUS="${K6_PRE_ALLOCATED_VUS:-6}"
K6_MAX_VUS="${K6_MAX_VUS:-20}"
K6_THINK_TIME_SECONDS="${K6_THINK_TIME_SECONDS:-0.2}"
K6_PROMETHEUS_RW_PUSH_INTERVAL="${K6_PROMETHEUS_RW_PUSH_INTERVAL:-5s}"
K6_PROMETHEUS_RW_TREND_STATS="${K6_PROMETHEUS_RW_TREND_STATS:-min,avg,med,p(90),p(95),p(99),max}"
K6_PROMETHEUS_RW_STALE_MARKERS="${K6_PROMETHEUS_RW_STALE_MARKERS:-true}"

sanitize_name() {
  printf '%s' "$1" \
    | tr '[:upper:]_' '[:lower:]-' \
    | tr -cd 'a-z0-9-' \
    | sed 's/^-*//; s/-*$//' \
    | cut -c1-63
}

RAW_JOB_NAME="k6-staging-${CI_PIPELINE_ID:-manual}-${CI_JOB_ID:-local}"
JOB_NAME="${K6_JOB_NAME:-$(sanitize_name "$RAW_JOB_NAME")}"
if [ -z "$JOB_NAME" ]; then
  JOB_NAME="k6-staging-manual"
fi
CONFIGMAP_NAME="${K6_CONFIGMAP_NAME:-$(sanitize_name "$JOB_NAME-script")}"
K6_TEST_ID="${K6_TEST_ID:-staging-${CI_PIPELINE_ID:-manual}-${CI_JOB_ID:-local}}"
LABEL_TEST_ID="$(sanitize_name "$K6_TEST_ID")"
if [ -z "$LABEL_TEST_ID" ]; then
  LABEL_TEST_ID="manual"
fi

parse_timeout_seconds() {
  case "$1" in
    *h) echo $((${1%h} * 3600)) ;;
    *m) echo $((${1%m} * 60)) ;;
    *s) echo "${1%s}" ;;
    *) echo "$1" ;;
  esac
}

prometheus_remote_write_url() {
  if [ -n "${K6_PROMETHEUS_RW_SERVER_URL:-}" ]; then
    echo "$K6_PROMETHEUS_RW_SERVER_URL"
    return 0
  fi

  for service in "${KUBE_PROMETHEUS_SERVICE:-}" kube-prometheus-stack-prometheus prometheus-operated; do
    [ -n "$service" ] || continue
    if kubectl get service "$service" -n "$MONITORING_NAMESPACE" >/dev/null 2>&1; then
      echo "http://$service.$MONITORING_NAMESPACE.svc.cluster.local:9090/api/v1/write"
      return 0
    fi
  done

  service=$(kubectl get service -n "$MONITORING_NAMESPACE" -o name 2>/dev/null \
    | sed 's#service/##' \
    | grep -E '(^prometheus-operated$|prometheus$|-prometheus$)' \
    | head -1 || true)

  if [ -z "$service" ]; then
    echo "❌ Could not find a Prometheus service in namespace $MONITORING_NAMESPACE" >&2
    kubectl get service -n "$MONITORING_NAMESPACE" || true
    return 1
  fi

  echo "http://$service.$MONITORING_NAMESPACE.svc.cluster.local:9090/api/v1/write"
}

PROMETHEUS_RW_URL="$(prometheus_remote_write_url)"
TIMEOUT_SECONDS="$(parse_timeout_seconds "$K6_JOB_TIMEOUT")"

if [ -z "$TIMEOUT_SECONDS" ] || ! [ "$TIMEOUT_SECONDS" -gt 0 ] 2>/dev/null; then
  echo "❌ K6_JOB_TIMEOUT must be a positive duration ending in s/m/h or a number of seconds"
  exit 1
fi

echo "═══════════════════════════════════════════════════════════════"
echo "  k6 staging load gate"
echo "═══════════════════════════════════════════════════════════════"
echo "Target URL:        $BASE_URL"
echo "Namespace:         $STAGING_NAMESPACE"
echo "k6 image:          $K6_IMAGE"
echo "Test ID:           $K6_TEST_ID"
echo "Iteration rate:    $K6_ITERATION_RATE endpoint sweeps/sec"
echo "Duration:          warmup=$K6_WARMUP_DURATION steady=$K6_DURATION cooldown=$K6_COOLDOWN_DURATION"
echo "Remote write URL:  $PROMETHEUS_RW_URL"
echo "Job timeout:       $K6_JOB_TIMEOUT"

kubectl delete job "$JOB_NAME" -n "$STAGING_NAMESPACE" --ignore-not-found=true --wait=false >/dev/null 2>&1 || true
kubectl delete configmap "$CONFIGMAP_NAME" -n "$STAGING_NAMESPACE" --ignore-not-found=true >/dev/null 2>&1 || true

kubectl create configmap "$CONFIGMAP_NAME" \
  --namespace "$STAGING_NAMESPACE" \
  --from-file=staging-smoke-load.js="$SCRIPT_PATH"

cat <<EOF | kubectl apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: $JOB_NAME
  namespace: $STAGING_NAMESPACE
  labels:
    app.kubernetes.io/name: k6-staging-load
    app.kubernetes.io/part-of: year4-project-observability
    environment: $K6_ENVIRONMENT
    testid: $LABEL_TEST_ID
spec:
  backoffLimit: 0
  ttlSecondsAfterFinished: 3600
  template:
    metadata:
      labels:
        app.kubernetes.io/name: k6-staging-load
        app.kubernetes.io/part-of: year4-project-observability
        environment: $K6_ENVIRONMENT
        testid: $LABEL_TEST_ID
    spec:
      restartPolicy: Never
      containers:
        - name: k6
          image: $K6_IMAGE
          imagePullPolicy: IfNotPresent
          env:
            - name: STAGING_URL
              value: "$BASE_URL"
            - name: K6_ENVIRONMENT
              value: "$K6_ENVIRONMENT"
            - name: K6_TEST_ID
              value: "$K6_TEST_ID"
            - name: CI_PIPELINE_ID
              value: "${CI_PIPELINE_ID:-local}"
            - name: CI_JOB_ID
              value: "${CI_JOB_ID:-local}"
            - name: IMAGE_VERSION
              value: "${IMAGE_VERSION:-unknown}"
            - name: K6_ITERATION_RATE
              value: "$K6_ITERATION_RATE"
            - name: K6_WARMUP_DURATION
              value: "$K6_WARMUP_DURATION"
            - name: K6_DURATION
              value: "$K6_DURATION"
            - name: K6_COOLDOWN_DURATION
              value: "$K6_COOLDOWN_DURATION"
            - name: K6_PRE_ALLOCATED_VUS
              value: "$K6_PRE_ALLOCATED_VUS"
            - name: K6_MAX_VUS
              value: "$K6_MAX_VUS"
            - name: K6_THINK_TIME_SECONDS
              value: "$K6_THINK_TIME_SECONDS"
            - name: K6_PROMETHEUS_RW_SERVER_URL
              value: "$PROMETHEUS_RW_URL"
            - name: K6_PROMETHEUS_RW_PUSH_INTERVAL
              value: "$K6_PROMETHEUS_RW_PUSH_INTERVAL"
            - name: K6_PROMETHEUS_RW_TREND_STATS
              value: "$K6_PROMETHEUS_RW_TREND_STATS"
            - name: K6_PROMETHEUS_RW_STALE_MARKERS
              value: "$K6_PROMETHEUS_RW_STALE_MARKERS"
          args:
            - run
            - --out
            - experimental-prometheus-rw
            - /scripts/staging-smoke-load.js
          volumeMounts:
            - name: k6-script
              mountPath: /scripts
              readOnly: true
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              cpu: 1000m
              memory: 512Mi
      volumes:
        - name: k6-script
          configMap:
            name: $CONFIGMAP_NAME
EOF

DEADLINE=$(( $(date +%s) + TIMEOUT_SECONDS ))
RESULT=124
while true; do
  SUCCEEDED=$(kubectl get job "$JOB_NAME" -n "$STAGING_NAMESPACE" -o jsonpath='{.status.succeeded}' 2>/dev/null || true)
  FAILED=$(kubectl get job "$JOB_NAME" -n "$STAGING_NAMESPACE" -o jsonpath='{.status.failed}' 2>/dev/null || true)
  SUCCEEDED="${SUCCEEDED:-0}"
  FAILED="${FAILED:-0}"

  if [ "$SUCCEEDED" -ge 1 ] 2>/dev/null; then
    RESULT=0
    break
  fi

  if [ "$FAILED" -ge 1 ] 2>/dev/null; then
    RESULT=1
    break
  fi

  if [ "$(date +%s)" -ge "$DEADLINE" ]; then
    RESULT=124
    break
  fi

  sleep 5
done

echo "--- k6 job status ---"
kubectl get job "$JOB_NAME" -n "$STAGING_NAMESPACE" -o wide || true
kubectl get pods -n "$STAGING_NAMESPACE" -l "job-name=$JOB_NAME" -o wide || true

echo "--- k6 logs ---"
kubectl logs -n "$STAGING_NAMESPACE" "job/$JOB_NAME" --all-containers=true --timestamps || true

if [ "$RESULT" -ne 0 ]; then
  echo "--- k6 diagnostics ---"
  kubectl describe job "$JOB_NAME" -n "$STAGING_NAMESPACE" || true
  kubectl describe pods -n "$STAGING_NAMESPACE" -l "job-name=$JOB_NAME" || true
  kubectl get events -n "$STAGING_NAMESPACE" --sort-by=.lastTimestamp | tail -80 || true
  kubectl delete configmap "$CONFIGMAP_NAME" -n "$STAGING_NAMESPACE" --ignore-not-found=true >/dev/null 2>&1 || true

  if [ "$RESULT" -eq 124 ]; then
    echo "❌ k6 load gate timed out after $K6_JOB_TIMEOUT"
  else
    echo "❌ k6 load gate failed. Threshold failures are expected to fail this CI job."
  fi
  exit "$RESULT"
fi

kubectl delete configmap "$CONFIGMAP_NAME" -n "$STAGING_NAMESPACE" --ignore-not-found=true >/dev/null 2>&1 || true
echo "✅ k6 load gate passed. Metrics were pushed to Prometheus with testid=$K6_TEST_ID"
