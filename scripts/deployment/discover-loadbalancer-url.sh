#!/bin/sh
set -eu

SERVICE_NAME="${1:?usage: discover-loadbalancer-url.sh <service> <namespace> <env-var> <dotenv-file>}"
SERVICE_NAMESPACE="${2:?usage: discover-loadbalancer-url.sh <service> <namespace> <env-var> <dotenv-file>}"
ENV_VAR_NAME="${3:?usage: discover-loadbalancer-url.sh <service> <namespace> <env-var> <dotenv-file>}"
DOTENV_FILE="${4:?usage: discover-loadbalancer-url.sh <service> <namespace> <env-var> <dotenv-file>}"
ATTEMPTS="${LOADBALANCER_WAIT_ATTEMPTS:-60}"
DELAY_SECONDS="${LOADBALANCER_WAIT_DELAY_SECONDS:-10}"

echo "Waiting for LoadBalancer external hostname on $SERVICE_NAMESPACE/$SERVICE_NAME..."
HOST=""
IP=""

for i in $(seq 1 "$ATTEMPTS"); do
  HOST=$(kubectl get svc "$SERVICE_NAME" -n "$SERVICE_NAMESPACE" \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
  IP=$(kubectl get svc "$SERVICE_NAME" -n "$SERVICE_NAMESPACE" \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)

  if [ -n "$HOST" ]; then
    printf '%s=http://%s\n' "$ENV_VAR_NAME" "$HOST" > "$DOTENV_FILE"
    echo "SUCCESS: $ENV_VAR_NAME=http://$HOST"
    exit 0
  fi

  if [ -n "$IP" ]; then
    printf '%s=http://%s\n' "$ENV_VAR_NAME" "$IP" > "$DOTENV_FILE"
    echo "SUCCESS: $ENV_VAR_NAME=http://$IP"
    exit 0
  fi

  echo "  Attempt $i/$ATTEMPTS - waiting for LoadBalancer provisioning..."
  sleep "$DELAY_SECONDS"
done

echo "WARN: LoadBalancer hostname not available yet"
kubectl get svc "$SERVICE_NAME" -n "$SERVICE_NAMESPACE" -o wide || true
kubectl describe svc "$SERVICE_NAME" -n "$SERVICE_NAMESPACE" || true
printf '%s=\n' "$ENV_VAR_NAME" > "$DOTENV_FILE"