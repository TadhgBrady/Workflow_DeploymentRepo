import http from 'k6/http';
import { check, sleep } from 'k6';
import { Rate } from 'k6/metrics';

const rawBaseUrl = __ENV.STAGING_URL || __ENV.BASE_URL || '';
const BASE_URL = rawBaseUrl.replace(/\/+$/, '');

function loadTestEnv(name, fallback) {
  return __ENV[`LOAD_TEST_${name}`] || __ENV[`K6_${name}`] || fallback;
}

const ITERATION_RATE = Number(loadTestEnv('ITERATION_RATE', 1));
const WARMUP_DURATION = loadTestEnv('WARMUP_DURATION', '30s');
const DURATION = loadTestEnv('DURATION', '3m');
const COOLDOWN_DURATION = loadTestEnv('COOLDOWN_DURATION', '30s');
const PRE_ALLOCATED_VUS = Number(loadTestEnv('PRE_ALLOCATED_VUS', 6));
const MAX_VUS = Number(loadTestEnv('MAX_VUS', 20));
const THINK_TIME_SECONDS = Number(loadTestEnv('THINK_TIME_SECONDS', 0.2));

const ENVIRONMENT = loadTestEnv('ENVIRONMENT', 'staging');
const PROFILE = loadTestEnv('PROFILE', 'gate');
const TEST_ID = loadTestEnv('TEST_ID', `local-${Date.now()}`);
const PIPELINE_ID = __ENV.CI_PIPELINE_ID || 'local';
const IMAGE_VERSION = __ENV.IMAGE_VERSION || 'unknown';

http.setResponseCallback(http.expectedStatuses({ min: 200, max: 499 }));

export const options = {
  discardResponseBodies: true,
  summaryTrendStats: ['min', 'avg', 'med', 'p(90)', 'p(95)', 'p(99)', 'max'],
  scenarios: {
    staging_endpoint_sweep: {
      executor: 'ramping-arrival-rate',
      timeUnit: '1s',
      preAllocatedVUs: PRE_ALLOCATED_VUS,
      maxVUs: MAX_VUS,
      gracefulStop: '30s',
      stages: [
        { duration: WARMUP_DURATION, target: Math.max(1, Math.ceil(ITERATION_RATE / 2)) },
        { duration: DURATION, target: ITERATION_RATE },
        { duration: COOLDOWN_DURATION, target: 0 },
      ],
    },
  },
  thresholds: {
    http_req_failed: ['rate<0.01'],
    'http_req_failed{type:critical}': ['rate<0.005'],
    'http_req_duration{type:critical}': ['p(95)<1000', 'p(99)<2500'],
    'checks{type:critical}': ['rate>0.98'],
    server_errors: ['rate<0.01'],
  },
  tags: {
    environment: ENVIRONMENT,
    testid: TEST_ID,
    pipeline: PIPELINE_ID,
    image_version: IMAGE_VERSION,
    profile: PROFILE,
  },
};

const serverErrors = new Rate('server_errors');

const endpoints = [
  {
    name: 'gateway-health',
    path: '/health',
    expectedStatuses: [200],
    type: 'critical',
  },
  {
    name: 'frontend-root',
    path: '/',
    expectedStatuses: [200, 301, 302],
    type: 'critical',
  },
  {
    name: 'auth-login-endpoint',
    path: '/api/v1/auth/login',
    expectedStatuses: [200, 400, 401, 405, 422],
    type: 'supporting',
  },
  {
    name: 'users-route-prefix',
    path: '/api/v1/users',
    expectedStatuses: [200, 401, 405],
    type: 'supporting',
  },
  {
    name: 'jobs-route-prefix',
    path: '/api/v1/jobs',
    expectedStatuses: [200, 401, 405],
    type: 'supporting',
  },
  {
    name: 'customers-route-prefix',
    path: '/api/v1/customers',
    expectedStatuses: [200, 401, 405],
    type: 'supporting',
  },
  {
    name: 'admin-organizations-endpoint',
    path: '/api/v1/admin/organizations',
    expectedStatuses: [200, 401, 403, 405],
    type: 'supporting',
  },
];

function requestTags(endpoint) {
  return {
    name: endpoint.name,
    endpoint: endpoint.name,
    type: endpoint.type,
  };
}

function expectedStatusMessage(endpoint) {
  return `${endpoint.name} status is one of ${endpoint.expectedStatuses.join(',')}`;
}

function requireBaseUrl() {
  if (!BASE_URL) {
    throw new Error('STAGING_URL or BASE_URL must be provided');
  }
}

export function setup() {
  requireBaseUrl();

  const health = http.get(`${BASE_URL}/health`, {
    tags: {
      name: 'setup-health',
      endpoint: 'setup-health',
      type: 'setup',
    },
  });

  if (health.status !== 200) {
    throw new Error(`Staging health check failed before load test: ${health.status}`);
  }
}

export default function () {
  requireBaseUrl();

  for (const endpoint of endpoints) {
    const response = http.get(`${BASE_URL}${endpoint.path}`, {
      tags: requestTags(endpoint),
    });

    serverErrors.add(response.status >= 500, requestTags(endpoint));

    check(
      response,
      {
        [expectedStatusMessage(endpoint)]: (res) => endpoint.expectedStatuses.includes(res.status),
        [`${endpoint.name} has no server error`]: (res) => res.status < 500,
      },
      requestTags(endpoint),
    );
  }

  if (THINK_TIME_SECONDS > 0) {
    sleep(THINK_TIME_SECONDS);
  }
}
