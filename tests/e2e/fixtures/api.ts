import type { APIRequestContext, APIResponse } from '@playwright/test';

import { credentials, type TestRole } from './env';

export interface CustomerInput {
  first_name: string;
  last_name: string;
  email?: string;
  phone?: string;
  company?: string;
  address?: string;
  eircode?: string;
  latitude?: number;
  longitude?: number;
  notify_whatsapp?: boolean;
  notify_email?: boolean;
}

export interface JobInput {
  title: string;
  description?: string;
  customer_id?: number | string;
  assigned_to?: number | string;
  status?: 'pending' | 'scheduled' | 'in_progress' | 'completed' | 'cancelled';
  priority?: 'low' | 'normal' | 'high' | 'urgent';
  start_time?: string;
  end_time?: string;
  estimated_duration?: number;
  address?: string;
  eircode?: string;
  latitude?: number;
  longitude?: number;
  notes?: string;
  send_welcome_email?: boolean;
  send_welcome_whatsapp?: boolean;
}

export interface ScheduleInput {
  assigned_to?: number | string;
  start_time: string;
  end_time: string;
}

export interface ListResponse<T = Record<string, unknown>> {
  items: T[];
  total: number;
  page?: number;
  per_page?: number;
  pages?: number;
}

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

  async deleteJobRaw(jobId: number | string): Promise<APIResponse> {
    return this.request.delete(`/api/jobs/${jobId}`);
  }

  async deleteCustomer(customerId: number | string | undefined): Promise<void> {
    if (!customerId) return;
    await this.request.delete(`/api/customers/${customerId}`);
  }

  async deleteCustomerRaw(customerId: number | string): Promise<APIResponse> {
    return this.request.delete(`/api/customers/${customerId}`);
  }

  async createCustomer(data: CustomerInput): Promise<Record<string, unknown>> {
    return jsonFromResponse(await this.createCustomerRaw(data), 'create customer');
  }

  async createCustomerRaw(data: CustomerInput): Promise<APIResponse> {
    return this.request.post('/api/customers/', { data });
  }

  async updateCustomer(
    customerId: number | string,
    data: Partial<CustomerInput>,
  ): Promise<Record<string, unknown>> {
    return jsonFromResponse(
      await this.request.put(`/api/customers/${customerId}`, { data }),
      `update customer ${customerId}`,
    );
  }

  async listCustomers(params: { search?: string } = {}): Promise<ListResponse> {
    return jsonFromResponse(
      await this.request.get('/api/customers/', { params }),
      'list customers',
    );
  }

  async searchCustomers(query: string): Promise<ListResponse> {
    return jsonFromResponse(
      await this.request.get('/api/customers/search', { params: { q: query } }),
      `search customers for ${query}`,
    );
  }

  async getCustomer(customerId: number | string): Promise<Record<string, unknown>> {
    return jsonFromResponse(
      await this.request.get(`/api/customers/${customerId}`),
      `get customer ${customerId}`,
    );
  }

  async createCustomerNote(
    customerId: number | string,
    content: string,
  ): Promise<Record<string, unknown>> {
    return jsonFromResponse(
      await this.request.post(`/api/notes/${customerId}`, { data: { content } }),
      `create note for customer ${customerId}`,
    );
  }

  async deleteCustomerNote(noteId: number | string | undefined): Promise<void> {
    if (!noteId) return;
    await this.request.delete(`/api/notes/${noteId}`);
  }

  async createJob(data: JobInput): Promise<Record<string, unknown>> {
    return jsonFromResponse(await this.createJobRaw(data), 'create job');
  }

  async createJobRaw(data: JobInput): Promise<APIResponse> {
    return this.request.post('/api/jobs/', { data });
  }

  async updateJob(
    jobId: number | string,
    data: Partial<JobInput>,
  ): Promise<Record<string, unknown>> {
    return jsonFromResponse(
      await this.request.put(`/api/jobs/${jobId}`, { data }),
      `update job ${jobId}`,
    );
  }

  async assignJob(
    jobId: number | string,
    assignedTo: number | string,
    schedule?: Omit<ScheduleInput, 'assigned_to'>,
  ): Promise<Record<string, unknown>> {
    return jsonFromResponse(
      await this.request.post(`/api/jobs/${jobId}/assign`, {
        data: {
          assigned_to: Number(assignedTo),
          ...(schedule || {}),
        },
      }),
      `assign job ${jobId}`,
    );
  }

  async checkJobConflicts(
    jobId: number | string,
    data: ScheduleInput,
  ): Promise<{ has_conflicts: boolean; conflicts: Record<string, unknown>[] }> {
    return jsonFromResponse(
      await this.request.post(`/api/jobs/${jobId}/check-conflicts`, { data }),
      `check job ${jobId} conflicts`,
    );
  }

  async scheduleJob(
    jobId: number | string,
    data: ScheduleInput,
  ): Promise<Record<string, unknown>> {
    return jsonFromResponse(
      await this.request.post(`/api/jobs/${jobId}/schedule`, { data }),
      `schedule job ${jobId}`,
    );
  }

  async listJobs(params: Record<string, string | number> = {}): Promise<ListResponse> {
    return jsonFromResponse(await this.request.get('/api/jobs/', { params }), 'list jobs');
  }

  async getJob(jobId: number | string): Promise<Record<string, unknown>> {
    return jsonFromResponse(await this.request.get(`/api/jobs/${jobId}`), `get job ${jobId}`);
  }

  async listEmployees(): Promise<ListResponse> {
    return jsonFromResponse(await this.request.get('/api/employees/'), 'list employees');
  }
}

export function idFromPayload(payload: unknown): number | string | undefined {
  if (!payload || typeof payload !== 'object') return undefined;
  const record = payload as Record<string, unknown>;
  const id = record.id || record.job_id || record.customer_id;
  return typeof id === 'number' || typeof id === 'string' ? id : undefined;
}

async function jsonFromResponse<T>(response: APIResponse, action: string): Promise<T> {
  const body = await response.text();
  if (!response.ok()) {
    throw new Error(`${action} failed: ${response.status()} ${body}`);
  }

  return body ? (JSON.parse(body) as T) : ({} as T);
}
