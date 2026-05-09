# k6 staging tests

This folder contains the first baseline k6 suite for tuning staging performance gates over time.

## Test files

- `staging-smoke-load.js` — automated CI gate. It is intentionally lightweight and blocks staging destroy/promotion when thresholds fail.
- `baseline-exploration.js` — manual exploratory baseline suite. Use it to learn normal staging latency, failure rate, and capacity before tightening the gate.
- `real-user-workflows.js` — manual authenticated workflow suite. Use it to exercise login-backed customer, job, calendar, status, scheduling, and conflict-check paths with temporary data cleanup.

The smoke and baseline scripts are non-destructive and use the same safe public endpoints as the shell smoke tests. The real workflow script creates only temporary `k6-*` customers/jobs and deletes them at the end of each journey.

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

The GitLab pipeline exposes `k6-baseline-staging`, `k6-human-medium-staging`, and `k6-human-hard-staging` as manual, allowed-to-fail jobs so they can be run while staging is up without blocking release flow. The automated `k6-load-staging` gate remains the only blocking k6 job.

The GitLab jobs still use the `K6_*` variables below for convenience. The Kubernetes runner maps those values to `LOAD_TEST_*` environment variables inside the k6 pod, because some `K6_*` names are reserved by k6 itself. If you run these scripts directly with `k6 run`, use `LOAD_TEST_DURATION`, `LOAD_TEST_MAX_VUS`, and the other `LOAD_TEST_*` names instead of exporting custom `K6_*` values.

## Useful tuning variables

| Variable | Default | Notes |
| --- | --- | --- |
| `K6_PROFILE` | `baseline` for manual baseline job | `smoke`, `baseline`, `stress-lite`, `spike-lite` |
| `K6_DURATION` | `5m` in baseline script | steady-state duration |
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

Every k6 GitLab job uploads a `k6-results/` artifact containing a timestamped Kubernetes log capture and a metadata JSON file with the test ID, profile, target URL, image version, commit SHA, and duration settings. Use that artifact together with the Grafana `testid` filter when recording evidence.

## Tuning workflow

1. Run a staging deployment and open the manual `k6-baseline-staging` job.
2. Start with `K6_PROFILE=baseline` and review the `Year4 Staging k6 Load Gate` Grafana dashboard.
3. Run `k6-human-medium-staging`. Record workflow success, cleanup failure rate, p95/p99 latency, scheduling latency, status-code mix, and any 5xx rate.
4. Run `k6-human-hard-staging` only after medium succeeds. Watch scheduling latency, conflict-check latency, expected conflicts, server errors, pod CPU/memory, and database symptoms.
5. Re-run baseline with `K6_PROFILE=stress-lite` or `K6_PROFILE=spike-lite` to compare public endpoint headroom with authenticated workflow headroom.
6. Save the GitLab job URL, `k6-results/` artifact, image version, k6 `testid`, Grafana screenshot/table, p95/p99 latency, workflow success, auth failures, token refresh failures, cleanup failures, and observed bottlenecks for each run.
7. Tighten `staging-smoke-load.js` thresholds only after the baseline and real workflow numbers are stable across several staging runs.

## Cleanup expectations

`real-user-workflows.js` creates temporary customers, jobs, and notes with a `k6-<testid>` marker. Each journey deletes notes first, then jobs, then customers. A non-zero cleanup failure rate should be investigated before repeating hard tests, because leftover records can make future scheduling conflict numbers noisy.
