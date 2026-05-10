import { expect, test } from '@playwright/test';

import { FrontendApi, idFromPayload } from '../fixtures/api';
import { loginThroughUi } from '../fixtures/auth';
import { isoDateTime, runPrefix, testAddress, todayIsoDate, uniqueEmail, uniquePhone } from '../fixtures/env';

test.describe('job scheduling browser flow', () => {
  test('owner sees conflict detection, assigns jobs, and verifies calendar visibility', async ({
    page,
    request,
  }) => {
    const api = new FrontendApi(request);
    const prefix = runPrefix('schedule');
    const scheduleDate = todayIsoDate();
    const firstJobTitle = `${prefix} boiler service`;
    const secondJobTitle = `${prefix} follow up`;

    let customerId: number | string | undefined;
    let firstJobId: number | string | undefined;
    let secondJobId: number | string | undefined;

    try {
      await api.login('owner');
      const employees = await api.listEmployees();
      const employee = employees.items.find((item) => item.id);
      const employeeId = employee?.id;
      test.skip(!employeeId, 'No seeded employee is available for assignment coverage.');

      const customer = await api.createCustomer({
        first_name: 'Playwright',
        last_name: prefix,
        email: uniqueEmail(prefix),
        phone: uniquePhone(prefix),
        company: 'Playwright Scheduling',
        address: testAddress.line,
        eircode: testAddress.eircode,
      });
      customerId = idFromPayload(customer);
      expect(customerId).toBeTruthy();

      const firstJob = await api.createJob({
        title: firstJobTitle,
        description: 'Seeded by Playwright to verify conflict detection.',
        customer_id: customerId,
        status: 'pending',
        priority: 'high',
        address: testAddress.line,
        eircode: testAddress.eircode,
        estimated_duration: 45,
      });
      firstJobId = idFromPayload(firstJob);
      expect(firstJobId).toBeTruthy();

      await api.assignJob(firstJobId!, employeeId, {
        start_time: isoDateTime(scheduleDate, '20:00'),
        end_time: isoDateTime(scheduleDate, '20:45'),
      });

      const secondJob = await api.createJob({
        title: secondJobTitle,
        description: 'Seeded by Playwright to verify non-overlapping assignment.',
        customer_id: customerId,
        status: 'pending',
        priority: 'normal',
        address: testAddress.line,
        eircode: testAddress.eircode,
        estimated_duration: 30,
      });
      secondJobId = idFromPayload(secondJob);
      expect(secondJobId).toBeTruthy();

      const conflicts = await api.checkJobConflicts(secondJobId!, {
        assigned_to: employeeId,
        start_time: isoDateTime(scheduleDate, '20:15'),
        end_time: isoDateTime(scheduleDate, '20:40'),
      });
      expect(conflicts.has_conflicts).toBe(true);
      expect(conflicts.conflicts.some((conflict) => conflict.conflicting_job_title === firstJobTitle)).toBe(
        true,
      );

      const assignedSecondJob = await api.assignJob(secondJobId!, employeeId, {
        start_time: isoDateTime(scheduleDate, '20:45'),
        end_time: isoDateTime(scheduleDate, '21:15'),
      });
      expect(assignedSecondJob.status).toBe('scheduled');

      const customerJobs = await api.listJobs({ customer_id: customerId! });
      const customerJobTitles = customerJobs.items.map((job) => job.title);
      expect(customerJobTitles).toContain(firstJobTitle);
      expect(customerJobTitles).toContain(secondJobTitle);

      await loginThroughUi(page, 'owner', '/calendar');
      await expect(page.locator('#calendar-container')).toBeVisible();
      await expect(page.locator('.event-chip', { hasText: firstJobTitle }).first()).toBeVisible({
        timeout: 20_000,
      });
      await expect(page.locator('.event-chip', { hasText: secondJobTitle }).first()).toBeVisible({
        timeout: 20_000,
      });
    } finally {
      await api.login('owner').catch(() => undefined);
      await api.deleteJob(secondJobId).catch(() => undefined);
      await api.deleteJob(firstJobId).catch(() => undefined);
      await api.deleteCustomer(customerId).catch(() => undefined);
    }
  });
});