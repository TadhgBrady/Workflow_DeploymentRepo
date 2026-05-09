import http from 'k6/http';
import { check, group, sleep } from 'k6';
import { Counter, Rate, Trend } from 'k6/metrics';

const rawBaseUrl = __ENV.STAGING_URL || __ENV.BASE_URL || '';
const BASE_URL = rawBaseUrl.replace(/\/+$/, '');

function loadTestEnv(name, fallback) {
  return __ENV[`LOAD_TEST_${name}`] || __ENV[`K6_${name}`] || fallback;
}

function numberEnv(name, fallback) {
  const value = Number(loadTestEnv(name, fallback));
  return Number.isFinite(value) ? value : fallback;
}

function boolEnv(name, fallback) {
  const value = String(loadTestEnv(name, fallback ? 'true' : 'false')).toLowerCase();
  return ['1', 'true', 'yes', 'on'].includes(value);
}

const PROFILE = loadTestEnv('PROFILE', 'medium').toLowerCase();
const ENVIRONMENT = loadTestEnv('ENVIRONMENT', 'staging');
const TEST_ID = loadTestEnv('TEST_ID', `human-${Date.now()}`);
const PIPELINE_ID = __ENV.CI_PIPELINE_ID || 'local';
const IMAGE_VERSION = __ENV.IMAGE_VERSION || 'unknown';

const OWNER_EMAIL = loadTestEnv('OWNER_EMAIL', 'owner@demo.com');
const MANAGER_EMAIL = loadTestEnv('MANAGER_EMAIL', 'manager@demo.com');
const EMPLOYEE_EMAIL = loadTestEnv('EMPLOYEE_EMAIL', 'employee@demo.com');
const SHARED_PASSWORD = loadTestEnv('USER_PASSWORD', '');
const OWNER_PASSWORD = loadTestEnv('OWNER_PASSWORD', SHARED_PASSWORD);
const MANAGER_PASSWORD = loadTestEnv('MANAGER_PASSWORD', SHARED_PASSWORD);
const EMPLOYEE_PASSWORD = loadTestEnv('EMPLOYEE_PASSWORD', SHARED_PASSWORD);

const WARMUP_DURATION = loadTestEnv('WARMUP_DURATION', '1m');
const DURATION = loadTestEnv('DURATION', '6m');
const COOLDOWN_DURATION = loadTestEnv('COOLDOWN_DURATION', '1m');
const MEDIUM_TARGET_VUS = numberEnv('MEDIUM_TARGET_VUS', 10);
const HARD_TARGET_VUS = numberEnv('HARD_TARGET_VUS', 24);
const HARD_JOBS_PER_SESSION = Math.max(1, Math.floor(numberEnv('HARD_JOBS_PER_SESSION', 2)));
const PRE_ALLOCATED_VUS = numberEnv('PRE_ALLOCATED_VUS', 12);
const MAX_VUS = numberEnv('MAX_VUS', 60);
const THINK_TIME_SECONDS = numberEnv('THINK_TIME_SECONDS', 0.6);
const THINK_TIME_JITTER_SECONDS = numberEnv('THINK_TIME_JITTER_SECONDS', 0.4);
const REQUEST_TIMEOUT = loadTestEnv('REQUEST_TIMEOUT', '15s');
const CLEANUP_ENABLED = boolEnv('CLEANUP_ENABLED', true);
const AUTH_RECOVERY_ENABLED = boolEnv('AUTH_RECOVERY_ENABLED', true);
const AUTH_REFRESH_SKEW_SECONDS = numberEnv('AUTH_REFRESH_SKEW_SECONDS', 60);
const AUTH_RETRY_DELAY_SECONDS = numberEnv('AUTH_RETRY_DELAY_SECONDS', 0.4);

const FAILURE_RATE = numberEnv('FAILURE_RATE', PROFILE === 'hard' ? 0.05 : 0.02);
const SERVER_ERROR_RATE = numberEnv('SERVER_ERROR_RATE', 0.01);
const UNEXPECTED_STATUS_RATE = numberEnv('UNEXPECTED_STATUS_RATE', PROFILE === 'hard' ? 0.05 : 0.02);
const CHECK_RATE = numberEnv('CHECK_RATE', PROFILE === 'hard' ? 0.9 : 0.95);
const WORKFLOW_SUCCESS_RATE = numberEnv('WORKFLOW_SUCCESS_RATE', PROFILE === 'hard' ? 0.9 : 0.95);
const AUTH_FAILURE_RATE = numberEnv('AUTH_FAILURE_RATE', 0.01);
const CLEANUP_FAILURE_RATE = numberEnv('CLEANUP_FAILURE_RATE', 0.02);
const LATENCY_P95_MS = numberEnv('LATENCY_P95_MS', PROFILE === 'hard' ? 3000 : 2000);
const LATENCY_P99_MS = numberEnv('LATENCY_P99_MS', PROFILE === 'hard' ? 7000 : 5000);
const SCHEDULING_P95_MS = numberEnv('SCHEDULING_P95_MS', PROFILE === 'hard' ? 4000 : 2500);
const SCHEDULING_P99_MS = numberEnv('SCHEDULING_P99_MS', PROFILE === 'hard' ? 8000 : 5000);
const CONFLICT_P95_MS = numberEnv('CONFLICT_P95_MS', PROFILE === 'hard' ? 4000 : 2500);
const CONFLICT_P99_MS = numberEnv('CONFLICT_P99_MS', PROFILE === 'hard' ? 8000 : 5000);

const DAY_MS = 24 * 60 * 60 * 1000;
const RUN_PREFIX = `k6-${TEST_ID}`.replace(/[^a-zA-Z0-9-]/g, '-').slice(0, 60);

http.setResponseCallback(http.expectedStatuses({ min: 200, max: 499 }));

const serverErrors = new Rate('server_errors');
const unexpectedStatuses = new Rate('unexpected_statuses');
const workflowSuccess = new Rate('workflow_success');
const authFailures = new Rate('auth_failures');
const authRecoveries = new Counter('auth_recoveries');
const tokenRefreshes = new Counter('token_refreshes');
const tokenRefreshFailures = new Rate('token_refresh_failures');
const cleanupFailures = new Rate('cleanup_failures');
const expectedConflicts = new Counter('expected_conflicts');
const workflowDuration = new Trend('workflow_duration', true);
const loginDuration = new Trend('login_duration', true);
const calendarDuration = new Trend('calendar_duration', true);
const customerCreateDuration = new Trend('customer_create_duration', true);
const jobCreateDuration = new Trend('job_create_duration', true);
const schedulingDuration = new Trend('scheduling_duration', true);
const conflictCheckDuration = new Trend('conflict_check_duration', true);

function baseTags(extra = {}) {
  return {
    environment: ENVIRONMENT,
    testid: TEST_ID,
    pipeline: PIPELINE_ID,
    image_version: IMAGE_VERSION,
    profile: PROFILE,
    suite: 'real-user-workflows',
    ...extra,
  };
}

function splitVus(total, ratios) {
  const normalizedTotal = Math.max(1, Math.floor(total));
  const values = ratios.map((ratio) => Math.max(1, Math.floor(normalizedTotal * ratio)));
  let sum = values.reduce((current, value) => current + value, 0);
  while (sum > normalizedTotal && values.length > 1) {
    const index = values.indexOf(Math.max(...values));
    if (values[index] <= 1) {
      break;
    }
    values[index] -= 1;
    sum -= 1;
  }
  return values;
}

function rampingVusScenario(execName, targetVus) {
  return {
    executor: 'ramping-vus',
    exec: execName,
    startVUs: 0,
    stages: [
      { duration: WARMUP_DURATION, target: targetVus },
      { duration: DURATION, target: targetVus },
      { duration: COOLDOWN_DURATION, target: 0 },
    ],
    gracefulRampDown: '30s',
  };
}

function buildScenarios() {
  if (PROFILE === 'medium') {
    const [ownerVus, employeeVus, managerVus] = splitVus(MEDIUM_TARGET_VUS, [0.4, 0.4, 0.2]);
    return {
      medium_owner_daily: rampingVusScenario('ownerDailyWorkflow', ownerVus),
      medium_employee_processing: rampingVusScenario('employeeProcessingWorkflow', employeeVus),
      medium_manager_read: rampingVusScenario('managerReadWorkflow', managerVus),
    };
  }

  if (PROFILE === 'hard') {
    const [managerVus, employeeVus, conflictVus] = splitVus(HARD_TARGET_VUS, [0.65, 0.2, 0.15]);
    return {
      hard_manager_scheduling: rampingVusScenario('managerSchedulingWorkflow', managerVus),
      hard_employee_processing: rampingVusScenario('employeeProcessingWorkflow', employeeVus),
      hard_conflict_pressure: rampingVusScenario('conflictPressureWorkflow', conflictVus),
    };
  }

  throw new Error(`Unsupported LOAD_TEST_PROFILE: ${PROFILE}. Use medium or hard.`);
}

export const options = {
  discardResponseBodies: false,
  summaryTrendStats: ['min', 'avg', 'med', 'p(90)', 'p(95)', 'p(99)', 'max'],
  scenarios: buildScenarios(),
  thresholds: {
    http_req_failed: [`rate<${FAILURE_RATE}`],
    'http_req_duration{type:critical}': [`p(95)<${LATENCY_P95_MS}`, `p(99)<${LATENCY_P99_MS}`],
    checks: [`rate>${CHECK_RATE}`],
    workflow_success: [`rate>${WORKFLOW_SUCCESS_RATE}`],
    auth_failures: [`rate<${AUTH_FAILURE_RATE}`],
    token_refresh_failures: [`rate<${AUTH_FAILURE_RATE}`],
    cleanup_failures: [`rate<${CLEANUP_FAILURE_RATE}`],
    unexpected_statuses: [`rate<${UNEXPECTED_STATUS_RATE}`],
    server_errors: [`rate<${SERVER_ERROR_RATE}`],
    scheduling_duration: [`p(95)<${SCHEDULING_P95_MS}`, `p(99)<${SCHEDULING_P99_MS}`],
    conflict_check_duration: [`p(95)<${CONFLICT_P95_MS}`, `p(99)<${CONFLICT_P99_MS}`],
  },
  tags: baseTags(),
};

function requireBaseUrl() {
  if (!BASE_URL) {
    throw new Error('STAGING_URL or BASE_URL must be provided');
  }
}

function requireCredential(name, value) {
  if (!value) {
    throw new Error(`Missing ${name}. Set a masked GitLab variable such as K6_USER_PASSWORD or the role-specific password variable.`);
  }
}

function toQuery(params = {}) {
  const pairs = Object.keys(params)
    .filter((key) => params[key] !== undefined && params[key] !== null && params[key] !== '')
    .map((key) => `${encodeURIComponent(key)}=${encodeURIComponent(String(params[key]))}`);
  if (pairs.length === 0) {
    return '';
  }
  return `?${pairs.join('&')}`;
}

function humanPause(multiplier = 1) {
  const delay = Math.max(0, THINK_TIME_SECONDS * multiplier + Math.random() * THINK_TIME_JITTER_SECONDS);
  if (delay > 0) {
    sleep(delay);
  }
}

function jsonBody(value) {
  return value === undefined || value === null ? null : JSON.stringify(value);
}

function parseJson(response, fallback = {}) {
  try {
    return response.json();
  } catch (error) {
    return fallback;
  }
}

function extractItems(data) {
  if (Array.isArray(data)) {
    return data;
  }
  return data.items || data.data || data.jobs || data.customers || data.employees || [];
}

function extractId(data) {
  return data && (data.id || data.job_id || data.customer_id || data.employee_id || data.note_id);
}

function isExpectedStatus(response, expectedStatuses) {
  return expectedStatuses.includes(response.status);
}

function assertExpected(response, expectedStatuses, context) {
  if (!isExpectedStatus(response, expectedStatuses)) {
    throw new Error(`${context} returned HTTP ${response.status}: ${String(response.body || '').slice(0, 240)}`);
  }
}

function requestTags(name, role, journey, type, flow) {
  return baseTags({ name, endpoint: name, role, journey, type, flow });
}

function applyTokenResponse(session, data) {
  session.token = data.access_token;
  session.refreshToken = data.refresh_token || session.refreshToken || '';
  const expiresIn = Math.max(30, Number(data.expires_in || 300));
  session.expiresAt = Date.now() + expiresIn * 1000;
}

function refreshSession(session, journey) {
  const tags = baseTags({ role: session.role, journey, flow: 'auth', name: 'auth-refresh' });
  if (!session.refreshToken) {
    tokenRefreshFailures.add(true, tags);
    return false;
  }

  const response = apiRequest(null, 'POST', '/api/v1/auth/refresh', {
    name: 'auth-refresh',
    role: session.role,
    journey,
    flow: 'auth',
    type: 'critical',
    expectedStatuses: [200],
    recoverAuth: false,
    body: { refresh_token: session.refreshToken },
  });
  const ok = response.status === 200;
  tokenRefreshFailures.add(!ok, tags);
  if (!ok) {
    return false;
  }

  const data = parseJson(response);
  if (!data.access_token) {
    tokenRefreshFailures.add(true, tags);
    return false;
  }

  applyTokenResponse(session, data);
  tokenRefreshes.add(1, tags);
  return true;
}

function reloginSession(session, journey) {
  if (!session.email || !session.password) {
    return false;
  }
  try {
    const nextSession = login(session.role, session.email, session.password, journey);
    session.token = nextSession.token;
    session.refreshToken = nextSession.refreshToken;
    session.expiresAt = nextSession.expiresAt;
    return true;
  } catch (error) {
    authFailures.add(true, baseTags({ role: session.role, journey, flow: 'auth', name: 'auth-relogin' }));
    return false;
  }
}

function recoverSession(session, journey) {
  if (!AUTH_RECOVERY_ENABLED) {
    return false;
  }
  if (AUTH_RETRY_DELAY_SECONDS > 0) {
    sleep(AUTH_RETRY_DELAY_SECONDS + Math.random() * AUTH_RETRY_DELAY_SECONDS);
  }
  const recovered = refreshSession(session, journey) || reloginSession(session, journey);
  if (recovered) {
    authRecoveries.add(1, baseTags({ role: session.role, journey, flow: 'auth', name: 'auth-recovery' }));
  }
  return recovered;
}

function ensureFreshSession(session, journey) {
  if (!session || !session.token || !AUTH_RECOVERY_ENABLED) {
    return;
  }
  if (session.expiresAt && Date.now() >= session.expiresAt - AUTH_REFRESH_SKEW_SECONDS * 1000) {
    recoverSession(session, journey);
  }
}

function apiRequest(session, method, path, options = {}) {
  const expectedStatuses = options.expectedStatuses || [200];
  const name = options.name || `${method.toLowerCase()}-${path.replace(/[^a-zA-Z0-9]+/g, '-').replace(/^-|-$/g, '')}`;
  const role = options.role || (session ? session.role : 'anonymous');
  const journey = options.journey || 'setup';
  const type = options.type || 'workflow';
  const flow = options.flow || journey;
  const tags = requestTags(name, role, journey, type, flow);

  if (session && options.refresh !== false) {
    ensureFreshSession(session, journey);
  }

  const send = () => {
    const headers = {
      Accept: 'application/json',
      'Content-Type': 'application/json',
      ...(options.headers || {}),
    };

    if (session && session.token) {
      headers.Authorization = `Bearer ${session.token}`;
    }

    return http.request(method, `${BASE_URL}${path}${toQuery(options.query)}`, jsonBody(options.body), {
      headers,
      tags,
      timeout: options.timeout || REQUEST_TIMEOUT,
    });
  };

  let response = send();
  if (response.status === 401 && session && options.recoverAuth !== false && options.refresh !== false) {
    authFailures.add(true, baseTags({ role, journey, flow: 'auth', name: `${name}-401` }));
    if (recoverSession(session, journey)) {
      response = send();
    }
  }

  const expected = isExpectedStatus(response, expectedStatuses);
  const serverError = response.status >= 500 || response.status === 0;
  unexpectedStatuses.add(!expected, tags);
  serverErrors.add(serverError, tags);

  check(
    response,
    {
      [`${name} status is expected`]: () => expected,
      [`${name} has no server error`]: () => !serverError,
    },
    tags,
  );

  return response;
}

function login(role, email, password, journey = 'setup') {
  const started = Date.now();
  const response = apiRequest(null, 'POST', '/api/v1/auth/login', {
    name: 'auth-login',
    role,
    journey,
    flow: 'auth',
    type: 'critical',
    expectedStatuses: [200],
    body: { email, password },
  });
  loginDuration.add(response.timings.duration || Date.now() - started, baseTags({ role, journey, name: 'auth-login' }));

  const ok = response.status === 200;
  authFailures.add(!ok, baseTags({ role, journey, name: 'auth-login' }));
  assertExpected(response, [200], `${role} login`);
  const data = parseJson(response);
  if (!data.access_token) {
    authFailures.add(true, baseTags({ role, journey, name: 'auth-login' }));
    throw new Error(`${role} login did not return access_token`);
  }

  const session = {
    role,
    email,
    password,
    token: '',
    refreshToken: '',
    expiresAt: 0,
  };
  applyTokenResponse(session, data);
  return session;
}

function verifySession(session) {
  const response = apiRequest(session, 'GET', '/api/v1/auth/me', {
    name: 'auth-me',
    journey: 'setup',
    flow: 'auth',
    type: 'critical',
    expectedStatuses: [200],
  });
  assertExpected(response, [200], `${session.role} auth/me`);
}

function fetchFirstEmployeeId(session) {
  const response = apiRequest(session, 'GET', '/api/v1/employees', {
    name: 'employees-list',
    journey: 'setup',
    flow: 'setup',
    type: 'critical',
    expectedStatuses: [200],
    query: { limit: 20 },
  });
  assertExpected(response, [200], 'employee lookup');
  const items = extractItems(parseJson(response));
  if (!items.length) {
    throw new Error('No employees found in staging tenant; real workflow tests require at least one employee.');
  }
  const employeeId = extractId(items[0]);
  if (!employeeId) {
    throw new Error(`Could not extract employee id from response: ${JSON.stringify(items[0])}`);
  }
  return employeeId;
}

function formatDate(date) {
  return date.toISOString().slice(0, 10);
}

function calendarRange(daysAhead, spanDays) {
  const start = new Date(Date.now() + daysAhead * DAY_MS);
  const end = new Date(start.getTime() + spanDays * DAY_MS);
  return { start_date: formatDate(start), end_date: formatDate(end) };
}

function futureSlot(extraDays = 0, lengthHours = 2) {
  const offsetDays = 30 + ((__VU * 17 + __ITER * 5 + extraDays) % 240);
  const start = new Date(Date.now() + offsetDays * DAY_MS);
  start.setUTCHours(8 + ((__VU + __ITER + extraDays) % 8), ((__VU * 7 + __ITER * 11) % 4) * 15, 0, 0);
  const end = new Date(start.getTime() + lengthHours * 60 * 60 * 1000);
  return { start_time: start.toISOString(), end_time: end.toISOString() };
}

function uniqueSuffix(label) {
  const compactTestId = TEST_ID.replace(/[^a-zA-Z0-9]/g, '').slice(0, 18) || 'manual';
  return `${label}-${compactTestId}-${__VU}-${__ITER}-${Date.now()}`.slice(0, 90);
}

function createCustomer(session, journey, label) {
  const suffix = uniqueSuffix(label);
  const response = apiRequest(session, 'POST', '/api/v1/customers', {
    name: 'customers-create',
    journey,
    flow: 'customer-create',
    type: 'critical',
    expectedStatuses: [200, 201],
    body: {
      first_name: 'K6',
      last_name: suffix.slice(0, 80),
      email: `${suffix.replace(/[^a-zA-Z0-9]/g, '').slice(0, 48)}@loadtest.example`,
      phone: '0850000000',
      company: 'K6 Load Test',
      address: '1 Load Test Street',
      notify_email: false,
      notify_whatsapp: false,
    },
  });
  customerCreateDuration.add(response.timings.duration, requestTags('customers-create', session.role, journey, 'critical', 'customer-create'));
  assertExpected(response, [200, 201], 'create customer');
  const customerId = extractId(parseJson(response));
  if (!customerId) {
    throw new Error('Customer create response did not include an id');
  }
  return customerId;
}

function createJob(session, journey, customerId, label, extra = {}) {
  const response = apiRequest(session, 'POST', '/api/v1/jobs', {
    name: 'jobs-create',
    journey,
    flow: 'job-create',
    type: 'critical',
    expectedStatuses: [200, 201],
    body: {
      title: `K6 ${PROFILE} ${uniqueSuffix(label)}`.slice(0, 180),
      description: `Created by k6 real-user workflow ${TEST_ID}`,
      customer_id: customerId,
      status: 'pending',
      priority: extra.priority || 'normal',
      estimated_duration: extra.estimated_duration || 90,
      address: '1 Load Test Street',
      notes: RUN_PREFIX,
      send_welcome_email: false,
      send_welcome_whatsapp: false,
      ...extra,
    },
  });
  jobCreateDuration.add(response.timings.duration, requestTags('jobs-create', session.role, journey, 'critical', 'job-create'));
  assertExpected(response, [200, 201], 'create job');
  const jobId = extractId(parseJson(response));
  if (!jobId) {
    throw new Error('Job create response did not include an id');
  }
  return jobId;
}

function addCustomerNote(session, journey, customerId) {
  const response = apiRequest(session, 'POST', `/api/v1/notes/${customerId}`, {
    name: 'notes-create',
    journey,
    flow: 'customer-note',
    expectedStatuses: [200, 201],
    body: { content: `k6 follow-up note ${RUN_PREFIX}` },
  });
  assertExpected(response, [200, 201], 'create customer note');
  return extractId(parseJson(response));
}

function assignJob(session, journey, jobId, employeeId) {
  const response = apiRequest(session, 'POST', `/api/v1/jobs/${jobId}/assign`, {
    name: 'jobs-assign',
    journey,
    flow: 'scheduling',
    type: 'scheduling',
    expectedStatuses: [200],
    body: { assigned_to: employeeId },
  });
  schedulingDuration.add(response.timings.duration, requestTags('jobs-assign', session.role, journey, 'scheduling', 'scheduling'));
  assertExpected(response, [200], 'assign job');
}

function checkConflicts(session, journey, jobId, slot, employeeId, expectedStatuses = [200]) {
  const response = apiRequest(session, 'POST', `/api/v1/jobs/${jobId}/check-conflicts`, {
    name: 'jobs-check-conflicts',
    journey,
    flow: 'scheduling',
    type: 'scheduling',
    expectedStatuses,
    body: { ...slot, assigned_to: employeeId },
  });
  conflictCheckDuration.add(response.timings.duration, requestTags('jobs-check-conflicts', session.role, journey, 'scheduling', 'scheduling'));
  assertExpected(response, expectedStatuses, 'check conflicts');
  return parseJson(response, { has_conflicts: false, conflicts: [] });
}

function scheduleJob(session, journey, jobId, slot, expectedStatuses = [200]) {
  const response = apiRequest(session, 'POST', `/api/v1/jobs/${jobId}/schedule`, {
    name: 'jobs-schedule',
    journey,
    flow: 'scheduling',
    type: 'scheduling',
    expectedStatuses,
    body: slot,
  });
  schedulingDuration.add(response.timings.duration, requestTags('jobs-schedule', session.role, journey, 'scheduling', 'scheduling'));
  assertExpected(response, expectedStatuses, 'schedule job');
  return response;
}

function updateJobStatus(session, journey, jobId, status) {
  const response = apiRequest(session, 'PUT', `/api/v1/jobs/${jobId}/status`, {
    name: 'jobs-status-update',
    journey,
    flow: 'job-status',
    type: 'critical',
    expectedStatuses: [200],
    body: { status, notes: `k6 ${status} ${RUN_PREFIX}` },
  });
  assertExpected(response, [200], `update job status to ${status}`);
}

function deleteResource(session, method, path, name, journey) {
  const response = apiRequest(session, method, path, {
    name,
    journey,
    flow: 'cleanup',
    type: 'cleanup',
    expectedStatuses: [200, 202, 204, 404],
  });
  return [200, 202, 204, 404].includes(response.status);
}

function cleanupCreatedResources(ownerSession, journey, state) {
  if (!CLEANUP_ENABLED) {
    cleanupFailures.add(false, baseTags({ journey, role: ownerSession.role, flow: 'cleanup', name: 'cleanup-disabled' }));
    return;
  }

  let failed = false;
  for (const noteId of [...state.noteIds].reverse()) {
    if (noteId && !deleteResource(ownerSession, 'DELETE', `/api/v1/notes/${noteId}`, 'notes-delete', journey)) {
      failed = true;
    }
  }
  for (const jobId of [...state.jobIds].reverse()) {
    if (jobId && !deleteResource(ownerSession, 'DELETE', `/api/v1/jobs/${jobId}`, 'jobs-delete', journey)) {
      failed = true;
    }
  }
  for (const customerId of [...state.customerIds].reverse()) {
    if (customerId && !deleteResource(ownerSession, 'DELETE', `/api/v1/customers/${customerId}`, 'customers-delete', journey)) {
      failed = true;
    }
  }
  cleanupFailures.add(failed, baseTags({ journey, role: ownerSession.role, flow: 'cleanup', name: 'cleanup' }));
}

function browseCalendar(session, journey, daysAhead, spanDays, employeeId = null) {
  const response = apiRequest(session, 'GET', '/api/v1/jobs/calendar', {
    name: 'jobs-calendar',
    journey,
    flow: 'calendar',
    type: 'critical',
    expectedStatuses: [200],
    query: { ...calendarRange(daysAhead, spanDays), employee_id: employeeId },
  });
  calendarDuration.add(response.timings.duration, requestTags('jobs-calendar', session.role, journey, 'critical', 'calendar'));
  assertExpected(response, [200], 'calendar browse');
}

function browseCommonReadPaths(session, journey, employeeId = null) {
  browseCalendar(session, journey, 0, PROFILE === 'hard' ? 60 : 30, employeeId);
  humanPause(0.7);
  assertExpected(apiRequest(session, 'GET', '/api/v1/jobs', {
    name: 'jobs-list', journey, flow: 'browse', expectedStatuses: [200], query: { limit: 25 },
  }), [200], 'jobs list');
  humanPause(0.5);
  assertExpected(apiRequest(session, 'GET', '/api/v1/customers/search', {
    name: 'customers-search', journey, flow: 'browse', expectedStatuses: [200], query: { q: 'Demo', limit: 10 },
  }), [200], 'customers search');
}

function finishWorkflow(journey, role, started, success, error) {
  const tags = baseTags({ journey, role, flow: 'workflow', name: journey });
  workflowDuration.add(Date.now() - started, tags);
  workflowSuccess.add(success, tags);
  if (error) {
    console.error(`[${journey}] ${error.message || error}`);
  }
}

export function setup() {
  requireBaseUrl();
  requireCredential('K6_USER_PASSWORD or K6_OWNER_PASSWORD', OWNER_PASSWORD);
  requireCredential('K6_USER_PASSWORD or K6_MANAGER_PASSWORD', MANAGER_PASSWORD);
  requireCredential('K6_USER_PASSWORD or K6_EMPLOYEE_PASSWORD', EMPLOYEE_PASSWORD);

  const health = apiRequest(null, 'GET', '/health', {
    name: 'setup-health',
    role: 'anonymous',
    journey: 'setup',
    flow: 'setup',
    type: 'critical',
    expectedStatuses: [200],
  });
  assertExpected(health, [200], 'staging health');

  const owner = login('owner', OWNER_EMAIL, OWNER_PASSWORD);
  const manager = login('manager', MANAGER_EMAIL, MANAGER_PASSWORD);
  const employee = login('employee', EMPLOYEE_EMAIL, EMPLOYEE_PASSWORD);
  verifySession(owner);
  verifySession(manager);
  verifySession(employee);
  const employeeId = fetchFirstEmployeeId(owner);

  console.log(JSON.stringify({
    suite: 'real-user-workflows',
    profile: PROFILE,
    target: BASE_URL,
    testid: TEST_ID,
    duration: DURATION,
    mediumTargetVus: MEDIUM_TARGET_VUS,
    hardTargetVus: HARD_TARGET_VUS,
    hardJobsPerSession: HARD_JOBS_PER_SESSION,
    cleanupEnabled: CLEANUP_ENABLED,
    authRecoveryEnabled: AUTH_RECOVERY_ENABLED,
    authRefreshSkewSeconds: AUTH_REFRESH_SKEW_SECONDS,
    thresholds: {
      failureRate: FAILURE_RATE,
      workflowSuccessRate: WORKFLOW_SUCCESS_RATE,
      checkRate: CHECK_RATE,
      latencyP95Ms: LATENCY_P95_MS,
      latencyP99Ms: LATENCY_P99_MS,
      schedulingP95Ms: SCHEDULING_P95_MS,
      conflictP95Ms: CONFLICT_P95_MS,
    },
  }, null, 2));

  return { owner, manager, employee, employeeId };
}

export function ownerDailyWorkflow(data) {
  const journey = 'owner-daily-workflow';
  const state = { customerIds: [], jobIds: [], noteIds: [] };
  const started = Date.now();
  let success = false;
  let workflowError = null;

  group('owner daily workflow', () => {
    try {
      const { owner, employeeId } = data;
      browseCommonReadPaths(owner, journey, employeeId);
      humanPause();
      const customerId = createCustomer(owner, journey, 'owner-customer');
      state.customerIds.push(customerId);
      humanPause();
      const jobId = createJob(owner, journey, customerId, 'owner-job', { priority: 'high' });
      state.jobIds.push(jobId);
      humanPause(0.5);
      assignJob(owner, journey, jobId, employeeId);
      const slot = futureSlot(1);
      const conflictResult = checkConflicts(owner, journey, jobId, slot, employeeId);
      if (conflictResult.has_conflicts) {
        throw new Error('New owner workflow job unexpectedly has scheduling conflicts');
      }
      scheduleJob(owner, journey, jobId, slot);
      humanPause();
      assertExpected(apiRequest(owner, 'GET', `/api/v1/jobs/${jobId}`, {
        name: 'jobs-detail', journey, flow: 'job-detail', expectedStatuses: [200],
      }), [200], 'job detail');
      const noteId = addCustomerNote(owner, journey, customerId);
      if (noteId) {
        state.noteIds.push(noteId);
      }
      updateJobStatus(owner, journey, jobId, 'completed');
      success = true;
    } catch (error) {
      workflowError = error;
    } finally {
      cleanupCreatedResources(data.owner, journey, state);
      finishWorkflow(journey, 'owner', started, success, workflowError);
    }
  });
  humanPause();
}

export function employeeProcessingWorkflow(data) {
  const journey = 'employee-processing-workflow';
  const state = { customerIds: [], jobIds: [], noteIds: [] };
  const started = Date.now();
  let success = false;
  let workflowError = null;

  group('employee processing workflow', () => {
    try {
      const { owner, employee, employeeId } = data;
      const customerId = createCustomer(owner, journey, 'employee-customer');
      state.customerIds.push(customerId);
      const slot = futureSlot(10);
      const jobId = createJob(owner, journey, customerId, 'employee-job', { priority: 'normal' });
      state.jobIds.push(jobId);
      assignJob(owner, journey, jobId, employeeId);
      scheduleJob(owner, journey, jobId, slot);
      humanPause();
      assertExpected(apiRequest(employee, 'GET', '/api/v1/jobs', {
        name: 'jobs-list', journey, flow: 'employee-queue', expectedStatuses: [200], query: { limit: 25 },
      }), [200], 'employee jobs list');
      assertExpected(apiRequest(employee, 'GET', `/api/v1/jobs/${jobId}`, {
        name: 'jobs-detail', journey, flow: 'employee-job-detail', expectedStatuses: [200],
      }), [200], 'employee job detail');
      humanPause(0.5);
      updateJobStatus(employee, journey, jobId, 'in_progress');
      humanPause(0.5);
      updateJobStatus(employee, journey, jobId, 'completed');
      browseCalendar(employee, journey, 0, 30, employeeId);
      success = true;
    } catch (error) {
      workflowError = error;
    } finally {
      cleanupCreatedResources(data.owner, journey, state);
      finishWorkflow(journey, 'employee', started, success, workflowError);
    }
  });
  humanPause();
}

export function managerReadWorkflow(data) {
  const journey = 'manager-read-workflow';
  const started = Date.now();
  let success = false;
  let workflowError = null;

  group('manager read workflow', () => {
    try {
      const { manager, employeeId } = data;
      assertExpected(apiRequest(manager, 'GET', '/api/v1/employees', {
        name: 'employees-list', journey, flow: 'team-read', expectedStatuses: [200], query: { limit: 50 },
      }), [200], 'employees list');
      humanPause();
      assertExpected(apiRequest(manager, 'GET', '/api/v1/users', {
        name: 'users-list', journey, flow: 'team-read', expectedStatuses: [200], query: { limit: 50 },
      }), [200], 'users list');
      browseCommonReadPaths(manager, journey, employeeId);
      assertExpected(apiRequest(manager, 'GET', '/api/v1/jobs/queue', {
        name: 'jobs-queue', journey, flow: 'queue-read', expectedStatuses: [200], query: { limit: 25 },
      }), [200], 'jobs queue');
      cleanupFailures.add(false, baseTags({ journey, role: 'manager', flow: 'cleanup', name: 'no-cleanup-needed' }));
      success = true;
    } catch (error) {
      workflowError = error;
    } finally {
      finishWorkflow(journey, 'manager', started, success, workflowError);
    }
  });
  humanPause();
}

export function managerSchedulingWorkflow(data) {
  const journey = 'manager-scheduling-workflow';
  const state = { customerIds: [], jobIds: [], noteIds: [] };
  const started = Date.now();
  let success = false;
  let workflowError = null;

  group('manager scheduling workflow', () => {
    try {
      const { owner, manager, employeeId } = data;
      browseCalendar(manager, journey, 0, 60, employeeId);
      assertExpected(apiRequest(manager, 'GET', '/api/v1/employees', {
        name: 'employees-list', journey, flow: 'team-read', expectedStatuses: [200], query: { limit: 50 },
      }), [200], 'employees list');
      const customerId = createCustomer(owner, journey, 'manager-customer');
      state.customerIds.push(customerId);

      for (let index = 0; index < HARD_JOBS_PER_SESSION; index += 1) {
        humanPause(0.4);
        const jobId = createJob(owner, journey, customerId, `manager-job-${index}`, { priority: index % 2 === 0 ? 'urgent' : 'high' });
        state.jobIds.push(jobId);
        const slot = futureSlot(20 + index, 2);
        assignJob(manager, journey, jobId, employeeId);
        const conflictResult = checkConflicts(manager, journey, jobId, slot, employeeId);
        if (conflictResult.has_conflicts) {
          throw new Error('Manager scheduling job unexpectedly has conflicts');
        }
        scheduleJob(manager, journey, jobId, slot);
        assertExpected(apiRequest(manager, 'GET', `/api/v1/jobs/${jobId}`, {
          name: 'jobs-detail', journey, flow: 'manager-job-detail', expectedStatuses: [200],
        }), [200], 'manager job detail');
      }

      browseCalendar(manager, journey, 0, 60, employeeId);
      success = true;
    } catch (error) {
      workflowError = error;
    } finally {
      cleanupCreatedResources(data.owner, journey, state);
      finishWorkflow(journey, 'manager', started, success, workflowError);
    }
  });
  humanPause(0.5);
}

export function conflictPressureWorkflow(data) {
  const journey = 'conflict-pressure-workflow';
  const state = { customerIds: [], jobIds: [], noteIds: [] };
  const started = Date.now();
  let success = false;
  let workflowError = null;

  group('conflict pressure workflow', () => {
    try {
      const { owner, manager, employeeId } = data;
      const customerId = createCustomer(owner, journey, 'conflict-customer');
      state.customerIds.push(customerId);
      const existingJobId = createJob(owner, journey, customerId, 'conflict-existing', { priority: 'urgent' });
      const competingJobId = createJob(owner, journey, customerId, 'conflict-competing', { priority: 'urgent' });
      state.jobIds.push(existingJobId, competingJobId);

      const slot = futureSlot(80, 2);
      const overlappingSlot = {
        start_time: new Date(new Date(slot.start_time).getTime() + 30 * 60 * 1000).toISOString(),
        end_time: new Date(new Date(slot.end_time).getTime() + 30 * 60 * 1000).toISOString(),
      };

      assignJob(manager, journey, existingJobId, employeeId);
      scheduleJob(manager, journey, existingJobId, slot);
      assignJob(manager, journey, competingJobId, employeeId);
      const conflictResult = checkConflicts(manager, journey, competingJobId, overlappingSlot, employeeId);
      if (!conflictResult.has_conflicts) {
        throw new Error('Expected overlapping schedule to report conflicts');
      }
      expectedConflicts.add(1, baseTags({ journey, role: 'manager', flow: 'scheduling', name: 'expected-conflict' }));
      scheduleJob(manager, journey, competingJobId, overlappingSlot, [409]);
      success = true;
    } catch (error) {
      workflowError = error;
    } finally {
      cleanupCreatedResources(data.owner, journey, state);
      finishWorkflow(journey, 'manager', started, success, workflowError);
    }
  });
  humanPause(0.5);
}

export default function (data) {
  ownerDailyWorkflow(data);
}