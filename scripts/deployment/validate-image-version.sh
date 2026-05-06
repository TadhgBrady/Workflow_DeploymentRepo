#!/bin/sh
set -eu

fail() {
  echo "ERROR: $1" >&2
  exit 1
}

require_var() {
  name="$1"
  value="$(eval "printf '%s' \"\${$name:-}\"")"
  [ -n "$value" ] || fail "$name is required"

  case "$value" in
    *'$'*) fail "$name contains an unexpanded CI variable marker: $value" ;;
    *[[:space:]]*) fail "$name contains whitespace: $value" ;;
  esac
}

require_var IMAGE_TAG
require_var IMAGE_VERSION
require_var SOURCE_COMMIT

case "$IMAGE_VERSION" in
  *[!0-9a-fA-F]*) fail "IMAGE_VERSION must be a git SHA fragment, got: $IMAGE_VERSION" ;;
esac

version_length=${#IMAGE_VERSION}
if [ "$version_length" -lt 7 ] || [ "$version_length" -gt 40 ]; then
  fail "IMAGE_VERSION must be 7-40 hex characters, got ${version_length}: $IMAGE_VERSION"
fi

case "$SOURCE_COMMIT" in
  *[!0-9a-fA-F]*) fail "SOURCE_COMMIT must be a git SHA, got: $SOURCE_COMMIT" ;;
esac

source_length=${#SOURCE_COMMIT}
if [ "$source_length" -lt 7 ] || [ "$source_length" -gt 40 ]; then
  fail "SOURCE_COMMIT must be 7-40 hex characters, got ${source_length}: $SOURCE_COMMIT"
fi

echo "Image metadata is valid: IMAGE_TAG=$IMAGE_TAG IMAGE_VERSION=$IMAGE_VERSION SOURCE_COMMIT=$SOURCE_COMMIT"
