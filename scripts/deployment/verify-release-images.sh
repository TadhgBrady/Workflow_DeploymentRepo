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
AUTH_SOURCE="unauthenticated"

IMAGE_REGISTRY="${IMAGE_TAG%%/*}"
case "$IMAGE_REGISTRY" in
  *.*|*:*|localhost) ;;
  *) IMAGE_REGISTRY="docker.io" ;;
esac

DOCKERHUB_LOGIN_USER="${DOCKERHUB_USER:-${DOCKERHUB_USERNAME:-}}"
if [ "$IMAGE_REGISTRY" = "docker.io" ]; then
  if [ -n "$DOCKERHUB_LOGIN_USER" ] && [ -n "${DOCKERHUB_TOKEN:-}" ]; then
    SKOPEO_CREDS="${DOCKERHUB_LOGIN_USER}:${DOCKERHUB_TOKEN}"
    AUTH_SOURCE="Docker Hub credentials"
  fi
elif [ -n "${CI_REGISTRY:-}" ] && [ "$IMAGE_REGISTRY" = "$CI_REGISTRY" ] && [ -n "${CI_REGISTRY_USER:-}" ] && [ -n "${CI_REGISTRY_PASSWORD:-}" ]; then
  SKOPEO_CREDS="${CI_REGISTRY_USER}:${CI_REGISTRY_PASSWORD}"
  AUTH_SOURCE="GitLab registry credentials"
fi

echo "  Registry: ${IMAGE_REGISTRY}"
echo "  Auth: ${AUTH_SOURCE}"

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT HUP INT TERM

export IMAGE_TAG IMAGE_VERSION SKOPEO_CREDS TMP_DIR
VERIFY_IMAGE_PARALLELISM="${VERIFY_IMAGE_PARALLELISM:-4}"

printf '%s\n' $SERVICES | xargs -P "$VERIFY_IMAGE_PARALLELISM" -I {} sh -c '
  SERVICE="$1"
  REF="docker://${IMAGE_TAG}:${SERVICE}-${IMAGE_VERSION}"
  LOG_FILE="$TMP_DIR/${SERVICE}.log"
  FAIL_FILE="$TMP_DIR/${SERVICE}.fail"
  AUTH_LOG_FILE="$TMP_DIR/${SERVICE}.auth.log"
  PUBLIC_LOG_FILE="$TMP_DIR/${SERVICE}.public.log"

  {
    echo "  Inspecting ${IMAGE_TAG}:${SERVICE}-${IMAGE_VERSION}"
    if [ -n "$SKOPEO_CREDS" ]; then
      if skopeo inspect --creds "$SKOPEO_CREDS" "$REF" >"$AUTH_LOG_FILE" 2>&1; then
        echo "    ✅ found"
      else
        echo "    ⚠️  authenticated inspect failed; retrying without credentials"
        if skopeo inspect "$REF" >"$PUBLIC_LOG_FILE" 2>&1; then
          echo "    ✅ found without credentials"
        else
          echo "    ❌ missing or inaccessible"
          echo "       authenticated inspect output:"
          sed "s/^/         /" "$AUTH_LOG_FILE" || true
          echo "       unauthenticated inspect output:"
          sed "s/^/         /" "$PUBLIC_LOG_FILE" || true
          echo "$SERVICE" > "$FAIL_FILE"
        fi
      fi
    else
      if skopeo inspect "$REF" >"$PUBLIC_LOG_FILE" 2>&1; then
        echo "    ✅ found"
      else
        echo "    ❌ missing or inaccessible"
        sed "s/^/       /" "$PUBLIC_LOG_FILE" || true
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
