#!/bin/sh
set -eu

NAMESPACE="${1:?usage: run-migration-job.sh <namespace> <rendered-yaml> [timeout]}"
RENDERED_YAML="${2:?usage: run-migration-job.sh <namespace> <rendered-yaml> [timeout]}"
TIMEOUT="${3:-300s}"
JOB_NAME="migration-runner"

if [ ! -f "$RENDERED_YAML" ]; then
  echo "❌ Rendered manifest not found: $RENDERED_YAML"
  exit 1
fi

TMP_JOB="$(mktemp)"
trap 'rm -f "$TMP_JOB"' EXIT
awk '
  BEGIN { doc = ""; keep = 0 }
  /^---[[:space:]]*$/ {
    if (doc != "" && keep == 1) {
      printf "%s---\n", doc
    }
    doc = ""
    keep = 0
    next
  }
  {
    doc = doc $0 ORS
    if ($0 ~ /^kind:[[:space:]]*Job[[:space:]]*$/) {
      keep = 1
    }
  }
  END {
    if (doc != "" && keep == 1) {
      printf "%s", doc
    }
  }
' "$RENDERED_YAML" > "$TMP_JOB"

if [ ! -s "$TMP_JOB" ]; then
  echo "ℹ️  No Kubernetes Job resources found in rendered manifest; skipping migrations."
  exit 0
fi

echo "Running migration job before application rollout..."
kubectl delete job "$JOB_NAME" -n "$NAMESPACE" --ignore-not-found=true
kubectl apply -f "$TMP_JOB"

if kubectl wait --for=condition=complete "job/${JOB_NAME}" -n "$NAMESPACE" --timeout="$TIMEOUT"; then
  echo "✅ Migration job completed successfully"
  exit 0
fi

echo "❌ Migration job failed or timed out — diagnostics:"
kubectl get job "$JOB_NAME" -n "$NAMESPACE" -o wide || true
kubectl describe job "$JOB_NAME" -n "$NAMESPACE" || true
kubectl get pods -n "$NAMESPACE" -l "job-name=${JOB_NAME}" -o wide || true
kubectl logs -n "$NAMESPACE" -l "job-name=${JOB_NAME}" --tail=120 --all-containers 2>/dev/null || true
kubectl get events -n "$NAMESPACE" --sort-by=.lastTimestamp | tail -80 || true
exit 1
