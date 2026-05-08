# k6 staging tests

This folder contains the first baseline k6 suite for tuning staging performance gates over time.

## Test files

- `staging-smoke-load.js` — automated CI gate. It is intentionally lightweight and blocks staging destroy/promotion when thresholds fail.
- `baseline-exploration.js` — manual exploratory baseline suite. Use it to learn normal staging latency, failure rate, and capacity before tightening the gate.

Both scripts are non-destructive and use the same safe public endpoints as the shell smoke tests.

## Profiles

`baseline-exploration.js` supports these `K6_PROFILE` values:

| Profile | Purpose | Default shape |
| --- | --- | --- |
| `smoke` | Quick sanity run | health probe + endpoint sweep for 1 minute |
| `baseline` | Normal starting point | health probe, endpoint sweep, weighted browse mix for 5 minutes |
| `stress-lite` | Gentle ramp-up | baseline coverage plus ramping browse traffic |
| `spike-lite` | Small burst test | short burst to observe recovery and dashboard behavior |

The GitLab pipeline exposes `k6-baseline-staging` as a manual, allowed-to-fail job so it can be run while staging is up without blocking release flow.

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

## Tuning workflow

1. Run a staging deployment and open the manual `k6-baseline-staging` job.
2. Start with `K6_PROFILE=baseline` and review the `Year4 Staging k6 Load Gate` Grafana dashboard.
3. Record normal p95/p99 latency, check rate, status-code mix, and any 5xx rate.
4. Re-run with `K6_PROFILE=stress-lite` or `K6_PROFILE=spike-lite` to understand headroom.
5. Tighten `staging-smoke-load.js` thresholds only after the baseline numbers are stable across several staging runs.
6. Add authenticated user journeys later when safe seeded credentials are available.
