import { requestJson } from '../api/http';
import { toBase64, utf8 } from '../crypto/bytes';
import { loadOrCreateBrowserKey, sha256Hex, signBrowserProof } from './device-keys';
import { refreshGhostIdTokens } from './ghostid';

const DEVICE_NAME = 'GhostChat Web';
const PROOF_DOMAIN = 'ghostchat-web-device:v2';
const SESSION_KEY = 'gc.web.session';
const REFRESH_MARGIN_MS = 30_000;

/** Часть сессии GhostID, которую несёт refresh-токен сервиса. */
export type RefreshPart = Pick<WebSession, 'refreshToken' | 'refreshExpiresAt'>;

export interface WebSession {
  token: string;
  deviceId: number;
  userId: string;
  username: string;
  expiresAt: number;
  /** Держит сессию живой после истечения access-токена. */
  refreshToken?: string;
  refreshExpiresAt?: number;
}

export interface ApprovalRequired {
  status: 'approval_required';
  approvalId: string;
  code?: string;
  expiresIn: number;
}

export type EnrollmentResult = WebSession | ApprovalRequired;

interface SessionResponse {
  status: 'ready' | 'approval_required' | 'pending' | 'approved' | 'expired';
  device_id?: number;
  user_id?: string;
  expires_at?: number;
  approval_id?: string;
  code?: string;
  expires_in?: number;
}

export type ApprovalPoll = WebSession | 'pending' | 'expired';

function proofMessage(timestamp: number, tokenHash: string): Uint8Array {
  return utf8(`${PROOF_DOMAIN}\n${tokenHash}\n${timestamp}`);
}

function readySession(
  response: SessionResponse,
  token: string,
  username: string,
  refresh?: RefreshPart,
): WebSession {
  return {
    token,
    deviceId: response.device_id as number,
    userId: response.user_id as string,
    username,
    expiresAt: (response.expires_at as number) * 1000,
    ...refresh,
  };
}

/** Enrollment привязывает браузер к нативному устройству через TDA-одобрение. */
export async function enroll(
  token: string,
  username: string,
  refresh?: RefreshPart,
): Promise<EnrollmentResult> {
  const browser = await loadOrCreateBrowserKey();
  const timestamp = Math.floor(Date.now() / 1000);
  const tokenHash = await sha256Hex(token);
  const proof = await signBrowserProof(browser, proofMessage(timestamp, tokenHash));

  const response = await requestJson<SessionResponse>('/api/chat/v2/client/session', {
    token,
    body: {
      browser_pub: toBase64(browser.publicKey),
      proof: toBase64(proof),
      timestamp,
      device_name: DEVICE_NAME,
    },
  });

  if (response.status === 'ready' && response.device_id && response.user_id && response.expires_at) {
    return readySession(response, token, username, refresh);
  }
  if (response.status === 'approval_required' && response.approval_id) {
    return {
      status: 'approval_required',
      approvalId: response.approval_id,
      code: response.code,
      expiresIn: response.expires_in ?? 0,
    };
  }
  throw new Error('Сервер вернул неизвестное состояние входа');
}

/** Опрос одобрения: pending → approved (готово) либо expired. */
export async function pollApproval(
  token: string,
  approvalId: string,
  username: string,
  refresh?: RefreshPart,
): Promise<ApprovalPoll> {
  const response = await requestJson<SessionResponse>(
    `/api/chat/v2/client/session/approval/${encodeURIComponent(approvalId)}`,
    { token },
  );

  if (response.status === 'ready' && response.device_id && response.user_id && response.expires_at) {
    return readySession(response, token, username, refresh);
  }
  if (response.status === 'expired') return 'expired';
  return 'pending';
}

/**
 * Новый токен после refresh не связан с устройством в базе сервера.
 * Повторный enroll возвращает прежнее устройство по ключу браузера, без одобрения.
 */
export async function ensureDevice(session: WebSession): Promise<WebSession> {
  try {
    const result = await enroll(session.token, session.username, session);
    return 'deviceId' in result ? result : session;
  } catch {
    // Сеть или чужое устройство — работаем с тем, что есть.
    return session;
  }
}

export function saveSession(session: WebSession): void {
  localStorage.setItem(SESSION_KEY, JSON.stringify(session));
}

export function loadSession(): WebSession | null {
  const raw = localStorage.getItem(SESSION_KEY);
  if (!raw) return null;
  try {
    const parsed = JSON.parse(raw) as WebSession;
    if (!parsed.token || !parsed.deviceId) return null;
    if (parsed.expiresAt > Date.now()) return parsed;
    // Токен истёк, но сессия GhostID жива — продлим при загрузке, вход не просим.
    if (parsed.refreshToken && (parsed.refreshExpiresAt ?? 0) > Date.now()) return parsed;
    return null;
  } catch {
    return null;
  }
}

/** Меняет access-токен на свежий, пока жива сессия GhostID. */
export async function ensureFresh(session: WebSession): Promise<WebSession | null> {
  if (session.expiresAt > Date.now() + REFRESH_MARGIN_MS) return session;
  if (!session.refreshToken || (session.refreshExpiresAt ?? 0) <= Date.now()) return null;
  try {
    const next = await refreshGhostIdTokens(session.refreshToken);
    return {
      ...session,
      token: next.token,
      expiresAt: next.expiresAt,
      refreshToken: next.refreshToken ?? session.refreshToken,
      refreshExpiresAt: next.refreshExpiresAt ?? session.refreshExpiresAt,
    };
  } catch {
    // Refresh одноразовый: после обрыва сети старый уже мог сгореть — просим вход.
    return null;
  }
}

export function clearSession(): void {
  localStorage.removeItem(SESSION_KEY);
}
