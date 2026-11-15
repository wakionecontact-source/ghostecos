import { fromBase64Url, randomBytes, toBase64Url } from '../crypto/bytes';

const VERIFIER_BYTES = 32;

export interface PkcePair {
  verifier: string;
  challenge: string;
}

/** PKCE S256: сервер принимает только challenge из 43 символов base64url. */
export async function createPkce(): Promise<PkcePair> {
  const verifier = toBase64Url(randomBytes(VERIFIER_BYTES));
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(verifier));
  return { verifier, challenge: toBase64Url(new Uint8Array(digest)) };
}

export function createState(): string {
  return toBase64Url(randomBytes(32));
}

/** Проверка вернувшегося state защищает от подмены callback. */
export function safeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

export function decodeTokenPart(value: string): Uint8Array {
  return fromBase64Url(value);
}
