#!/bin/sh
set -eu

BASE_URL="${1:?base URL is required}"
ENV_LABEL="${2:-environment}"
WARMUP_ATTEMPTS="${WARMUP_ATTEMPTS:-18}"

if [ -z "$BASE_URL" ]; then
  echo "❌ ${ENV_LABEL} URL is empty — LoadBalancer hostname not provisioned"
  exit 1
fi

echo "  Waiting for ${ENV_LABEL} LoadBalancer to become reachable..."
WARMUP_DONE=0
for i in $(seq 1 "$WARMUP_ATTEMPTS"); do
  WARMUP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "${BASE_URL}/health" 2>/dev/null) || true
  if [ -n "$WARMUP_CODE" ] && [ "$WARMUP_CODE" != "000" ]; then
    echo "  ✅ LoadBalancer reachable (HTTP $WARMUP_CODE) after $((i * 10))s"
    WARMUP_DONE=1
    break
  fi
  echo "  Attempt $i/$WARMUP_ATTEMPTS — not reachable yet (code: ${WARMUP_CODE:-000}), retrying in 10s..."
  sleep 10
done

if [ "$WARMUP_DONE" -eq 0 ]; then
  echo "❌ LoadBalancer did not become reachable within $((WARMUP_ATTEMPTS * 10))s"
  echo "  URL: ${BASE_URL}/health"
  exit 1
fi

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT HUP INT TERM

check_url() {
  NAME="$1"
  URL="$2"
  EXPECTED="$3"

  echo -n "  Checking $NAME... "
  HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 15 "$URL" 2>/dev/null) || true
  HTTP_CODE="${HTTP_CODE:-000}"

  OLDIFS=$IFS
  IFS=','
  for CODE in $EXPECTED; do
    if [ "$HTTP_CODE" = "$CODE" ]; then
      IFS=$OLDIFS
      echo "✅ ($HTTP_CODE)"
      return 0
    fi
  done
  IFS=$OLDIFS

  echo "❌ ($HTTP_CODE), expected: $EXPECTED"
  return 1
}

run_check() {
  NAME="$1"
  PATH_SUFFIX="$2"
  EXPECTED="$3"
  LOG_FILE="$TMP_DIR/${NAME}.log"
  STATUS_FILE="$TMP_DIR/${NAME}.status"

  (
    if check_url "$NAME" "${BASE_URL}${PATH_SUFFIX}" "$EXPECTED" > "$LOG_FILE" 2>&1; then
      echo 0 > "$STATUS_FILE"
    else
      echo 1 > "$STATUS_FILE"
    fi
  ) &
}

# NGINX gateway exposes /health and route prefixes (/api/v1/*), not
# /api/{service}/health. Probe stable public endpoints to avoid false negatives.
run_check "gateway-health" "/health" "200"
run_check "frontend-root" "/" "200,301,302"
run_check "auth-login-endpoint" "/api/v1/auth/login" "200,400,401,405,422"
run_check "users-route-prefix" "/api/v1/users" "200,401,405"
run_check "jobs-route-prefix" "/api/v1/jobs" "200,401,405"
run_check "customers-route-prefix" "/api/v1/customers" "200,401,405"
run_check "admin-organizations-endpoint" "/api/v1/admin/organizations" "200,401,403,405"

wait

FAILED=0
for LOG_FILE in "$TMP_DIR"/*.log; do
  cat "$LOG_FILE"
done
for STATUS_FILE in "$TMP_DIR"/*.status; do
  STATUS=$(cat "$STATUS_FILE")
  if [ "$STATUS" -ne 0 ]; then
    FAILED=$((FAILED + 1))
  fi
done

echo ""
if [ "$FAILED" -gt 0 ]; then
  echo "❌ $FAILED service(s) failed health check in ${ENV_LABEL}"
  exit 1
fi

echo "✅ All ${ENV_LABEL} services healthy"
