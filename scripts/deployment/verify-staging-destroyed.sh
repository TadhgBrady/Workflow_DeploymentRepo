#!/bin/sh
set -eu

REGION="${AWS_DEFAULT_REGION:-eu-west-1}"
CLUSTER_NAME="${STAGING_CLUSTER_NAME:-yr4-project-staging-eks}"
STATE_BUCKET="${TF_BOOTSTRAP_STATE_BUCKET:-yr4-project-tf-state}"
LOCK_TABLE="${TF_BOOTSTRAP_LOCK_TABLE:-yr4-project-terraform-locks}"
PROJECT_NAME="${PROJECT_NAME:-yr4-project}"
ENVIRONMENT="${STAGING_ENVIRONMENT_NAME:-staging}"

FAILED=0

fail_resource() {
  echo "❌ $1"
  FAILED=$((FAILED + 1))
}

pass_check() {
  echo "✅ $1"
}

text_or_empty() {
  awk 'NF { print }'
}

echo "═══════════════════════════════════════════════════════════════"
echo "  Verifying STAGING infrastructure is destroyed"
echo "═══════════════════════════════════════════════════════════════"

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "")

echo "── EKS ──"
if aws eks describe-cluster --name "$CLUSTER_NAME" --region "$REGION" >/dev/null 2>&1; then
  fail_resource "EKS cluster still exists: $CLUSTER_NAME"
else
  pass_check "EKS cluster is gone: $CLUSTER_NAME"
fi

echo "── Tagged VPCs / NAT Gateways ──"
VPC_IDS=$(aws ec2 describe-vpcs --region "$REGION" \
  --filters "Name=tag:Project,Values=$PROJECT_NAME" "Name=tag:Environment,Values=$ENVIRONMENT" \
  --query 'Vpcs[].VpcId' --output text 2>/dev/null | text_or_empty || true)
if [ -n "$VPC_IDS" ]; then
  fail_resource "Staging VPC(s) still exist: $VPC_IDS"
  for VPC_ID in $VPC_IDS; do
    echo "  Remaining ELBv2 in $VPC_ID:"
    aws elbv2 describe-load-balancers --region "$REGION" \
      --query "LoadBalancers[?VpcId=='$VPC_ID'].{Name:LoadBalancerName,Type:Type,State:State.Code}" \
      --output table 2>/dev/null || true
    echo "  Remaining Classic ELB in $VPC_ID:"
    aws elb describe-load-balancers --region "$REGION" \
      --query "LoadBalancerDescriptions[?VPCId=='$VPC_ID'].{Name:LoadBalancerName,Scheme:Scheme}" \
      --output table 2>/dev/null || true
  done
else
  pass_check "No tagged staging VPCs remain"
fi

NAT_IDS=$(aws ec2 describe-nat-gateways --region "$REGION" \
  --filter "Name=tag:Project,Values=$PROJECT_NAME" "Name=tag:Environment,Values=$ENVIRONMENT" "Name=state,Values=pending,available" \
  --query 'NatGateways[].NatGatewayId' --output text 2>/dev/null | text_or_empty || true)
if [ -n "$NAT_IDS" ]; then
  fail_resource "Staging NAT gateway(s) still active: $NAT_IDS"
else
  pass_check "No active tagged staging NAT gateways remain"
fi

echo "── RDS / ElastiCache ──"
RDS_IDS=$(aws rds describe-db-instances --region "$REGION" \
  --query "DBInstances[?contains(DBInstanceIdentifier, '$PROJECT_NAME-$ENVIRONMENT')].DBInstanceIdentifier" \
  --output text 2>/dev/null | text_or_empty || true)
if [ -n "$RDS_IDS" ]; then
  fail_resource "Staging RDS instance(s) still exist: $RDS_IDS"
else
  pass_check "No staging RDS instances remain"
fi

REDIS_IDS=$(aws elasticache describe-replication-groups --region "$REGION" \
  --query "ReplicationGroups[?contains(ReplicationGroupId, '$PROJECT_NAME-$ENVIRONMENT')].ReplicationGroupId" \
  --output text 2>/dev/null | text_or_empty || true)
if [ -n "$REDIS_IDS" ]; then
  fail_resource "Staging ElastiCache replication group(s) still exist: $REDIS_IDS"
else
  pass_check "No staging ElastiCache replication groups remain"
fi

echo "── Loki S3 bucket ──"
LOKI_BUCKETS=""
if [ -n "$ACCOUNT_ID" ]; then
  EXPECTED_LOKI_BUCKET="$PROJECT_NAME-$ENVIRONMENT-loki-$ACCOUNT_ID"
  if aws s3api head-bucket --bucket "$EXPECTED_LOKI_BUCKET" 2>/dev/null; then
    LOKI_BUCKETS="$EXPECTED_LOKI_BUCKET"
  fi
fi
PREFIX_LOKI_BUCKETS=$(aws s3api list-buckets \
  --query "Buckets[?starts_with(Name, '$PROJECT_NAME-$ENVIRONMENT-loki-')].Name" \
  --output text 2>/dev/null | text_or_empty || true)
LOKI_BUCKETS=$(printf '%s\n%s\n' "$LOKI_BUCKETS" "$PREFIX_LOKI_BUCKETS" | awk 'NF && !seen[$0]++')
if [ -n "$LOKI_BUCKETS" ]; then
  fail_resource "Staging Loki bucket(s) still exist: $(printf '%s' "$LOKI_BUCKETS" | tr '\n' ' ')"
else
  pass_check "No staging Loki buckets remain"
fi

echo "── Terraform bootstrap resources ──"
if aws s3api head-bucket --bucket "$STATE_BUCKET" 2>/dev/null; then
  pass_check "Terraform state bucket still exists: $STATE_BUCKET"
else
  fail_resource "Terraform state bucket missing or inaccessible: $STATE_BUCKET"
fi

if aws dynamodb describe-table --table-name "$LOCK_TABLE" --region "$REGION" >/dev/null 2>&1; then
  pass_check "Terraform lock table still exists: $LOCK_TABLE"
else
  fail_resource "Terraform lock table missing or inaccessible: $LOCK_TABLE"
fi

if [ "$FAILED" -gt 0 ]; then
  echo ""
  echo "❌ Staging destroy verification failed with $FAILED issue(s)."
  exit 1
fi

echo ""
echo "✅ Staging destroy verified: cost resources removed and bootstrap preserved."
