import { expect, test } from '@playwright/test';

import { loginThroughUi } from '../fixtures/auth';

test.describe('role-based browser access', () => {
  test('employee is redirected away from the admin portal', async ({ page }) => {
    await loginThroughUi(page, 'employee', '/admin');

    await expect(page).toHaveURL(/\/calendar/);
    await expect(page.getByRole('heading', { name: /admin portal/i })).toBeHidden();
    await expect(page.locator('#admin-nav-link')).toBeHidden();
  });

  test('superadmin reaches the admin portal and sees platform tabs', async ({ page }) => {
    await loginThroughUi(page, 'superadmin');

    await expect(page).toHaveURL(/\/admin/);
    await expect(page.getByRole('heading', { name: /admin portal/i })).toBeVisible();
    await expect(page.locator('#admin-nav-link')).toBeVisible();
    await expect(page.locator('#nav-calendar')).toBeHidden();
    await expect(page.getByRole('button', { name: /organizations/i })).toBeVisible();
    await expect(page.getByRole('button', { name: /^users$/i })).toBeVisible();
    await expect(page.getByRole('button', { name: /audit logs/i })).toBeVisible();
    await expect(page.getByRole('button', { name: /^settings$/i })).toBeVisible();
  });
});