import { defineConfig, devices } from '@playwright/test';

const baseURL = process.env.STAGING_URL || process.env.PLAYWRIGHT_BASE_URL || 'http://localhost';
const isCI = !!process.env.CI;
const workers = Number(process.env.PLAYWRIGHT_WORKERS || '1');

export default defineConfig({
  testDir: './specs',
  timeout: 60_000,
  expect: {
    timeout: 12_000,
  },
  fullyParallel: false,
  forbidOnly: isCI,
  retries: isCI ? 2 : 0,
  workers: isCI ? 1 : workers,
  reporter: [
    ['list'],
    ['html', { outputFolder: 'playwright-report', open: 'never' }],
    ['json', { outputFile: 'test-results/playwright-results.json' }],
    ['junit', { outputFile: 'test-results/playwright-junit.xml' }],
  ],
  use: {
    baseURL,
    actionTimeout: 15_000,
    navigationTimeout: 30_000,
    trace: 'on-first-retry',
    screenshot: 'only-on-failure',
    video: 'retain-on-failure',
    ignoreHTTPSErrors: true,
  },
  projects: [
    {
      name: 'chromium',
      use: { ...devices['Desktop Chrome'] },
    },
  ],
  metadata: {
    target: baseURL,
    environment: process.env.PLAYWRIGHT_ENVIRONMENT || 'staging',
    imageVersion: process.env.IMAGE_VERSION || 'unknown',
    pipelineId: process.env.CI_PIPELINE_ID || 'local',
    jobId: process.env.CI_JOB_ID || 'local',
  },
});