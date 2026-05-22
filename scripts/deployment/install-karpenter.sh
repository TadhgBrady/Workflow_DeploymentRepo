#!/bin/sh
set -eu

CLUSTER_NAME="${1:?usage: install-karpenter.sh <cluster-name> <staging|production>}"
ENVIRONMENT="${2:?usage: install-karpenter.sh <cluster-name> <staging|production>}"

KARPENTER_NAMESPACE="${KARPENTER_NAMESPACE:-karpenter}"
KARPENTER_VERSION="${KARPENTER_VERSION:-1.6.0}"
KARPENTER_RELEASE="${KARPENTER_RELEASE:-karpenter}"
KARPENTER_ROLE_NAME="${KARPENTER_CONTROLLER_ROLE_NAME:-yr4-project-${ENVIRONMENT}-karpenter-controller-role}"
KARPENTER_NODE_INSTANCE_PROFILE="${KARPENTER_NODE_INSTANCE_PROFILE:-yr4-project-${ENVIRONMENT}-eks-node-instance-profile}"
KARPENTER_MANIFEST_PATH="${KARPENTER_MANIFEST_PATH:-kubernetes/autoscaling/karpenter/${ENVIRONMENT}}"

retry_cmd() {
  ATTEMPTS="$1"
  DELAY="$2"
  shift 2
  TRY=1
  until "$@"; do
    if [ "$TRY" -ge "$ATTEMPTS" ]; then
      echo "ERROR: command failed after ${ATTEMPTS} attempts: $*"
      return 1
    fi
    echo "WARN: command failed (attempt ${TRY}/${ATTEMPTS}): $*"
    sleep "$DELAY"
    TRY=$((TRY + 1))
  done
}

echo "Installing Karpenter ${KARPENTER_VERSION} for ${ENVIRONMENT} (${CLUSTER_NAME})"

KARPENTER_ROLE_ARN=$(aws iam get-role \
  --role-name "$KARPENTER_ROLE_NAME" \
  --query 'Role.Arn' --output text)
echo "Karpenter controller role: $KARPENTER_ROLE_ARN"

aws iam get-instance-profile \
  --instance-profile-name "$KARPENTER_NODE_INSTANCE_PROFILE" \
  --query 'InstanceProfile.InstanceProfileName' --output text >/dev/null
echo "Karpenter node instance profile: $KARPENTER_NODE_INSTANCE_PROFILE"

kubectl create namespace "$KARPENTER_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

if kubectl -n kube-system get deployment coredns >/dev/null 2>&1; then
  kubectl -n kube-system patch deployment coredns \
    --type=json \
    -p='[{"op":"remove","path":"/spec/template/metadata/annotations/eks.amazonaws.com~1compute-type"}]' \
    2>/dev/null || true
  kubectl -n kube-system rollout restart deployment/coredns
fi

retry_cmd 6 20 helm upgrade --install "$KARPENTER_RELEASE" \
  oci://public.ecr.aws/karpenter/karpenter \
  --version "$KARPENTER_VERSION" \
  --namespace "$KARPENTER_NAMESPACE" --create-namespace \
  --set "settings.clusterName=$CLUSTER_NAME" \
  --set "settings.interruptionQueue=$CLUSTER_NAME" \
  --set "serviceAccount.annotations.eks\.amazonaws\.com/role-arn=$KARPENTER_ROLE_ARN" \
  --set "controller.resources.requests.cpu=100m" \
  --set "controller.resources.requests.memory=256Mi" \
  --set "controller.resources.limits.cpu=500m" \
  --set "controller.resources.limits.memory=512Mi" \
  --wait --timeout 300s

kubectl rollout status deployment/$KARPENTER_RELEASE -n "$KARPENTER_NAMESPACE" --timeout=300s
retry_cmd 20 10 kubectl get crd nodepools.karpenter.sh
retry_cmd 20 10 kubectl get crd ec2nodeclasses.karpenter.k8s.aws

kubectl apply -k "$KARPENTER_MANIFEST_PATH"
kubectl get nodepools.karpenter.sh
kubectl get ec2nodeclasses.karpenter.k8s.aws

echo "Karpenter installed and configured for ${ENVIRONMENT}"