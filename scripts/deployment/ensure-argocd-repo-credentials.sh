#!/bin/sh
set -eu

ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-argocd}"
ARGOCD_REPO_SECRET="${ARGOCD_REPO_SECRET:-year4-project-deployment-repo}"
ARGOCD_REPO_URL="${ARGOCD_REPO_URL:-${CI_PROJECT_URL:-https://gitlab.comp.dkit.ie/finalproject/Prototypes/yr4-projectdeploymentrepo}.git}"

REPO_USERNAME="${ARGOCD_REPO_USERNAME:-}"
REPO_PASSWORD="${ARGOCD_REPO_PASSWORD:-}"
CREDENTIAL_SOURCE="ARGOCD_REPO_USERNAME/ARGOCD_REPO_PASSWORD"

if [ -z "$REPO_USERNAME" ] || [ -z "$REPO_PASSWORD" ]; then
  if [ -n "${CI_JOB_TOKEN:-}" ]; then
    REPO_USERNAME="gitlab-ci-token"
    REPO_PASSWORD="$CI_JOB_TOKEN"
    CREDENTIAL_SOURCE="CI_JOB_TOKEN"
  fi
fi

if [ -z "$REPO_USERNAME" ] || [ -z "$REPO_PASSWORD" ]; then
  echo "WARN: No Argo CD repository credentials available."
  echo "      Set ARGOCD_REPO_USERNAME/ARGOCD_REPO_PASSWORD for persistent auto-sync."
  echo "      Without credentials, Argo CD can sync only if $ARGOCD_REPO_URL is public."
  exit 0
fi

kubectl -n "$ARGOCD_NAMESPACE" create secret generic "$ARGOCD_REPO_SECRET" \
  --from-literal=type=git \
  --from-literal=url="$ARGOCD_REPO_URL" \
  --from-literal=username="$REPO_USERNAME" \
  --from-literal=password="$REPO_PASSWORD" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl -n "$ARGOCD_NAMESPACE" label secret "$ARGOCD_REPO_SECRET" \
  argocd.argoproj.io/secret-type=repository --overwrite >/dev/null

echo "Configured Argo CD repository credentials for $ARGOCD_REPO_URL using $CREDENTIAL_SOURCE"
if [ "$CREDENTIAL_SOURCE" = "CI_JOB_TOKEN" ]; then
  echo "WARN: CI_JOB_TOKEN is suitable for this pipeline sync only."
  echo "      For long-lived Argo CD auto-sync, configure ARGOCD_REPO_USERNAME/ARGOCD_REPO_PASSWORD."
fi