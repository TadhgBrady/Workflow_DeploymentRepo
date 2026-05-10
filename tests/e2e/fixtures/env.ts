export type TestRole = 'owner' | 'manager' | 'employee' | 'viewer' | 'superadmin';

export interface TestCredentials {
  email: string;
  password: string;
}

const demoPassword = process.env.PLAYWRIGHT_DEMO_USER_PASSWORD || 'password123';

export const credentials: Record<TestRole, TestCredentials> = {
  owner: {
    email: process.env.PLAYWRIGHT_OWNER_EMAIL || 'owner@demo.com',
    password: process.env.PLAYWRIGHT_OWNER_PASSWORD || demoPassword,
  },
  manager: {
    email: process.env.PLAYWRIGHT_MANAGER_EMAIL || 'manager@demo.com',
    password: process.env.PLAYWRIGHT_MANAGER_PASSWORD || demoPassword,
  },
  employee: {
    email: process.env.PLAYWRIGHT_EMPLOYEE_EMAIL || 'employee@demo.com',
    password: process.env.PLAYWRIGHT_EMPLOYEE_PASSWORD || demoPassword,
  },
  viewer: {
    email: process.env.PLAYWRIGHT_VIEWER_EMAIL || 'viewer@demo.com',
    password: process.env.PLAYWRIGHT_VIEWER_PASSWORD || demoPassword,
  },
  superadmin: {
    email: process.env.PLAYWRIGHT_SUPERADMIN_EMAIL || 'superadmin@system.local',
    password: process.env.PLAYWRIGHT_SUPERADMIN_PASSWORD || 'SuperAdmin123!',
  },
};

export function runPrefix(label: string): string {
  const pipelineId = process.env.CI_PIPELINE_ID || 'local';
  const jobId = process.env.CI_JOB_ID || String(Date.now());
  return `pw-${pipelineId}-${jobId}-${label}`.toLowerCase();
}

export function uniqueEmail(prefix: string): string {
  const sanitizedPrefix = prefix.replace(/[^a-z0-9-]/gi, '-').toLowerCase();
  return `${sanitizedPrefix}@playwright-e2e.dev`;
}

export function todayIsoDate(): string {
  const today = new Date();
  const year = today.getFullYear();
  const month = String(today.getMonth() + 1).padStart(2, '0');
  const day = String(today.getDate()).padStart(2, '0');
  return `${year}-${month}-${day}`;
}