import { expect, test } from '@playwright/test';

import { loginThroughUi } from '../fixtures/auth';

test.describe('calendar browser flow', () => {
  test.beforeEach(async ({ page }) => {
    await loginThroughUi(page, 'owner');
  });

  test('month navigation and view switches update the HTMX calendar container', async ({ page }) => {
    await expect(page.locator('#calendar-container')).toBeVisible();
    await expect(page.locator('#calendar-grid')).toBeVisible();
    await expect(page.locator('#current-view')).toHaveValue('month');

    const heading = page.locator('#calendar-container h1').first();
    const nextButton = page.getByRole('button', { name: /^next$/i });
    const nextUrl = await nextButton.getAttribute('hx-get');
    expect(nextUrl).toBeTruthy();
    const nextParams = new URL(nextUrl || '', page.url()).searchParams;
    const expectedNextHeading = new Intl.DateTimeFormat('en-GB', {
      month: 'long',
      year: 'numeric',
    }).format(
      new Date(Number(nextParams.get('year')), Number(nextParams.get('month')) - 1, 1),
    );

    const nextMonthResponse = page.waitForResponse((response) =>
      response.url().includes('/calendar/container') && response.status() === 200,
    );
    await nextButton.click();
    await nextMonthResponse;
    await expect(heading).toHaveText(expectedNextHeading, { timeout: 15_000 });
    await expect(page.locator('#current-view')).toHaveValue('month');

    const weekResponse = page.waitForResponse((response) =>
      response.url().includes('/calendar/week') && response.status() === 200,
    );
    await page.getByRole('button', { name: /^week$/i }).click();
    await weekResponse;
    await expect(page.locator('#current-view')).toHaveValue('week');
    await expect(page.locator('.week-grid')).toBeVisible();

    const dayResponse = page.waitForResponse((response) =>
      response.url().includes('/calendar/day-view/') && response.status() === 200,
    );
    await page.getByRole('button', { name: /^day$/i }).click();
    await dayResponse;
    await expect(page.locator('#current-view')).toHaveValue('day');
    await expect(page.locator('.day-timeline')).toBeVisible();
  });
});