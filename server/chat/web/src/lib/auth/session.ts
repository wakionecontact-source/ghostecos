import { requestJson, ApiError } from '../api/http';
import { toBase64, utf8 } from '../crypto/bytes';
import { loadOrCreateBrowserKey, sha256Hex, signBrowserProof } from './device-keys';

const DEVICE_NAME = 'GhostChat Web';
const PROOF_DOMAIN = 'ghostchat-web-device:v2';
const SESSION_KEY = 'gc.web.session';

export interface WebSession {
  token: string;
  deviceId: number;
  userId: string;
  username: string;
  expiresAt: number;
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

/** Enrollment привязывает браузер к нативному устройству через TDA-одобрение. */
export async function enroll(token: string, username: string): Promise<EnrollmentResult> {
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
    return {
      token,
      deviceId: response.device_id,
      userId: response.user_id,
      username,
      expiresAt: response.expires_at * 1000,
    };
  }
  if (response.status === 'approval_required' && response.approval_id) {
    return {
      status: 'approval_required',
      approvalId: response.approval_id,
      code: response.code,
      expiresIn: response.expires_in ?? 0,
    };
  }
  throw new ApiError(502, 'Сервер вернул неизвестное состояние входа');
}

/** Опрос одобрения: pending → approved (готово) либо expired. */
export async function pollApproval(
  token: string,
  approvalId: string,
  username: string,
): Promise<ApprovalPoll> {
  const response = await requestJson<SessionResponse>(
    `/api/chat/v2/client/session/approval/${encodeURIComponent(approvalId)}`,
    { token },
  );

  if (response.status === 'ready' && response.device_id && response.user_id && response.expires_at) {
    return {
      token,
      deviceId: response.device_id,
      userId: response.user_id,
      username,
      expiresAt: response.expires_at * 1000,
    };
  }
  if (response.status === 'expired') return 'expired';
  return 'pending';
}

export function saveSession(session: WebSession): void {
  localStorage.setItem(SESSION_KEY, JSON.stringify(session));
}

export function loadSession(): WebSession | null {
  const raw = localStorage.getItem(SESSION_KEY);
  if (!raw) return null;
  try {
    const parsed = JSON.parse(raw) as WebSession;
    if (!parsed.token || !parsed.deviceId || parsed.expiresAt <= Date.now()) return null;
    return parsed;
  } catch {
    return null;
  }
}

export function clearSession(): void {
  localStorage.removeItem(SESSION_KEY);
}
