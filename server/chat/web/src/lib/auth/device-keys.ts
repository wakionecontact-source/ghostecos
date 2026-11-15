import { ed25519 } from '@noble/curves/ed25519';
import { idbGet, idbPut, STORE_KEYS } from '../storage/db';

const BROWSER_KEY = 'browser-identity-v1';

export interface BrowserKey {
  seed: Uint8Array;
  publicKey: Uint8Array;
}

export function browserKeyFromSeed(seed: Uint8Array): BrowserKey {
  return { seed, publicKey: ed25519.getPublicKey(seed) };
}

/** Ключ веб-устройства: только доказательство владения, E2E-ключи отдельные. */
export async function loadOrCreateBrowserKey(): Promise<BrowserKey> {
  const stored = await idbGet<ArrayBuffer>(STORE_KEYS, BROWSER_KEY);
  const seed = stored ? new Uint8Array(stored) : crypto.getRandomValues(new Uint8Array(32));
  if (!stored) await idbPut(STORE_KEYS, BROWSER_KEY, seed);
  return browserKeyFromSeed(seed);
}

export async function signBrowserProof(key: BrowserKey, message: Uint8Array): Promise<Uint8Array> {
  return ed25519.sign(message, key.seed);
}

export async function sha256Hex(value: string): Promise<string> {
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(value));
  return Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, '0')).join('');
}
