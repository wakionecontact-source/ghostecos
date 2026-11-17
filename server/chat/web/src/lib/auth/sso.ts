import { ApiError, requestJson } from '../api/http';
import { createPkce, createState, safeEqual } from './pkce';

const CLIENT_ID = 'ghostchat';
// Просим весь каталог: пользователь сам снимет лишнее в анкете GhostID.
const SCOPES = ['identity', 'profile', 'password', 'device', 'chat'];
const CALLBACK_PATH = '/v2/chat/sso/callback';
const STORAGE_PREFIX = 'gc.sso.';
const VAULT_ALG = 'AES-256-GCM';
const VAULT_KDF = 'HKDF-SHA256';

interface AuthorizeResponse {
  requestId: string;
  url: string;
}

interface EntranceResponse {
  request_id: string;
  authorization_url: string;
}

interface MeResponse {
  id: number;
  username: string;
  displayName?: string;
  avatarUrl?: string | null;
}

interface SealedPassword {
  alg: string;
  kdf: { name: string; salt: string; info: string; secret: string };
  aad: string;
  nonce: string;
  ciphertext: string;
}

interface TokenResponse {
  access_token: string;
  refresh_token?: string;
  token_type: string;
  expires_in: number;
  refresh_expires_in?: number;
  scope?: string;
  scopes?: string[];
  vault?: SealedPassword;
}

export interface SsoSession {
  token: string;
  scopes: string[];
  expiresAt: number;
  /** Токен GhostID на этот сервис: им клиент продлевает сессию без повторного входа. */
  refreshToken?: string;
  refreshExpiresAt?: number;
  /** Пароль из сейва GhostID, если пользователь выдал этот доступ. */
  password?: string;
}

function redirectUri(): string {
  return `${location.origin}${CALLBACK_PATH}`;
}

/** Откат на замороженный SSO нужен только там, где маршрута v2 нет вовсе. */
function v2Unavailable(cause: unknown): boolean {
  return cause instanceof ApiError && (cause.status === 404 || cause.status >= 500);
}

/** Начинаем вход: PKCE и state живут только на время перехода. */
export async function startLogin(): Promise<void> {
  const pkce = await createPkce();
  const state = createState();
  const entrance = await entranceUrl(pkce.challenge, state);

  sessionStorage.setItem(`${STORAGE_PREFIX}verifier`, pkce.verifier);
  sessionStorage.setItem(`${STORAGE_PREFIX}state`, state);
  location.assign(entrance);
}

/** Ссылка на анкету GhostID: сначала v2, при его недоступности — прежний SSO. */
async function entranceUrl(challenge: string, state: string): Promise<string> {
  try {
    const started = await requestJson<AuthorizeResponse>('/api/v2/auth/authorize', {
      body: {
        client_id: CLIENT_ID,
        redirect_uri: redirectUri(),
        scopes: SCOPES,
        state,
        challenge,
      },
    });
    return started.url;
  } catch (cause) {
    if (!v2Unavailable(cause)) throw cause;
    const legacy = await requestJson<EntranceResponse>('/api/sso/entrance', {
      body: {
        client_id: CLIENT_ID,
        redirect_uri: redirectUri(),
        scopes: SCOPES,
        state,
        code_challenge: challenge,
        code_challenge_method: 'S256',
        prompt: 'select_account',
      },
    });
    return legacy.authorization_url;
  }
}

export interface SsoUserInfo {
  sub: string;
  username: string;
  name?: string;
  picture?: string;
}

export async function fetchUserInfo(token: string): Promise<SsoUserInfo> {
  try {
    const me = await requestJson<MeResponse>('/api/v2/auth/me', { token });
    return {
      sub: String(me.id),
      username: me.username,
      name: me.displayName,
      picture: me.avatarUrl ?? undefined,
    };
  } catch (cause) {
    if (!v2Unavailable(cause)) throw cause;
    return requestJson<SsoUserInfo>('/api/sso/userinfo', { token });
  }
}

export class SsoCallbackError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'SsoCallbackError';
  }
}

function fromBase64(value: string): ArrayBuffer {
  const binary = atob(value);
  const bytes = new Uint8Array(new ArrayBuffer(binary.length));
  for (let index = 0; index < binary.length; index += 1) {
    bytes[index] = binary.charCodeAt(index);
  }
  return bytes.buffer;
}

/** Пароль из сейфа GhostID: ключ выводится из PKCE-verifier этого входа. */
async function openSealedPassword(
  vault: SealedPassword,
  verifier: string,
): Promise<string | undefined> {
  if (vault.alg !== VAULT_ALG || vault.kdf?.name !== VAULT_KDF || vault.kdf.secret !== 'code_verifier') {
    return undefined;
  }
  const encoder = new TextEncoder();
  const base = await crypto.subtle.importKey('raw', encoder.encode(verifier), 'HKDF', false, ['deriveKey']);
  const key = await crypto.subtle.deriveKey(
    {
      name: 'HKDF',
      hash: 'SHA-256',
      salt: encoder.encode(vault.kdf.salt),
      info: encoder.encode(vault.kdf.info),
    },
    base,
    { name: 'AES-GCM', length: 256 },
    false,
    ['decrypt'],
  );
  try {
    const plain = await crypto.subtle.decrypt(
      { name: 'AES-GCM', iv: fromBase64(vault.nonce), additionalData: encoder.encode(vault.aad) },
      key,
      fromBase64(vault.ciphertext),
    );
    return new TextDecoder().decode(plain);
  } catch {
    // Сейф не открылся — пароль спросим вручную, вход не ломаем.
    return undefined;
  }
}

/** Код меняется на токен сервиса: сначала v2, при его недоступности — прежний SSO. */
async function exchangeCode(code: string, verifier: string): Promise<TokenResponse> {
  try {
    return await requestJson<TokenResponse>('/api/v2/auth/token', {
      body: {
        grant_type: 'authorization_code',
        client_id: CLIENT_ID,
        code,
        redirect_uri: redirectUri(),
        code_verifier: verifier,
      },
    });
  } catch (cause) {
    if (!v2Unavailable(cause)) throw cause;
    return requestJson<TokenResponse>('/api/sso/token', {
      body: {
        grant_type: 'authorization_code',
        client_id: CLIENT_ID,
        code,
        redirect_uri: redirectUri(),
        code_verifier: verifier,
      },
    });
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

  const token = await exchangeCode(code, verifier);

  sessionStorage.removeItem(`${STORAGE_PREFIX}state`);
  sessionStorage.removeItem(`${STORAGE_PREFIX}verifier`);

  const password = token.vault ? await openSealedPassword(token.vault, verifier) : undefined;

  return {
    token: token.access_token,
    scopes: token.scopes ?? (token.scope ? token.scope.split(' ').filter(Boolean) : []),
    expiresAt: Date.now() + token.expires_in * 1000,
    refreshToken: token.refresh_token,
    refreshExpiresAt: token.refresh_expires_in
      ? Date.now() + token.refresh_expires_in * 1000
      : undefined,
    password,
  };
}
