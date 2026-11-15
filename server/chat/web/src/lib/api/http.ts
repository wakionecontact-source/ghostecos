export class ApiError extends Error {
  readonly status: number;
  readonly code?: string;

  constructor(status: number, message: string, code?: string) {
    super(message);
    this.name = 'ApiError';
    this.status = status;
    this.code = code;
  }
}

export interface RequestOptions {
  method?: 'GET' | 'POST' | 'PUT' | 'PATCH' | 'DELETE';
  body?: unknown;
  token?: string;
  signal?: AbortSignal;
  form?: FormData;
}

/** Единая точка ошибок: сервер отдаёт detail строкой или объектом. */
export async function requestJson<T>(path: string, options: RequestOptions = {}): Promise<T> {
  const headers: Record<string, string> = { Accept: 'application/json' };
  if (options.token) headers.Authorization = `Bearer ${options.token}`;
  if (options.body !== undefined) headers['Content-Type'] = 'application/json';

  const response = await fetch(path, {
    method: options.method ?? (options.body !== undefined || options.form ? 'POST' : 'GET'),
    headers,
    body: options.form ?? (options.body === undefined ? undefined : JSON.stringify(options.body)),
    signal: options.signal,
    credentials: 'same-origin',
  });

  const text = await response.text();
  let payload: unknown = null;
  if (text) {
    try {
      payload = JSON.parse(text);
    } catch {
      payload = null;
    }
  }

  if (!response.ok) {
    const detail = (payload as { detail?: unknown } | null)?.detail;
    const message = typeof detail === 'string' ? detail : `Ошибка сервера (${response.status})`;
    const code = (payload as { code?: string } | null)?.code;
    throw new ApiError(response.status, message, code);
  }

  return payload as T;
}
