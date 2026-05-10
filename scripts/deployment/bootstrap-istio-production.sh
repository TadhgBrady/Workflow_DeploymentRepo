#!/bin/sh
set -eu

PROD_NAMESPACE="${PROD_NAMESPACE:-year4-project}"
exec sh scripts/deployment/bootstrap-istio.sh production "$PROD_NAMESPACE"