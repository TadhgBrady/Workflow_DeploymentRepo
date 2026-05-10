#!/usr/bin/env sh
set -eu

BASE_URL="${1:-${STAGING_URL:-}}"
if [ -z "$BASE_URL" ]; then
  echo "STAGING_URL is required"
  exit 1
fi

E2E_DIR="${PLAYWRIGHT_E2E_DIR:-tests/e2e}"
PROJECT_ROOT="$(pwd)"
RESULTS_DIR="$PROJECT_ROOT/$E2E_DIR/test-results"
REPORT_DIR="$PROJECT_ROOT/$E2E_DIR/playwright-report"

if [ ! -f "$E2E_DIR/package.json" ]; then
  echo "Playwright package not found: $E2E_DIR/package.json"
  exit 1
fi

mkdir -p "$RESULTS_DIR" "$REPORT_DIR"

cat > "$RESULTS_DIR/metadata.json" <<EOF
{
  "test_id": "playwright-${CI_PIPELINE_ID:-local}-${CI_JOB_ID:-local}",
  "environment": "staging",
  "target_url": "$BASE_URL",
  "image_version": "${IMAGE_VERSION:-unknown}",
  "pipeline_id": "${CI_PIPELINE_ID:-local}",
  "job_id": "${CI_JOB_ID:-local}",
  "commit_sha": "${CI_COMMIT_SHA:-unknown}"
}
EOF

echo "================================================================"
echo "  Playwright staging E2E"
echo "================================================================"
echo "Target URL:      $BASE_URL"
echo "E2E directory:   $E2E_DIR"
echo "Results:         $RESULTS_DIR"
echo "HTML report:     $REPORT_DIR"

cd "$E2E_DIR"
npm ci
TEST_EXIT=0
STAGING_URL="$BASE_URL" PLAYWRIGHT_ENVIRONMENT="staging" npm run test:staging || TEST_EXIT=$?

if [ "$TEST_EXIT" -eq 0 ]; then
  TEST_STATUS="passed"
else
  TEST_STATUS="failed"
fi

cat > "$RESULTS_DIR/summary.md" <<EOF
# Playwright Staging E2E

Status: $TEST_STATUS
Test ID: playwright-${CI_PIPELINE_ID:-local}-${CI_JOB_ID:-local}
Target URL: $BASE_URL
Image version: ${IMAGE_VERSION:-unknown}
JUnit: test-results/playwright-junit.xml
JSON: test-results/playwright-results.json
HTML report: playwright-report/index.html
EOF

exit "$TEST_EXIT"