# Playwright Staging E2E

Browser-based E2E tests for the deployed staging environment. These tests run after the k6 staging load gate and validate user-visible workflows through the real frontend. The CI job is a mandatory staging release gate: a Playwright failure blocks `staging-release-gate` and production promotion.

## Local kind run

From the deployment repo root, start the staging-parity kind stack:

```powershell
.\local\setup.ps1 -BuildLocal -DevRepo "..\yr4-projectdevelopmentrepo"
```

The local app is exposed through the kind NodePort at `http://localhost:30080`.

Run the browser suite against kind:

```powershell
Set-Location .\tests\e2e
npm ci
npx playwright install chromium
$env:STAGING_URL="http://localhost:30080"
$env:PLAYWRIGHT_ENVIRONMENT="kind-local"
npm run test:staging
```

Clean up when finished:

```powershell
Set-Location ..\..
.\local\teardown.ps1
```

## Staging run

```bash
cd tests/e2e
npm ci
STAGING_URL=http://your-staging-load-balancer npm run test:staging
```

## Coverage

- Login, invalid login, and logout through the UI.
- Calendar HTMX navigation across month, week, and day views.
- Job creation from the calendar modal, including inline customer creation.
- Role-based access checks for employee and superadmin users.

API calls are used only for setup and cleanup. The user journeys themselves are driven through Chromium.

## Artifacts

The GitLab job keeps these for debugging and release evidence:

- `playwright-report/`
- `test-results/playwright-junit.xml`
- `test-results/playwright-results.json`
- `test-results/metadata.json`
- `test-results/summary.md`
- screenshots, videos, and traces on failure

GitLab reads the JUnit file into the pipeline Tests tab. Download `playwright-report/index.html` from the job artifact for the browser timeline, DOM snapshots, traces, screenshots, and videos. The downstream `staging-release-gate` job republishes the Playwright artifact paths alongside the k6 test ID so the passing release has one evidence bundle.