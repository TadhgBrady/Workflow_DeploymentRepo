import { expect, test } from '@playwright/test';

import { FrontendApi, idFromPayload } from '../fixtures/api';
import { loginThroughUi } from '../fixtures/auth';
import { runPrefix, todayIsoDate, uniqueEmail } from '../fixtures/env';

test.describe('customer and job browser flow', () => {
  test('owner creates a customer from the job modal and sees the scheduled job on the calendar', async ({
    page,
    request,
  }) => {
    const api = new FrontendApi(request);
    const prefix = runPrefix('job');
    const customerFirstName = 'Playwright';
    const customerLastName = prefix;
    const customerEmail = uniqueEmail(prefix);
    const jobTitle = `${prefix} scheduled kitchen check`;
    const scheduleDate = todayIsoDate();

    let customerId: number | string | undefined;
    let jobId: number | string | undefined;

    try {
      await loginThroughUi(page, 'owner');

      const newJobButton = page.getByRole('button', { name: /new job/i });
      await expect(newJobButton).toBeVisible({ timeout: 20_000 });
      await newJobButton.click();

      const modal = page.locator('#modal-container');
      await expect(modal.getByRole('heading', { name: /create new job/i })).toBeVisible();

      await modal.getByLabel(/job title/i).fill(jobTitle);
      await modal.getByLabel(/description/i).fill('Created by the staging Playwright suite.');
      await modal.getByLabel(/start date/i).fill(scheduleDate);
      await modal.getByLabel(/start time/i).fill('09:30');
      await modal.getByLabel(/end date/i).fill(scheduleDate);
      await modal.getByLabel(/end time/i).fill('11:00');
      await modal.getByLabel(/status/i).selectOption('scheduled');
      await modal.locator('#address').fill('12 River Lane, Galway');
      await modal.locator('#eircode').fill('H91 H6KX');

      await modal.getByRole('button', { name: /new customer/i }).click();
      await expect(modal.getByRole('heading', { name: /^new customer$/i })).toBeVisible();
      await page.locator('#new_customer_first_name').fill(customerFirstName);
      await page.locator('#new_customer_last_name').fill(customerLastName);
      await page.locator('#new_customer_email').fill(customerEmail);
      await page.locator('#new_customer_phone').fill('0871234567');
      await page.locator('#new_customer_company').fill('Playwright QA');
      await page.locator('#new_customer_address').fill('12 River Lane, Galway');
      await page.locator('#new_customer_eircode').fill('H91 H6KX');

      const customerResponsePromise = page.waitForResponse((response) =>
        response.url().includes('/api/customers/') &&
        response.request().method() === 'POST' &&
        response.status() >= 200 &&
        response.status() < 300,
      );
      await modal.getByRole('button', { name: /create.*select/i }).click();
      const customerResponse = await customerResponsePromise;
      const customerResponseBody = await customerResponse.text();
      expect(
        customerResponse.ok(),
        `Customer create failed: ${customerResponse.status()} ${customerResponseBody}`,
      ).toBeTruthy();
      customerId = idFromPayload(JSON.parse(customerResponseBody));
      expect(customerId).toBeTruthy();
      await expect(modal.locator('#customer_id')).toHaveValue(String(customerId));

      const jobResponsePromise = page.waitForResponse((response) =>
        response.url().match(/\/api\/jobs\/?$/) !== null &&
        response.request().method() === 'POST' &&
        response.status() >= 200 &&
        response.status() < 300,
      );
      await modal.getByRole('button', { name: /^create job$/i }).click();
      const jobResponse = await jobResponsePromise;
      const jobResponseBody = await jobResponse.text();
      expect(
        jobResponse.ok(),
        `Job create failed: ${jobResponse.status()} ${jobResponseBody}`,
      ).toBeTruthy();
      jobId = idFromPayload(JSON.parse(jobResponseBody));
      expect(jobId).toBeTruthy();

      await expect(modal.getByRole('heading', { name: /create new job/i })).toBeHidden({
        timeout: 15_000,
      });
      await expect(page.locator('.event-chip', { hasText: jobTitle }).first()).toBeVisible({
        timeout: 20_000,
      });
    } finally {
      await api.login('owner').catch(() => undefined);
      await api.deleteJob(jobId).catch(() => undefined);
      await api.deleteCustomer(customerId).catch(() => undefined);
    }
  });
});