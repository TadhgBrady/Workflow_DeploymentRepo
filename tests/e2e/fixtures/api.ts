import type { APIRequestContext } from '@playwright/test';

import { credentials, type TestRole } from './env';

export class FrontendApi {
  constructor(private readonly request: APIRequestContext) {}

  async login(role: TestRole = 'owner'): Promise<void> {
    const account = credentials[role];
    const response = await this.request.post('/api/auth/login', {
      data: {
        email: account.email,
        password: account.password,
      },
    });

    if (!response.ok()) {
      throw new Error(`API login failed for ${role}: ${response.status()} ${await response.text()}`);
    }
  }

  async deleteJob(jobId: number | string | undefined): Promise<void> {
    if (!jobId) return;
    await this.request.delete(`/api/jobs/${jobId}`);
  }

  async deleteCustomer(customerId: number | string | undefined): Promise<void> {
    if (!customerId) return;
    await this.request.delete(`/api/customers/${customerId}`);
  }
}

export function idFromPayload(payload: unknown): number | string | undefined {
  if (!payload || typeof payload !== 'object') return undefined;
  const record = payload as Record<string, unknown>;
  const id = record.id || record.job_id || record.customer_id;
  return typeof id === 'number' || typeof id === 'string' ? id : undefined;
}