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

type TokenRefresher = (staleToken: string) => Promise<string | null>;

let refresher: TokenRefresher | null = null;

/** Продление токена сессии: 401 → один повтор с новым токеном. */
export function setTokenRefresher(handler: TokenRefresher | null): void {
  refresher = handler;
}

function buildInit(options: RequestOptions, token?: string): RequestInit {
  const headers: Record<string, string> = { Accept: 'application/json' };
  if (token) headers.Authorization = `Bearer ${token}`;
  if (options.body !== undefined) headers['Content-Type'] = 'application/json';
  return {
    method: options.method ?? (options.body !== undefined || options.form ? 'POST' : 'GET'),
    headers,
    body: options.form ?? (options.body === undefined ? undefined : JSON.stringify(options.body)),
    signal: options.signal,
    credentials: 'same-origin',
  };
}

/** Единая точка ошибок: сервер отдаёт detail строкой или объектом. */
export async function requestJson<T>(path: string, options: RequestOptions = {}): Promise<T> {
  let response = await fetch(path, buildInit(options, options.token));

  // Сессия GhostID живёт дольше токена сервиса — меняем его без перезагрузки страницы.
  if (response.status === 401 && options.token && refresher) {
    const fresh = await refresher(options.token);
    if (fresh) response = await fetch(path, buildInit(options, fresh));
  }

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
