import { expect, type Page } from '@playwright/test';

import { credentials, type TestRole } from './env';

export async function dismissCookieBanner(page: Page): Promise<void> {
  const gotItButton = page.getByRole('button', { name: /^got it$/i });
  if (await gotItButton.isVisible({ timeout: 2_000 }).catch(() => false)) {
    await gotItButton.click({ timeout: 3_000 }).catch(async (error: unknown) => {
      const privacyDialog = page.getByRole('heading', { name: /privacy policy consent/i });
      if (!(await privacyDialog.isVisible({ timeout: 1_000 }).catch(() => false))) {
        throw error;
      }

      await acceptPrivacyConsentIfShown(page);
      await gotItButton.click({ timeout: 5_000 });
    });
    await expect(gotItButton).toBeHidden({ timeout: 5_000 });
  }
}

export async function acceptPrivacyConsentIfShown(page: Page): Promise<void> {
  const privacyDialog = page.getByRole('heading', { name: /privacy policy consent/i });
  if (!(await privacyDialog.isVisible({ timeout: 7_500 }).catch(() => false))) {
    return;
  }

  await page.locator('#privacy-consent-checkbox').check();
  const acceptButton = page.getByRole('button', { name: /accept.*continue/i });
  await expect(acceptButton).toBeEnabled({ timeout: 5_000 });
  await acceptButton.click();
  await expect(privacyDialog).toBeHidden({ timeout: 15_000 });
}

export async function settleAuthenticatedPage(page: Page): Promise<void> {
  await acceptPrivacyConsentIfShown(page);
  await dismissCookieBanner(page);
}

export async function loginThroughUi(
  page: Page,
  role: TestRole = 'owner',
  nextPath?: string,
): Promise<void> {
  const account = credentials[role];
  const loginPath = nextPath ? `/login?next=${encodeURIComponent(nextPath)}` : '/login';

  await page.goto(loginPath);
  await page.getByLabel(/email address/i).fill(account.email);
  await page.getByLabel(/^password$/i).fill(account.password);
  const consentStatusResponse = page
    .waitForResponse((response) => response.url().includes('/api/users/me/consent-status'), {
      timeout: 15_000,
    })
    .catch(() => undefined);

  await Promise.all([
    page.waitForURL((url) => !url.pathname.startsWith('/login'), { timeout: 30_000 }),
    page.getByRole('button', { name: /sign in/i }).click(),
  ]);

  await consentStatusResponse;
  await settleAuthenticatedPage(page);
}

export async function logoutThroughUi(page: Page): Promise<void> {
  await page.getByRole('button', { name: /open user menu/i }).click();
  await page.getByRole('button', { name: /sign out/i }).click();
  await expect(page).toHaveURL(/\/login$/);
}