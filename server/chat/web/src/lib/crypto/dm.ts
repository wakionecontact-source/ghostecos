import { hkdf } from '@noble/hashes/hkdf';
import { sha256 } from '@noble/hashes/sha2';

import { concat, fromBase64, randomBytes, toBase64, utf8 } from './bytes';

/** Информация HKDF и соль — те же, что в crypto_service.dart приложения. */
const HKDF_INFO = utf8('ghostchat-msg-v1');
const HKDF_SALT = new Uint8Array(32);
const IV_BYTES = 12;

function bufferOf(bytes: Uint8Array): ArrayBuffer {
  return bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength) as ArrayBuffer;
}

/** Общий AES-ключ: ECDH(P-256) → X → HKDF-SHA256. */
async function aesKeyFor(priv: CryptoKey, peerPubRaw: Uint8Array): Promise<CryptoKey> {
  const peer = await crypto.subtle.importKey(
    'raw',
    bufferOf(peerPubRaw),
    { name: 'ECDH', namedCurve: 'P-256' },
    false,
    [],
  );
  const bits = await crypto.subtle.deriveBits({ name: 'ECDH', public: peer }, priv, 256);
  const key = hkdf(sha256, new Uint8Array(bits), HKDF_SALT, HKDF_INFO, 32);
  return crypto.subtle.importKey('raw', bufferOf(key), 'AES-GCM', false, ['encrypt', 'decrypt']);
}

/** Конверт как в приложении: base64(iv(12) || ciphertext || tag). */
export async function encryptDm(
  priv: CryptoKey,
  peerPubRaw: Uint8Array,
  plaintext: string,
): Promise<string> {
  const key = await aesKeyFor(priv, peerPubRaw);
  const iv = randomBytes(IV_BYTES);
  const sealed = await crypto.subtle.encrypt(
    { name: 'AES-GCM', iv: bufferOf(iv) },
    key,
    bufferOf(utf8(plaintext)),
  );
  return toBase64(concat(iv, new Uint8Array(sealed)));
}

export async function decryptDm(
  priv: CryptoKey,
  peerPubRaw: Uint8Array,
  envelopeB64: string,
): Promise<string> {
  const raw = fromBase64(envelopeB64);
  if (raw.length < IV_BYTES + 16) throw new Error('Конверт слишком короткий');
  const key = await aesKeyFor(priv, peerPubRaw);
  const plain = await crypto.subtle.decrypt(
    { name: 'AES-GCM', iv: bufferOf(raw.subarray(0, IV_BYTES)) },
    key,
    bufferOf(raw.subarray(IV_BYTES)),
  );
  return new TextDecoder().decode(plain);
}
