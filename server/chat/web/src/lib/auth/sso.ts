import { requestJson } from '../api/http';
import { createPkce, createState, safeEqual } from './pkce';

const CLIENT_ID = 'ghostchat';
const SCOPES = ['identity', 'profile', 'chat'];
const CALLBACK_PATH = '/v2/chat/sso/callback';
const STORAGE_PREFIX = 'gc.sso.';

interface EntranceResponse {
  request_id: string;
  authorization_url: string;
  state: string;
  redirect_uri: string;
  expires_in: number;
}

interface TokenResponse {
  access_token: string;
  token_type: string;
  expires_in: number;
  scope: string;
}

export interface SsoSession {
  token: string;
  scopes: string[];
  expiresAt: number;
}

function redirectUri(): string {
  return `${location.origin}${CALLBACK_PATH}`;
}

/** Начинаем вход: PKCE и state живут только на время перехода. */
export async function startLogin(): Promise<void> {
  const pkce = await createPkce();
  const state = createState();
  const entrance = await requestJson<EntranceResponse>('/api/sso/entrance', {
    body: {
      client_id: CLIENT_ID,
      redirect_uri: redirectUri(),
      scopes: SCOPES,
      state,
      code_challenge: pkce.challenge,
      code_challenge_method: 'S256',
      prompt: 'select_account',
    },
  });

  sessionStorage.setItem(`${STORAGE_PREFIX}verifier`, pkce.verifier);
  sessionStorage.setItem(`${STORAGE_PREFIX}state`, state);
  location.assign(entrance.authorization_url);
}

export interface SsoUserInfo {
  sub: string;
  username: string;
  name?: string;
  picture?: string;
}

export async function fetchUserInfo(token: string): Promise<SsoUserInfo> {
  return requestJson<SsoUserInfo>('/api/sso/userinfo', { token });
}

export class SsoCallbackError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'SsoCallbackError';
  }
}

/** Callback GhostID: код меняется на токен доступа сервиса. */
export async function completeLogin(params: URLSearchParams): Promise<SsoSession> {
  const error = params.get('error');
  if (error) throw new SsoCallbackError(error === 'access_denied' ? 'Доступ отклонён' : `Ошибка входа: ${error}`);

  const code = params.get('code');
  const state = params.get('state');
  if (!code || !state) throw new SsoCallbackError('GhostID не вернул код');

  const expectedState = sessionStorage.getItem(`${STORAGE_PREFIX}state`);
  if (!expectedState || !safeEqual(expectedState, state)) {
    throw new SsoCallbackError('Не совпал state — вход нужно начать заново');
  }
  const verifier = sessionStorage.getItem(`${STORAGE_PREFIX}verifier`);
  if (!verifier) throw new SsoCallbackError('Нет PKCE-verifier — вход нужно начать заново');

  const token = await requestJson<TokenResponse>('/api/sso/token', {
    body: {
      grant_type: 'authorization_code',
      client_id: CLIENT_ID,
      code,
      redirect_uri: redirectUri(),
      code_verifier: verifier,
    },
  });

  sessionStorage.removeItem(`${STORAGE_PREFIX}state`);
  sessionStorage.removeItem(`${STORAGE_PREFIX}verifier`);

  return {
    token: token.access_token,
    scopes: token.scope.split(' ').filter(Boolean),
    expiresAt: Date.now() + token.expires_in * 1000,
  };
}
