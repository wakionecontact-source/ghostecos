import { ApiError, requestJson } from '../api/http';

const CLIENT_ID = 'ghostchat';

export interface RefreshedTokens {
  token: string;
  expiresAt: number;
  refreshToken?: string;
  refreshExpiresAt?: number;
}

interface RefreshResponse {
  access_token: string;
  refresh_token?: string;
  expires_in: number;
  refresh_expires_in?: number;
}

/**
 * Меняет refresh-токен GhostID на новую пару.
 * 401 значит, что сессию GhostID отозвали: продлевать нечего, нужен вход.
 */
export async function refreshGhostIdTokens(refreshToken: string): Promise<RefreshedTokens> {
  const data = await refreshTokens(refreshToken);
  return {
    token: data.access_token,
    expiresAt: Date.now() + data.expires_in * 1000,
    refreshToken: data.refresh_token,
    refreshExpiresAt: data.refresh_expires_in
      ? Date.now() + data.refresh_expires_in * 1000
      : undefined,
  };
}

/** Продление через v2; прежний SSO остаётся откатом, пока v2-маршрута нет. */
async function refreshTokens(refreshToken: string): Promise<RefreshResponse> {
  try {
    return await requestJson<RefreshResponse>('/api/v2/auth/token', {
      body: { grant_type: 'refresh_token', client_id: CLIENT_ID, refresh_token: refreshToken },
    });
  } catch (cause) {
    if (!(cause instanceof ApiError) || (cause.status !== 404 && cause.status < 500)) throw cause;
    return requestJson<RefreshResponse>('/api/sso/refresh', {
      body: { client_id: CLIENT_ID, refresh_token: refreshToken },
    });
  }
}
