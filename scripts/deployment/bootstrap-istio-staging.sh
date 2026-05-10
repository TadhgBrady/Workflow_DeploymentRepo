#!/bin/sh
set -eu

STAGING_NAMESPACE="${STAGING_NAMESPACE:-year4-project-staging}"
exec sh scripts/deployment/bootstrap-istio.sh staging "$STAGING_NAMESPACE"