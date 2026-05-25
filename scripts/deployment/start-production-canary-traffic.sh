#!/bin/sh
set -eu

NAMESPACE="${1:-${PROD_NAMESPACE:-year4-project}}"
DURATION_SECONDS="${2:-${PROD_TRAFFIC_DURATION_SECONDS:-2700}}"
INTERVAL_SECONDS="${3:-${PROD_TRAFFIC_INTERVAL_SECONDS:-5}}"
MODE="${4:-${PROD_TRAFFIC_MODE:-Both}}"
JOB_PREFIX="${PROD_TRAFFIC_JOB_PREFIX:-prod-canary-traffic}"
CURL_IMAGE="${PROD_TRAFFIC_CURL_IMAGE:-curlimages/curl:8.11.1}"
SAFE_DEFAULT_PATHS="__service_safe_defaults__"
PATHS="${PROD_TRAFFIC_PATHS:-$SAFE_DEFAULT_PATHS}"
KEEP_EXISTING="${PROD_TRAFFIC_KEEP_EXISTING:-false}"
WAIT_FOR_POD="${PROD_TRAFFIC_WAIT_FOR_POD:-true}"
ISTIO_NAMESPACE="${ISTIO_NAMESPACE:-istio-system}"
MONITORING_NAMESPACE="${MONITORING_NAMESPACE:-monitoring}"
PROMETHEUS_SERVICE="${PROMETHEUS_SERVICE:-kube-prometheus-stack-prometheus}"
INJECTION_ATTEMPTS="${PROD_TRAFFIC_INJECTION_ATTEMPTS:-3}"
POD_READY_TIMEOUT_SECONDS="${PROD_TRAFFIC_POD_READY_TIMEOUT_SECONDS:-180}"

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
case "$INJECTION_ATTEMPTS" in
  ''|*[!0-9]*) echo "ERROR: PROD_TRAFFIC_INJECTION_ATTEMPTS must be numeric" >&2; exit 1 ;;
esac
case "$POD_READY_TIMEOUT_SECONDS" in
  ''|*[!0-9]*) echo "ERROR: PROD_TRAFFIC_POD_READY_TIMEOUT_SECONDS must be numeric" >&2; exit 1 ;;
esac

wait_for_service_endpoints() {
  CHECK_NAMESPACE="$1"
  SERVICE_NAME="$2"
  TIMEOUT_SECONDS="$3"
  END_TIME=$(( $(date +%s) + TIMEOUT_SECONDS ))

  echo "Waiting for service endpoints: $SERVICE_NAME.$CHECK_NAMESPACE"
  while [ "$(date +%s)" -lt "$END_TIME" ]; do
    ENDPOINTS="$(kubectl -n "$CHECK_NAMESPACE" get endpoints "$SERVICE_NAME" -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null || true)"
    if [ -n "$ENDPOINTS" ]; then
      return 0
    fi
    sleep 5
  done

  echo "ERROR: service $SERVICE_NAME in namespace $CHECK_NAMESPACE has no ready endpoints" >&2
  kubectl -n "$CHECK_NAMESPACE" get svc,endpoints "$SERVICE_NAME" -o wide >&2 || true
  return 1
}

wait_for_mesh_dependencies() {
  echo "Checking release-critical mesh and analysis dependencies"
  INJECTION_LABEL="$(kubectl get namespace "$NAMESPACE" -o jsonpath='{.metadata.labels.istio-injection}' 2>/dev/null || true)"
  REVISION_LABEL="$(kubectl get namespace "$NAMESPACE" -o jsonpath='{.metadata.labels.istio\.io/rev}' 2>/dev/null || true)"
  if [ "$INJECTION_LABEL" != "enabled" ] && [ -z "$REVISION_LABEL" ]; then
    echo "ERROR: namespace $NAMESPACE is not labelled for Istio sidecar injection" >&2
    kubectl get namespace "$NAMESPACE" --show-labels >&2 || true
    return 1
  fi

  kubectl -n "$ISTIO_NAMESPACE" rollout status deployment/istiod --timeout=300s
  wait_for_service_endpoints "$ISTIO_NAMESPACE" istiod 180
  kubectl get mutatingwebhookconfiguration istio-sidecar-injector >/dev/null
  wait_for_service_endpoints "$MONITORING_NAMESPACE" "$PROMETHEUS_SERVICE" 300
}

get_job_pod_name() {
  kubectl -n "$NAMESPACE" get pod -l "job-name=$JOB_NAME" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true
}

pod_has_istio_proxy() {
  POD_NAME="$1"
  CONTAINERS="$(kubectl -n "$NAMESPACE" get pod "$POD_NAME" -o jsonpath='{.spec.containers[*].name}' 2>/dev/null || true)"
  printf '%s\n' "$CONTAINERS" | grep -Eq '(^| )istio-proxy( |$)'
}

wait_for_traffic_pod_name() {
  END_TIME=$(( $(date +%s) + POD_READY_TIMEOUT_SECONDS ))
  while [ "$(date +%s)" -lt "$END_TIME" ]; do
    POD_NAME="$(get_job_pod_name)"
    if [ -n "$POD_NAME" ]; then
      printf '%s\n' "$POD_NAME"
      return 0
    fi
    sleep 3
  done

  echo "ERROR: traffic Job $JOB_NAME did not create a Pod" >&2
  kubectl -n "$NAMESPACE" describe job "$JOB_NAME" >&2 || true
  return 1
}

verify_traffic_pod() {
  if [ "$WAIT_FOR_POD" != "true" ]; then
    return 0
  fi

  POD_NAME="$(wait_for_traffic_pod_name)"
  kubectl wait -n "$NAMESPACE" --for=condition=PodScheduled "pod/$POD_NAME" --timeout="${POD_READY_TIMEOUT_SECONDS}s"

  if ! pod_has_istio_proxy "$POD_NAME"; then
    echo "ERROR: traffic Pod $POD_NAME was created without the istio-proxy sidecar" >&2
    echo "This would make STRICT mTLS reset synthetic canary traffic and cause Argo Rollouts to see canary-request-rate=0." >&2
    kubectl -n "$NAMESPACE" get pod "$POD_NAME" -o wide >&2 || true
    kubectl -n "$NAMESPACE" describe pod "$POD_NAME" >&2 || true
    return 1
  fi

  kubectl wait -n "$NAMESPACE" --for=condition=Ready "pod/$POD_NAME" --timeout="${POD_READY_TIMEOUT_SECONDS}s"

  FIRST_SERVICE="$(printf '%s\n' "$TARGET_SERVICES" | head -n 1)"
  if [ -n "$FIRST_SERVICE" ]; then
    STATUS_CODE="$(kubectl -n "$NAMESPACE" exec "$POD_NAME" -c traffic -- sh -c "curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 2 --max-time 5 http://$FIRST_SERVICE.$NAMESPACE.svc.cluster.local/api/v1/health" 2>/dev/null || printf '000')"
    case "$STATUS_CODE" in
      000|5*)
        echo "ERROR: traffic Pod $POD_NAME cannot reach $FIRST_SERVICE through the mesh (status=$STATUS_CODE)" >&2
        kubectl -n "$NAMESPACE" logs "$POD_NAME" --tail=40 >&2 || true
        return 1
        ;;
    esac
  fi
}

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

wait_for_mesh_dependencies

echo "Starting production canary traffic job"
echo "  Namespace: $NAMESPACE"
echo "  Job:       $JOB_NAME"
echo "  Duration:  ${DURATION_SECONDS}s"
echo "  Interval:  ${INTERVAL_SECONDS}s"
echo "  Mode:      $MODE"
echo "  Services:  $(printf '%s\n' "$TARGET_SERVICES" | wc -l | tr -d ' ')"

apply_traffic_job() {
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
              paths_for_service() {
                case "\$TARGET_PATHS" in
                  "__service_safe_defaults__")
                    case "\$1" in
                      frontend-service|frontend-service-canary|nginx-gateway|nginx-gateway-canary)
                        printf '%s\n' /
                        ;;
                      *)
                        printf '%s\n' /api/v1/health
                        ;;
                    esac
                    ;;
                  *)
                    printf '%s\n' "\$TARGET_PATHS"
                    ;;
                esac
              }
              if [ "\$TARGET_PATHS" = "__service_safe_defaults__" ]; then
                echo "Paths: service-specific safe defaults"
              else
                echo "Paths:"
                printf '%s\n' "\$TARGET_PATHS"
              fi
              while [ "\$(date +%s)" -lt "\$END_TIME" ]; do
                for SERVICE in \$TARGET_SERVICES; do
                  for PATH_VALUE in \$(paths_for_service "\$SERVICE"); do
                    URL="http://\$SERVICE.\$NAMESPACE.svc.cluster.local\$PATH_VALUE"
                    CODE="\$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 2 --max-time 5 "\$URL")" || CODE="000"
                    TOTAL="\$((TOTAL + 1))"
                    case "\$CODE" in
                      000|4*|5*) FAILURES="\$((FAILURES + 1))" ;;
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
}

ATTEMPT=1
while [ "$ATTEMPT" -le "$INJECTION_ATTEMPTS" ]; do
  if [ "$ATTEMPT" -gt 1 ]; then
    echo "Retrying production canary traffic Job after failed sidecar/connectivity verification (attempt $ATTEMPT/$INJECTION_ATTEMPTS)"
    kubectl -n "$NAMESPACE" delete job "$JOB_NAME" --ignore-not-found=true --wait=true >/dev/null 2>&1 || true
    wait_for_mesh_dependencies
  fi

  apply_traffic_job
  if verify_traffic_pod; then
    break
  fi

  if [ "$ATTEMPT" -ge "$INJECTION_ATTEMPTS" ]; then
    kubectl -n "$NAMESPACE" delete job "$JOB_NAME" --ignore-not-found=true --wait=false >/dev/null 2>&1 || true
    echo "ERROR: traffic Job failed sidecar/connectivity verification after $INJECTION_ATTEMPTS attempts" >&2
    exit 1
  fi

  ATTEMPT=$((ATTEMPT + 1))
done

kubectl -n "$NAMESPACE" get job "$JOB_NAME" -o wide
kubectl -n "$NAMESPACE" get pods -l "job-name=$JOB_NAME" -o wide
echo "Production canary traffic job started: $JOB_NAME"