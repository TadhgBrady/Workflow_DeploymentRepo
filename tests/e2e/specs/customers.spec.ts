import { expect, test } from '@playwright/test';

import { FrontendApi, idFromPayload } from '../fixtures/api';
import { loginThroughUi } from '../fixtures/auth';
import { runPrefix, testAddress, uniqueEmail, uniquePhone } from '../fixtures/env';

test.describe('customer management browser flow', () => {
  test('owner searches for a customer, opens details, and adds a note', async ({
    page,
    request,
  }) => {
    const api = new FrontendApi(request);
    const prefix = runPrefix('customer');
    const firstName = 'Playwright';
    const lastName = prefix;
    const customerEmail = uniqueEmail(prefix);
    const noteText = `${prefix} detail note`;

    let customerId: number | string | undefined;
    let noteId: number | string | undefined;

    try {
      await api.login('owner');
      const customer = await api.createCustomer({
        first_name: firstName,
        last_name: lastName,
        email: customerEmail,
        phone: uniquePhone(prefix),
        company: 'Playwright QA',
        address: testAddress.line,
        eircode: testAddress.eircode,
        latitude: testAddress.latitude,
        longitude: testAddress.longitude,
        notify_email: true,
      });
      customerId = idFromPayload(customer);
      expect(customerId).toBeTruthy();

      await loginThroughUi(page, 'owner', '/customers');
      await expect(page.getByRole('heading', { name: /^customers$/i })).toBeVisible();

      const searchResponse = page.waitForResponse((response) => {
        const url = response.url();
        return (
          url.includes('/api/customers') &&
          url.includes(encodeURIComponent(customerEmail)) &&
          response.request().method() === 'GET' &&
          response.status() === 200
        );
      });
      await page.getByPlaceholder(/search by name, email or phone/i).fill(customerEmail);
      await searchResponse;

      const row = page.locator('tr.customer-row', { hasText: customerEmail }).first();
      await expect(row).toBeVisible({ timeout: 15_000 });
      await expect(row).toContainText(firstName);
      await expect(row).toContainText('Playwright QA');

      const detailResponse = page.waitForResponse((response) =>
        response.url().includes(`/api/customers/${customerId}`) && response.status() === 200,
      );
      await row.click();
      await detailResponse;

      await expect(page.getByRole('heading', { name: /customer details/i })).toBeVisible();
      await expect(page.locator(`a[href="mailto:${customerEmail}"]`)).toBeVisible();
      await expect(page.locator('dd', { hasText: testAddress.line })).toBeVisible();
      await expect(page.locator('dd', { hasText: testAddress.eircode })).toBeVisible();

      await page.getByRole('button', { name: /add note/i }).click();
      await page.getByPlaceholder(/write a note/i).fill(noteText);

      const noteResponsePromise = page.waitForResponse((response) =>
        response.url().includes(`/api/notes/${customerId}`) &&
        response.request().method() === 'POST' &&
        response.status() >= 200 &&
        response.status() < 300,
      );
      await page.getByRole('button', { name: /save note/i }).click();
      const noteResponse = await noteResponsePromise;
      noteId = idFromPayload(await noteResponse.json());

      await expect(page.getByText(noteText)).toBeVisible({ timeout: 10_000 });
    } finally {
      await api.login('owner').catch(() => undefined);
      await api.deleteCustomerNote(noteId).catch(() => undefined);
      await api.deleteCustomer(customerId).catch(() => undefined);
    }
  });
});