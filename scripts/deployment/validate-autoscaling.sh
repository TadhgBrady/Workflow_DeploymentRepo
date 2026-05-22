#!/usr/bin/env sh
set -eu

ENVIRONMENT="${1:?usage: validate-autoscaling.sh <staging|production>}"
OVERLAY_PATH="kubernetes/overlays/${ENVIRONMENT}"

fail() {
  echo "FAIL autoscaling validation: $1" >&2
  exit 1
}

count_pattern() {
  printf '%s\n' "$RENDERED" | grep -Ec "$1" || true
}

RENDERED="$(kubectl kustomize "$OVERLAY_PATH")"

HPA_COUNT="$(count_pattern '^kind:[[:space:]]*HorizontalPodAutoscaler$')"
CPU_METRIC_COUNT="$(count_pattern '^[[:space:]]*name:[[:space:]]*cpu$')"
MEMORY_METRIC_COUNT="$(count_pattern '^[[:space:]]*name:[[:space:]]*memory$')"
PDB_COUNT="$(count_pattern '^kind:[[:space:]]*PodDisruptionBudget$')"
PRIORITY_CLASS_COUNT="$(count_pattern '^kind:[[:space:]]*PriorityClass$')"
PRIORITY_ASSIGNMENT_COUNT="$(count_pattern '^[[:space:]]*priorityClassName:[[:space:]]*year4-')"
TOPOLOGY_COUNT="$(count_pattern '^[[:space:]]*topologySpreadConstraints:$')"

if [ "$ENVIRONMENT" = "production" ]; then
  WORKLOAD_COUNT="$(count_pattern '^kind:[[:space:]]*Rollout$')"
  EXPECTED_PDB_COUNT="$WORKLOAD_COUNT"
  EXPECTED_TOPOLOGY_COUNT="$WORKLOAD_COUNT"
else
  WORKLOAD_COUNT="$(count_pattern '^kind:[[:space:]]*Deployment$')"
  EXPECTED_PDB_COUNT=4
  EXPECTED_TOPOLOGY_COUNT=4
fi

[ "$WORKLOAD_COUNT" -gt 0 ] || fail "no workloads rendered for ${ENVIRONMENT}"
[ "$HPA_COUNT" -eq "$WORKLOAD_COUNT" ] || fail "expected ${WORKLOAD_COUNT} HPAs, found ${HPA_COUNT}"
[ "$CPU_METRIC_COUNT" -eq "$HPA_COUNT" ] || fail "expected CPU metric on every HPA (${HPA_COUNT}), found ${CPU_METRIC_COUNT}"
[ "$MEMORY_METRIC_COUNT" -eq "$HPA_COUNT" ] || fail "expected memory metric on every HPA (${HPA_COUNT}), found ${MEMORY_METRIC_COUNT}"
[ "$PRIORITY_CLASS_COUNT" -ge 6 ] || fail "expected shared PriorityClasses, found ${PRIORITY_CLASS_COUNT}"
[ "$PRIORITY_ASSIGNMENT_COUNT" -eq "$WORKLOAD_COUNT" ] || fail "expected priorityClassName on every workload (${WORKLOAD_COUNT}), found ${PRIORITY_ASSIGNMENT_COUNT}"
[ "$PDB_COUNT" -ge "$EXPECTED_PDB_COUNT" ] || fail "expected at least ${EXPECTED_PDB_COUNT} PDBs, found ${PDB_COUNT}"
[ "$TOPOLOGY_COUNT" -ge "$EXPECTED_TOPOLOGY_COUNT" ] || fail "expected at least ${EXPECTED_TOPOLOGY_COUNT} topology spread constraints, found ${TOPOLOGY_COUNT}"

echo "PASS autoscaling validation for ${ENVIRONMENT}: ${HPA_COUNT} HPAs, ${PDB_COUNT} PDBs, ${PRIORITY_ASSIGNMENT_COUNT} priority assignments"