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

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT HUP INT TERM

export IMAGE_TAG IMAGE_VERSION SKOPEO_CREDS TMP_DIR
VERIFY_IMAGE_PARALLELISM="${VERIFY_IMAGE_PARALLELISM:-4}"

printf '%s\n' $SERVICES | xargs -P "$VERIFY_IMAGE_PARALLELISM" -I {} sh -c '
  SERVICE="$1"
  REF="docker://${IMAGE_TAG}:${SERVICE}-${IMAGE_VERSION}"
  LOG_FILE="$TMP_DIR/${SERVICE}.log"
  FAIL_FILE="$TMP_DIR/${SERVICE}.fail"

  {
    echo "  Inspecting ${IMAGE_TAG}:${SERVICE}-${IMAGE_VERSION}"
    if [ -n "$SKOPEO_CREDS" ]; then
      if skopeo inspect --creds "$SKOPEO_CREDS" "$REF" >/dev/null 2>&1; then
        echo "    ✅ found"
      else
        echo "    ❌ missing or inaccessible"
        skopeo inspect --creds "$SKOPEO_CREDS" "$REF" 2>&1 | sed "s/^/       /" || true
        echo "$SERVICE" > "$FAIL_FILE"
      fi
    else
      if skopeo inspect "$REF" >/dev/null 2>&1; then
        echo "    ✅ found"
      else
        echo "    ❌ missing or inaccessible"
        skopeo inspect "$REF" 2>&1 | sed "s/^/       /" || true
        echo "$SERVICE" > "$FAIL_FILE"
      fi
    fi
  } > "$LOG_FILE" 2>&1
' sh {}

for LOG_FILE in "$TMP_DIR"/*.log; do
  [ -e "$LOG_FILE" ] || continue
  cat "$LOG_FILE"
done

FAILED=""
for FAIL_FILE in "$TMP_DIR"/*.fail; do
  [ -e "$FAIL_FILE" ] || continue
  FAILED="$FAILED $(cat "$FAIL_FILE")"
done

if [ -n "$FAILED" ]; then
  echo ""
  echo "❌ Missing release image(s):$FAILED"
  echo "   Check the dev repo build/push jobs before deploying."
  exit 1
fi

echo "✅ All release images are available"
