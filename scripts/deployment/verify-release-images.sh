#!/bin/sh
set -eu

IMAGE_TAG="${IMAGE_TAG:?IMAGE_TAG is required}"
IMAGE_VERSION="${IMAGE_VERSION:?IMAGE_VERSION is required}"
SERVICES="${RELEASE_IMAGE_SERVICES:-nginx auth-service user-bl-service user-db-access-service job-bl-service job-db-access-service customer-bl-service customer-db-access-service admin-bl-service maps-access-service notification-service frontend migration-runner}"

if printf '%s' "$IMAGE_TAG$IMAGE_VERSION" | grep -q '\$'; then
  echo "❌ Image metadata contains an unexpanded CI variable"
  echo "   IMAGE_TAG=$IMAGE_TAG"
  echo "   IMAGE_VERSION=$IMAGE_VERSION"
  exit 1
fi

echo "Verifying release images exist before deployment..."
SKOPEO_CREDS=""
if [ -n "${CI_REGISTRY_USER:-}" ] && [ -n "${CI_REGISTRY_PASSWORD:-}" ]; then
  SKOPEO_CREDS="${CI_REGISTRY_USER}:${CI_REGISTRY_PASSWORD}"
elif [ -n "${DOCKERHUB_USERNAME:-}" ] && [ -n "${DOCKERHUB_TOKEN:-}" ]; then
  SKOPEO_CREDS="${DOCKERHUB_USERNAME}:${DOCKERHUB_TOKEN}"
fi

FAILED=""
for SERVICE in $SERVICES; do
  REF="docker://${IMAGE_TAG}:${SERVICE}-${IMAGE_VERSION}"
  echo "  Inspecting ${IMAGE_TAG}:${SERVICE}-${IMAGE_VERSION}"
  if [ -n "$SKOPEO_CREDS" ]; then
    INSPECT_OUTPUT=$(skopeo inspect --creds "$SKOPEO_CREDS" "$REF" 2>&1) || INSPECT_EXIT=$?
  else
    INSPECT_OUTPUT=$(skopeo inspect "$REF" 2>&1) || INSPECT_EXIT=$?
  fi
  if [ "${INSPECT_EXIT:-0}" -eq 0 ]; then
    echo "    ✅ found"
  else
    echo "    ❌ missing or inaccessible"
    echo "       ${INSPECT_OUTPUT:-inspect failed}"
    FAILED="$FAILED $SERVICE"
  fi
  unset INSPECT_EXIT INSPECT_OUTPUT
done

if [ -n "$FAILED" ]; then
  echo ""
  echo "❌ Missing release image(s):$FAILED"
  echo "   Check the dev repo build/push jobs before deploying."
  exit 1
fi

echo "✅ All release images are available"
