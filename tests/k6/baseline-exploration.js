import http from 'k6/http';
import { check, group, sleep } from 'k6';
import { Counter, Rate, Trend } from 'k6/metrics';

const rawBaseUrl = __ENV.STAGING_URL || __ENV.BASE_URL || '';
const BASE_URL = rawBaseUrl.replace(/\/+$/, '');
const PROFILE = (__ENV.K6_PROFILE || 'baseline').toLowerCase();
const ENVIRONMENT = __ENV.K6_ENVIRONMENT || 'staging';
const TEST_ID = __ENV.K6_TEST_ID || `baseline-${Date.now()}`;
const PIPELINE_ID = __ENV.CI_PIPELINE_ID || 'local';
const IMAGE_VERSION = __ENV.IMAGE_VERSION || 'unknown';

const WARMUP_DURATION = __ENV.K6_WARMUP_DURATION || '45s';
const DURATION = __ENV.K6_DURATION || '5m';
const COOLDOWN_DURATION = __ENV.K6_COOLDOWN_DURATION || '45s';
const SWEEP_RATE = Number(__ENV.K6_SWEEP_RATE || __ENV.K6_ITERATION_RATE || 1);
const BROWSE_RATE = Number(__ENV.K6_BROWSE_RATE || 2);
const STRESS_RATE = Number(__ENV.K6_STRESS_RATE || 5);
const SPIKE_RATE = Number(__ENV.K6_SPIKE_RATE || 10);
const PRE_ALLOCATED_VUS = Number(__ENV.K6_PRE_ALLOCATED_VUS || 8);
const MAX_VUS = Number(__ENV.K6_MAX_VUS || 30);
const THINK_TIME_SECONDS = Number(__ENV.K6_THINK_TIME_SECONDS || 0.25);

const FAILURE_RATE = Number(__ENV.K6_FAILURE_RATE || 0.02);
const CRITICAL_FAILURE_RATE = Number(__ENV.K6_CRITICAL_FAILURE_RATE || 0.01);
const UNEXPECTED_STATUS_RATE = Number(__ENV.K6_UNEXPECTED_STATUS_RATE || 0.02);
const SERVER_ERROR_RATE = Number(__ENV.K6_SERVER_ERROR_RATE || 0.01);
const CHECK_RATE = Number(__ENV.K6_CHECK_RATE || 0.95);
const LATENCY_P95_MS = Number(__ENV.K6_LATENCY_P95_MS || 1500);
const LATENCY_P99_MS = Number(__ENV.K6_LATENCY_P99_MS || 3000);
const REQUEST_TIMEOUT = __ENV.K6_REQUEST_TIMEOUT || '10s';

http.setResponseCallback(http.expectedStatuses({ min: 200, max: 499 }));

const serverErrors = new Rate('server_errors');
const unexpectedStatuses = new Rate('unexpected_statuses');
const endpointDuration = new Trend('endpoint_duration', true);
const endpointRequests = new Counter('endpoint_requests');

const endpoints = [
  {
    name: 'gateway-health',
    path: '/health',
    expectedStatuses: [200],
    type: 'critical',
    weight: 4,
  },
  {
    name: 'frontend-root',
    path: '/',
    expectedStatuses: [200, 301, 302],
    type: 'critical',
    weight: 4,
  },
  {
    name: 'auth-login-endpoint',
    path: '/api/v1/auth/login',
    expectedStatuses: [200, 400, 401, 405, 422],
    type: 'supporting',
    weight: 2,
  },
  {
    name: 'users-route-prefix',
    path: '/api/v1/users',
    expectedStatuses: [200, 401, 405],
    type: 'supporting',
    weight: 2,
  },
  {
    name: 'jobs-route-prefix',
    path: '/api/v1/jobs',
    expectedStatuses: [200, 401, 405],
    type: 'supporting',
    weight: 2,
  },
  {
    name: 'customers-route-prefix',
    path: '/api/v1/customers',
    expectedStatuses: [200, 401, 405],
    type: 'supporting',
    weight: 2,
  },
  {
    name: 'admin-organizations-endpoint',
    path: '/api/v1/admin/organizations',
    expectedStatuses: [200, 401, 403, 405],
    type: 'supporting',
    weight: 1,
  },
];

function baseTags(extra = {}) {
  return {
    environment: ENVIRONMENT,
    testid: TEST_ID,
    pipeline: PIPELINE_ID,
    image_version: IMAGE_VERSION,
    profile: PROFILE,
    suite: 'baseline-exploration',
    ...extra,
  };
}

function requestTags(endpoint, flow) {
  return baseTags({
    name: endpoint.name,
    endpoint: endpoint.name,
    flow,
    type: endpoint.type,
  });
}

function positiveRate(value, fallback) {
  return Number.isFinite(value) && value > 0 ? value : fallback;
}

function availabilityScenario(duration) {
  return {
    executor: 'constant-arrival-rate',
    exec: 'availabilitySweep',
    rate: positiveRate(SWEEP_RATE, 1),
    timeUnit: '1s',
    duration,
    preAllocatedVUs: PRE_ALLOCATED_VUS,
    maxVUs: MAX_VUS,
    gracefulStop: '30s',
  };
}

function browseScenario(duration, rate) {
  return {
    executor: 'constant-arrival-rate',
    exec: 'browseMix',
    rate: positiveRate(rate, 1),
    timeUnit: '1s',
    duration,
    preAllocatedVUs: PRE_ALLOCATED_VUS,
    maxVUs: MAX_VUS,
    gracefulStop: '30s',
  };
}

function rampingBrowseScenario(stages) {
  return {
    executor: 'ramping-arrival-rate',
    exec: 'browseMix',
    timeUnit: '1s',
    preAllocatedVUs: PRE_ALLOCATED_VUS,
    maxVUs: MAX_VUS,
    gracefulStop: '30s',
    stages,
  };
}

function healthProbeScenario(duration) {
  return {
    executor: 'constant-arrival-rate',
    exec: 'healthProbe',
    rate: 1,
    timeUnit: '1s',
    duration,
    preAllocatedVUs: 2,
    maxVUs: Math.max(4, Math.min(MAX_VUS, 8)),
    gracefulStop: '15s',
  };
}

function buildScenarios() {
  switch (PROFILE) {
    case 'smoke':
      return {
        health_probe: healthProbeScenario(__ENV.K6_DURATION || '1m'),
        availability_sweep: availabilityScenario(__ENV.K6_DURATION || '1m'),
      };
    case 'stress-lite':
      return {
        health_probe: healthProbeScenario(DURATION),
        availability_sweep: availabilityScenario(DURATION),
        browse_mix: rampingBrowseScenario([
          { duration: WARMUP_DURATION, target: positiveRate(BROWSE_RATE, 2) },
          { duration: DURATION, target: positiveRate(STRESS_RATE, 5) },
          { duration: COOLDOWN_DURATION, target: 0 },
        ]),
      };
    case 'spike-lite':
      return {
        health_probe: healthProbeScenario(DURATION),
        browse_mix: rampingBrowseScenario([
          { duration: '30s', target: positiveRate(BROWSE_RATE, 2) },
          { duration: '30s', target: positiveRate(SPIKE_RATE, 10) },
          { duration: '1m', target: positiveRate(SPIKE_RATE, 10) },
          { duration: '30s', target: positiveRate(BROWSE_RATE, 2) },
          { duration: '30s', target: 0 },
        ]),
      };
    case 'baseline':
      return {
        health_probe: healthProbeScenario(DURATION),
        availability_sweep: availabilityScenario(DURATION),
        browse_mix: browseScenario(DURATION, BROWSE_RATE),
      };
    default:
      throw new Error(`Unsupported K6_PROFILE: ${PROFILE}. Use smoke, baseline, stress-lite, or spike-lite.`);
  }
}

export const options = {
  discardResponseBodies: true,
  summaryTrendStats: ['min', 'avg', 'med', 'p(90)', 'p(95)', 'p(99)', 'max'],
  scenarios: buildScenarios(),
  thresholds: {
    http_req_failed: [`rate<${FAILURE_RATE}`],
    'http_req_failed{type:critical}': [`rate<${CRITICAL_FAILURE_RATE}`],
    'http_req_duration{type:critical}': [`p(95)<${LATENCY_P95_MS}`, `p(99)<${LATENCY_P99_MS}`],
    'endpoint_duration{type:critical}': [`p(95)<${LATENCY_P95_MS}`, `p(99)<${LATENCY_P99_MS}`],
    checks: [`rate>${CHECK_RATE}`],
    unexpected_statuses: [`rate<${UNEXPECTED_STATUS_RATE}`],
    server_errors: [`rate<${SERVER_ERROR_RATE}`],
  },
  tags: baseTags(),
};

function requireBaseUrl() {
  if (!BASE_URL) {
    throw new Error('STAGING_URL or BASE_URL must be provided');
  }
}

function expectedStatusMessage(endpoint) {
  return `${endpoint.name} status is one of ${endpoint.expectedStatuses.join(',')}`;
}

function pickWeightedEndpoint() {
  const totalWeight = endpoints.reduce((sum, endpoint) => sum + endpoint.weight, 0);
  let draw = Math.random() * totalWeight;
  for (const endpoint of endpoints) {
    draw -= endpoint.weight;
    if (draw <= 0) {
      return endpoint;
    }
  }
  return endpoints[0];
}

function exerciseEndpoint(endpoint, flow) {
  const tags = requestTags(endpoint, flow);
  const response = http.get(`${BASE_URL}${endpoint.path}`, {
    tags,
    timeout: REQUEST_TIMEOUT,
  });

  const expectedStatus = endpoint.expectedStatuses.includes(response.status);
  const serverError = response.status >= 500;

  endpointRequests.add(1, tags);
  endpointDuration.add(response.timings.duration, tags);
  unexpectedStatuses.add(!expectedStatus, tags);
  serverErrors.add(serverError, tags);

  check(
    response,
    {
      [expectedStatusMessage(endpoint)]: () => expectedStatus,
      [`${endpoint.name} has no server error`]: () => !serverError,
    },
    tags,
  );

  return response;
}

export function setup() {
  requireBaseUrl();
  const health = http.get(`${BASE_URL}/health`, {
    tags: baseTags({ name: 'setup-health', endpoint: 'setup-health', flow: 'setup', type: 'setup' }),
    timeout: REQUEST_TIMEOUT,
  });

  if (health.status !== 200) {
    throw new Error(`Staging health check failed before baseline run: ${health.status}`);
  }

  console.log(
    JSON.stringify(
      {
        suite: 'baseline-exploration',
        profile: PROFILE,
        target: BASE_URL,
        testid: TEST_ID,
        duration: DURATION,
        sweepRate: SWEEP_RATE,
        browseRate: BROWSE_RATE,
        stressRate: STRESS_RATE,
        spikeRate: SPIKE_RATE,
        thresholds: {
          failureRate: FAILURE_RATE,
          criticalFailureRate: CRITICAL_FAILURE_RATE,
          unexpectedStatusRate: UNEXPECTED_STATUS_RATE,
          serverErrorRate: SERVER_ERROR_RATE,
          checkRate: CHECK_RATE,
          latencyP95Ms: LATENCY_P95_MS,
          latencyP99Ms: LATENCY_P99_MS,
        },
      },
      null,
      2,
    ),
  );
}

export function healthProbe() {
  requireBaseUrl();
  const healthEndpoint = endpoints[0];
  group('health probe', () => {
    exerciseEndpoint(healthEndpoint, 'health-probe');
  });
}

export function availabilitySweep() {
  requireBaseUrl();
  group('availability sweep', () => {
    for (const endpoint of endpoints) {
      exerciseEndpoint(endpoint, 'availability-sweep');
    }
  });

  if (THINK_TIME_SECONDS > 0) {
    sleep(THINK_TIME_SECONDS);
  }
}

export function browseMix() {
  requireBaseUrl();
  const endpoint = pickWeightedEndpoint();
  group('weighted browse mix', () => {
    exerciseEndpoint(endpoint, 'browse-mix');
  });

  if (THINK_TIME_SECONDS > 0) {
    sleep(THINK_TIME_SECONDS);
  }
}
