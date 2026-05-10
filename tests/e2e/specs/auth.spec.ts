import { expect, test } from '@playwright/test';

import { loginThroughUi, logoutThroughUi } from '../fixtures/auth';

test.describe('authentication browser flow', () => {
  test('rejects invalid credentials without leaving the login page', async ({ page }) => {
    await page.goto('/login');
    await page.getByLabel(/email address/i).fill('owner@demo.com');
    await page.getByLabel(/^password$/i).fill('not-the-demo-password');
    await page.getByRole('button', { name: /sign in/i }).click();

    await expect(page.getByText(/invalid email or password/i)).toBeVisible();
    await expect(page).toHaveURL(/\/login/);
  });

  test('owner signs in and signs out through the UI', async ({ page }) => {
    await loginThroughUi(page, 'owner');

    await expect(page).toHaveURL(/\/calendar/);
    await expect(page.locator('#nav-calendar')).toBeVisible();
    await expect(page.locator('#nav-customers')).toBeVisible();

    await logoutThroughUi(page);
    await expect(page.getByLabel(/email address/i)).toBeVisible();
  });
});