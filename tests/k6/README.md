# k6 staging tests

This folder contains the staging k6 suites for release load gates and exploratory capacity checks. The mandatory pipeline gate is the medium real-user workflow: 10 authenticated virtual users spread across owner, employee, and manager journeys.

## Test files

- `real-user-workflows.js` — mandatory authenticated release gate for the `medium` profile, plus optional `hard` profile exploration. It exercises login-backed customer, job, calendar, status, scheduling, notes, team-read, queue-read, and conflict-check paths with temporary data cleanup.
- `baseline-exploration.js` — optional public-endpoint exploration suite. Use it manually when you want a quick comparison between public endpoint headroom and authenticated workflow headroom.
- `staging-smoke-load.js` — lightweight k6 smoke script retained for ad hoc checks. The shell `smoke-tests-staging` job remains the pipeline health check; this script is no longer the release load gate.

The public smoke and baseline scripts are non-destructive. The real workflow script creates only temporary `k6-*` customers/jobs/notes and deletes them at the end of each journey.

## Profiles

`baseline-exploration.js` supports these `K6_PROFILE` values:

| Profile | Purpose | Default shape |
| --- | --- | --- |
| `smoke` | Quick sanity run | health probe + endpoint sweep for 1 minute |
| `baseline` | Normal starting point | health probe, endpoint sweep, weighted browse mix for 5 minutes |
| `stress-lite` | Gentle ramp-up | baseline coverage plus ramping browse traffic |
| `spike-lite` | Small burst test | short burst to observe recovery and dashboard behavior |

`real-user-workflows.js` supports these `K6_PROFILE` values:

| Profile | Purpose | Default shape |
| --- | --- | --- |
| `medium` | Realistic logged-in daily use | owner customer/job workflow, employee job processing, manager read workflow at about 10 VUs |
| `hard` | Scheduling and contention pressure | manager scheduling, employee status updates, and expected conflict checks at about 24 VUs |

The GitLab pipeline runs `k6-load-staging` automatically with `real-user-workflows.js` and `K6_PROFILE=medium`. This job is mandatory and blocks `playwright-e2e-staging`, `staging-release-gate`, and production promotion when thresholds fail. The optional `k6-human-hard-staging` job remains manual and allowed to fail so scheduling/contention pressure can be explored without changing release policy.

The GitLab jobs still use the `K6_*` variables below for convenience. The Kubernetes runner maps those values to `LOAD_TEST_*` environment variables inside the k6 pod, because some `K6_*` names are reserved by k6 itself. If you run these scripts directly with `k6 run`, use `LOAD_TEST_DURATION`, `LOAD_TEST_MAX_VUS`, and the other `LOAD_TEST_*` names instead of exporting custom `K6_*` values.

## Useful tuning variables

| Variable | Default | Notes |
| --- | --- | --- |
| `K6_PROFILE` | `medium` for the mandatory gate | `medium`, `hard`; public exploration also supports `smoke`, `baseline`, `stress-lite`, `spike-lite` |
| `K6_DURATION` | `6m` for the mandatory gate | steady-state duration, after warmup and before cooldown |
| `K6_SWEEP_RATE` | `1` | full endpoint sweeps per second |
| `K6_BROWSE_RATE` | `2` | weighted single-endpoint browse requests per second |
| `K6_STRESS_RATE` | `5` | target browse rate for `stress-lite` |
| `K6_SPIKE_RATE` | `10` | burst browse rate for `spike-lite` |
| `K6_PRE_ALLOCATED_VUS` | `8` | preallocated virtual users |
| `K6_MAX_VUS` | `30` | maximum virtual users |
| `K6_LATENCY_P95_MS` | `1500` | exploratory p95 threshold |
| `K6_LATENCY_P99_MS` | `3000` | exploratory p99 threshold |
| `K6_FAILURE_RATE` | `0.02` | total failed request threshold |
| `K6_SERVER_ERROR_RATE` | `0.01` | HTTP 5xx threshold |
| `K6_CHECK_RATE` | `0.95` | check pass-rate threshold |
| `K6_MEDIUM_TARGET_VUS` | `10` | total target VUs for `real-user-workflows.js` medium profile |
| `K6_HARD_TARGET_VUS` | `24` | total target VUs for `real-user-workflows.js` hard profile |
| `K6_HARD_JOBS_PER_SESSION` | `2` | jobs each hard manager scheduling session creates and schedules |
| `K6_THINK_TIME_SECONDS` | `0.6` medium, `0.35` hard | base human pause between workflow actions |
| `K6_THINK_TIME_JITTER_SECONDS` | `0.4` medium, `0.25` hard | random extra human pause |
| `K6_WORKFLOW_SUCCESS_RATE` | `0.95` medium, `0.90` hard | full journey success threshold |
| `K6_CLEANUP_FAILURE_RATE` | `0.02` | cleanup failure threshold for temporary records |
| `K6_SCHEDULING_P95_MS` | `2500` medium, `4000` hard | scheduling action p95 threshold |
| `K6_CONFLICT_P95_MS` | `2500` medium, `4000` hard | conflict-check p95 threshold |
| `K6_AUTH_RECOVERY_ENABLED` | `true` | refresh access tokens before expiry and retry once after a 401 |
| `K6_AUTH_REFRESH_SKEW_SECONDS` | `60` | refresh access tokens this many seconds before expiry |
| `K6_AUTH_RETRY_DELAY_SECONDS` | `0.4` | jittered delay before token refresh or relogin recovery |

## Authenticated workflow credentials

The real workflow jobs default to the seeded staging emails:

| Role | Default email | Password variable |
| --- | --- | --- |
| Owner | `owner@demo.com` | `K6_OWNER_PASSWORD` or shared `K6_USER_PASSWORD` |
| Manager | `manager@demo.com` | `K6_MANAGER_PASSWORD` or shared `K6_USER_PASSWORD` |
| Employee | `employee@demo.com` | `K6_EMPLOYEE_PASSWORD` or shared `K6_USER_PASSWORD` |

The runner defaults to the seeded demo password `password123`, matching the staging fixture users. Set `K6_USER_PASSWORD` as a masked GitLab CI/CD variable if all seeded users share a different password. Use the role-specific password variables if staging uses different credentials. The runner stores these values in a short-lived Kubernetes Secret and deletes it after the k6 Job finishes.

The real workflow script stores each role's refresh token from `/api/v1/auth/login`, refreshes access tokens before expiry via `/api/v1/auth/refresh`, and retries once after a 401. This keeps long medium/hard runs focused on workflow capacity instead of accidental JWT expiry.

Every k6 GitLab job uploads a `k6-results/` artifact containing the Kubernetes log capture, a metadata JSON file with the test ID, profile, target URL, image version, commit SHA, and duration settings, and a k6 JSON summary export with threshold results. Use that artifact together with the Grafana `testid` filter when recording evidence. The release gate also republishes those artifacts under `staging-release-evidence/` so a passing promotion has a single audit trail.

## Viewing mandatory k6 evidence

1. Open the GitLab `k6-load-staging` job and note the `Test ID` printed in the log.
2. Download `k6-results/` from the job artifacts. The `*-metadata.json` file records the test ID and target, and `*-summary.json` records threshold results.
3. Open Grafana dashboard `/d/year4-k6-staging` and filter by that `testid` to view request rate, active VUs, failed request rate, checks, latency, and server errors for the run.
4. Open the `staging-release-gate` artifact for the combined release evidence that links this k6 run with the Playwright browser run.

## Mandatory gate coverage

The medium gate is designed as a release baseline, not a single-endpoint benchmark. It splits 10 VUs into owner daily work, employee processing, and manager read scenarios. Together those journeys cover auth login, `/me`, token refresh recovery, customer create/search/delete, customer notes, job create/detail/list/delete, assignment, scheduling, conflict checks, status updates, calendar reads, employee/user list reads, and queue reads.

The gate also checks behavior, not just throughput. It fails on excess HTTP failures, unexpected statuses, 5xx responses, low check pass rate, low full-workflow success, auth recovery failures, cleanup failures, and p95/p99 latency regressions for critical requests, scheduling, and conflict checks. Test data uses fixed coordinates to avoid external geocoding noise, per-VU sessions to avoid artificial refresh-token collisions, and widened future schedule slots so normal workflows are spread across the scheduling domain.

## Tuning workflow

1. Run a staging deployment and let the mandatory `k6-load-staging` job complete with `K6_PROFILE=medium`.
2. Record workflow success, cleanup failure rate, p95/p99 latency, scheduling latency, conflict-check latency, status-code mix, server errors, image version, GitLab job URL, k6 `testid`, `k6-results/` artifact, and Grafana evidence.
3. Run `k6-human-hard-staging` only after the mandatory medium gate is stable. Watch scheduling latency, conflict-check latency, expected conflicts, server errors, pod CPU/memory, and database symptoms.
4. Use `baseline-exploration.js` manually when comparing public endpoint headroom with authenticated workflow headroom; it is not a release gate.
5. Before raising the mandatory gate beyond 10 VUs, scale staging capacity or move to larger workers, then increase load progressively and preserve the same evidence trail.

## Cleanup expectations

`real-user-workflows.js` creates temporary customers, jobs, and notes with a `k6-<testid>` marker. Each journey deletes notes first, then jobs, then customers. A non-zero cleanup failure rate should be investigated before repeating hard tests, because leftover records can make future scheduling conflict numbers noisy.
