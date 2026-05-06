#!/bin/sh
set -eu

STORE_MANIFEST="${1:-kubernetes/base/external-secrets.yaml}"
STORE_NAME="${2:-aws-secrets-manager}"
TIMEOUT="${EXTERNAL_SECRET_STORE_TIMEOUT:-120s}"
OPERATOR_TIMEOUT="${EXTERNAL_SECRETS_OPERATOR_TIMEOUT:-180s}"

if ! kubectl get crd clustersecretstores.external-secrets.io >/dev/null 2>&1; then
  echo "❌ External Secrets ClusterSecretStore CRD is not installed"
  echo "   Install the External Secrets Operator before applying ${STORE_MANIFEST}."
  exit 1
fi

kubectl wait --for=condition=Established crd/clustersecretstores.external-secrets.io --timeout=60s

if ! kubectl wait --for=condition=Available deployment/external-secrets -n external-secrets --timeout="$OPERATOR_TIMEOUT"; then
  echo "❌ External Secrets Operator deployment is not Available within ${OPERATOR_TIMEOUT}"
  kubectl get pods -n external-secrets -o wide || true
  kubectl describe deployment external-secrets -n external-secrets || true
  exit 1
fi

if [ ! -f "$STORE_MANIFEST" ]; then
  echo "❌ ClusterSecretStore manifest not found: ${STORE_MANIFEST}"
  exit 1
fi

echo "--- Ensuring External Secrets ClusterSecretStore/${STORE_NAME} ---"
kubectl apply -f "$STORE_MANIFEST"

if kubectl wait --for=condition=Ready=True "clustersecretstore/${STORE_NAME}" --timeout="$TIMEOUT"; then
  echo "✅ ClusterSecretStore/${STORE_NAME} is ready"
  exit 0
fi

echo "❌ ClusterSecretStore/${STORE_NAME} did not become Ready within ${TIMEOUT}"
echo "── ClusterSecretStore status ──"
kubectl describe "clustersecretstore/${STORE_NAME}" || true
echo "── External Secrets Operator pods ──"
kubectl get pods -n external-secrets -o wide || true
echo "── External Secrets Operator service account ──"
kubectl describe serviceaccount external-secrets-sa -n external-secrets || true
exit 1
