import { expect, test } from '@playwright/test';

import { FrontendApi, idFromPayload } from '../fixtures/api';
import { runPrefix, testAddress, uniqueEmail, uniquePhone } from '../fixtures/env';

test.describe('rbac API enforcement', () => {
  test('viewer cannot create jobs through proxied APIs', async ({ request }) => {
    const api = new FrontendApi(request);
    const prefix = runPrefix('viewer-denied');

    await api.login('viewer');

    const jobResponse = await api.createJobRaw({
      title: `${prefix} forbidden job`,
      status: 'pending',
      priority: 'normal',
      address: testAddress.line,
      eircode: testAddress.eircode,
    });
    expect(jobResponse.status()).toBe(403);
  });

  test('employee cannot delete owner-created jobs', async ({ request }) => {
    const api = new FrontendApi(request);
    const prefix = runPrefix('employee-denied');

    let customerId: number | string | undefined;
    let jobId: number | string | undefined;

    try {
      await api.login('owner');
      const customer = await api.createCustomer({
        first_name: 'Protected',
        last_name: prefix,
        email: uniqueEmail(prefix),
        phone: uniquePhone(prefix),
        company: 'Playwright RBAC',
        address: testAddress.line,
        eircode: testAddress.eircode,
      });
      customerId = idFromPayload(customer);
      expect(customerId).toBeTruthy();

      const job = await api.createJob({
        title: `${prefix} protected job`,
        customer_id: customerId,
        status: 'pending',
        priority: 'normal',
        address: testAddress.line,
        eircode: testAddress.eircode,
      });
      jobId = idFromPayload(job);
      expect(jobId).toBeTruthy();

      await api.login('employee');
      const deleteJobResponse = await api.deleteJobRaw(jobId!);
      expect(deleteJobResponse.status()).toBe(403);
    } finally {
      await api.login('owner').catch(() => undefined);
      await api.deleteJob(jobId).catch(() => undefined);
      await api.deleteCustomer(customerId).catch(() => undefined);
    }
  });
});