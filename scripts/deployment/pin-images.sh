#!/bin/sh
set -eu

IMAGE_VERSION="${1:-${IMAGE_VERSION:-}}"
shift 2>/dev/null || true

REPOSITORY="${IMAGE_REPOSITORY:-${IMAGE_TAG:-bencev04/4th-year-proj-tadgh-bence}}"

if [ -z "$IMAGE_VERSION" ] || [ "$IMAGE_VERSION" = "latest" ]; then
  echo "ℹ️  IMAGE_VERSION not set — deploying existing image tags"
  exit 0
fi

if printf '%s' "$IMAGE_VERSION" | grep -q '\$'; then
  echo "❌ IMAGE_VERSION contains a literal dollar sign: $IMAGE_VERSION"
  exit 1
fi

if ! printf '%s' "$IMAGE_VERSION" | grep -Eq '^[0-9a-f]{7,40}$'; then
  echo "❌ IMAGE_VERSION must be a git SHA-like value, got: $IMAGE_VERSION"
  exit 1
fi

if [ "$#" -eq 0 ]; then
  echo "❌ No manifest files passed to pin-images.sh"
  exit 1
fi

UPDATED_COUNT=0

for file in "$@"; do
  [ -f "$file" ] || continue

  if grep -q "$REPOSITORY:" "$file" 2>/dev/null; then
    before=$(grep -o "${REPOSITORY}:[A-Za-z0-9._-]*" "$file" | sort -u | tr '\n' ' ')

    # Make pinning idempotent: replace either service-latest or service-<sha>
    # with exactly service-${IMAGE_VERSION}.
    sed -i -E "s#(${REPOSITORY}:[a-z0-9-]+-)(latest|[0-9a-f]{7,40})#\\1${IMAGE_VERSION}#g" "$file"

    if ! grep -q "${REPOSITORY}:.*-${IMAGE_VERSION}" "$file"; then
      echo "❌ Image pinning did not update expected repository references in $file"
      echo "   Before: $before"
      echo "   After:  $(grep -o "${REPOSITORY}:[A-Za-z0-9._-]*" "$file" | sort -u | tr '\n' ' ')"
      exit 1
    fi

    after=$(grep -o "${REPOSITORY}:[A-Za-z0-9._-]*" "$file" | sort -u | tr '\n' ' ')
    echo "  ✅ $(basename "$file"): $after"
    UPDATED_COUNT=$((UPDATED_COUNT + 1))
  fi
done

if [ "$UPDATED_COUNT" -eq 0 ]; then
  echo "❌ No image references for $REPOSITORY were found in the provided files"
  exit 1
fi

printf '✅ Pinned %s manifest file(s) to image version %s\n' "$UPDATED_COUNT" "$IMAGE_VERSION"
