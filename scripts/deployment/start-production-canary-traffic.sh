#!/bin/sh
set -eu

NAMESPACE="${1:-${PROD_NAMESPACE:-year4-project}}"
DURATION_SECONDS="${2:-${PROD_TRAFFIC_DURATION_SECONDS:-2700}}"
INTERVAL_SECONDS="${3:-${PROD_TRAFFIC_INTERVAL_SECONDS:-5}}"
MODE="${4:-${PROD_TRAFFIC_MODE:-Both}}"
JOB_PREFIX="${PROD_TRAFFIC_JOB_PREFIX:-prod-canary-traffic}"
CURL_IMAGE="${PROD_TRAFFIC_CURL_IMAGE:-curlimages/curl:8.11.1}"
PATHS="${PROD_TRAFFIC_PATHS:-/ /api/v1/health /health /ready}"
KEEP_EXISTING="${PROD_TRAFFIC_KEEP_EXISTING:-false}"
WAIT_FOR_POD="${PROD_TRAFFIC_WAIT_FOR_POD:-true}"

case "$MODE" in
  Both|CanaryOnly|StableOnly) ;;
  *)
    echo "ERROR: unsupported PROD_TRAFFIC_MODE=$MODE" >&2
    echo "Allowed: Both, CanaryOnly, StableOnly" >&2
    exit 1
    ;;
esac

case "$DURATION_SECONDS" in
  ''|*[!0-9]*) echo "ERROR: DURATION_SECONDS must be numeric" >&2; exit 1 ;;
esac
case "$INTERVAL_SECONDS" in
  ''|*[!0-9]*) echo "ERROR: INTERVAL_SECONDS must be numeric" >&2; exit 1 ;;
esac

TARGET_SERVICES="$(kubectl -n "$NAMESPACE" get rollouts.argoproj.io -o json | python3 -c '
import json
import sys

mode = sys.argv[1]
data = json.load(sys.stdin)
services = set()

for item in data.get("items", []):
    canary = (((item.get("spec") or {}).get("strategy") or {}).get("canary") or {})
    stable_service = canary.get("stableService")
    canary_service = canary.get("canaryService")
    if mode in ("Both", "StableOnly") and stable_service:
        services.add(stable_service)
    if mode in ("Both", "CanaryOnly") and canary_service:
        services.add(canary_service)

for service in sorted(services):
    print(service)
' "$MODE"
)"

if [ -z "$TARGET_SERVICES" ]; then
  echo "ERROR: no Rollout stable/canary Services found in namespace $NAMESPACE" >&2
  exit 1
fi

TIMESTAMP="$(date -u +%Y%m%d%H%M%S)"
JOB_NAME="$JOB_PREFIX-$TIMESTAMP"
ACTIVE_DEADLINE_SECONDS=$((DURATION_SECONDS + 900))
TTL_SECONDS=$ACTIVE_DEADLINE_SECONDS
if [ "$TTL_SECONDS" -lt 3600 ]; then
  TTL_SECONDS=3600
fi

SERVICE_LIST_YAML="$(printf '%s\n' "$TARGET_SERVICES" | sed 's/^/                /')"
PATH_LIST_YAML="$(printf '%s\n' $PATHS | sed 's/^/                /')"

if [ "$KEEP_EXISTING" != "true" ]; then
  kubectl -n "$NAMESPACE" delete job -l app.kubernetes.io/name=production-canary-traffic --ignore-not-found=true --wait=false >/dev/null 2>&1 || true
fi

echo "Starting production canary traffic job"
echo "  Namespace: $NAMESPACE"
echo "  Job:       $JOB_NAME"
echo "  Duration:  ${DURATION_SECONDS}s"
echo "  Interval:  ${INTERVAL_SECONDS}s"
echo "  Mode:      $MODE"
echo "  Services:  $(printf '%s\n' "$TARGET_SERVICES" | wc -l | tr -d ' ')"

cat <<EOF | kubectl apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: $JOB_NAME
  namespace: $NAMESPACE
  labels:
    app.kubernetes.io/name: production-canary-traffic
    app.kubernetes.io/part-of: year4-project-observability
    environment: production
spec:
  backoffLimit: 6
  activeDeadlineSeconds: $ACTIVE_DEADLINE_SECONDS
  ttlSecondsAfterFinished: $TTL_SECONDS
  template:
    metadata:
      annotations:
        sidecar.istio.io/inject: "true"
      labels:
        app.kubernetes.io/name: production-canary-traffic
        app.kubernetes.io/part-of: year4-project-observability
        environment: production
    spec:
      restartPolicy: Never
      priorityClassName: year4-batch
      terminationGracePeriodSeconds: 10
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        runAsGroup: 10001
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: traffic
          image: $CURL_IMAGE
          imagePullPolicy: IfNotPresent
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop:
                - ALL
          env:
            - name: NAMESPACE
              value: $NAMESPACE
            - name: DURATION_SECONDS
              value: "$DURATION_SECONDS"
            - name: INTERVAL_SECONDS
              value: "$INTERVAL_SECONDS"
            - name: TARGET_SERVICES
              value: |-
$SERVICE_LIST_YAML
            - name: TARGET_PATHS
              value: |-
$PATH_LIST_YAML
          command:
            - /bin/sh
            - -c
          args:
            - |
              set -eu
              END_TIME="\$((\$(date +%s) + DURATION_SECONDS))"
              TOTAL=0
              FAILURES=0
              echo "Starting production canary traffic for \$DURATION_SECONDS seconds"
              echo "Namespace: \$NAMESPACE"
              echo "Services:"
              printf '%s\n' "\$TARGET_SERVICES"
              echo "Paths:"
              printf '%s\n' "\$TARGET_PATHS"
              while [ "\$(date +%s)" -lt "\$END_TIME" ]; do
                for SERVICE in \$TARGET_SERVICES; do
                  for PATH_VALUE in \$TARGET_PATHS; do
                    URL="http://\$SERVICE.\$NAMESPACE.svc.cluster.local\$PATH_VALUE"
                    CODE="\$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 2 --max-time 5 "\$URL")" || CODE="000"
                    TOTAL="\$((TOTAL + 1))"
                    case "\$CODE" in
                      000|5*) FAILURES="\$((FAILURES + 1))" ;;
                    esac
                    printf '%s service=%s path=%s status=%s total=%s failures=%s\n' "\$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "\$SERVICE" "\$PATH_VALUE" "\$CODE" "\$TOTAL" "\$FAILURES"
                  done
                done
                sleep "\$INTERVAL_SECONDS"
              done
              echo "Finished production canary traffic: total=\$TOTAL failures=\$FAILURES"
              curl -sf -XPOST http://127.0.0.1:15020/quitquitquit || true
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              cpu: 500m
              memory: 256Mi
EOF

if [ "$WAIT_FOR_POD" = "true" ]; then
  kubectl wait -n "$NAMESPACE" --for=condition=PodScheduled pod -l "job-name=$JOB_NAME" --timeout=180s
fi

kubectl -n "$NAMESPACE" get job "$JOB_NAME" -o wide
kubectl -n "$NAMESPACE" get pods -l "job-name=$JOB_NAME" -o wide
echo "Production canary traffic job started: $JOB_NAME"