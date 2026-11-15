import { x25519 } from '@noble/curves/ed25519';
import { hkdf } from '@noble/hashes/hkdf';
import { sha256 } from '@noble/hashes/sha2';
import { aesGcmDecrypt, aesGcmEncrypt } from './aes';
import { concat, fromBase64, randomBytes, toBase64 } from './bytes';

const MESSAGE_INFO = new TextEncoder().encode('ghostchat-v2-msg');
const ZERO_SALT = new Uint8Array(32);
const EPH_PUB_BYTES = 32;
const IV_BYTES = 12;
const MIN_ENVELOPE_BYTES = EPH_PUB_BYTES + IV_BYTES + 16;

/** ECDH + HKDF: один и тот же вывод у отправителя с эфемерным ключом и у получателя. */
function deriveMessageKey(sharedSecret: Uint8Array): Uint8Array {
  return hkdf(sha256, sharedSecret, ZERO_SALT, MESSAGE_INFO, 32);
}

/** Конверт v2: eph_pub(32) || iv(12) || ciphertext || tag(16), base64. */
export async function encryptV2(
  recipientDevicePublicKey: Uint8Array,
  plaintext: Uint8Array,
  options?: { ephemeralPrivate?: Uint8Array; iv?: Uint8Array },
): Promise<string> {
  if (recipientDevicePublicKey.length !== 32) throw new Error('Получатель: ожидается X25519 32 байта');
  const ephemeralPrivate = options?.ephemeralPrivate ?? x25519.utils.randomPrivateKey();
  const ephemeralPublic = x25519.getPublicKey(ephemeralPrivate);
  const shared = x25519.getSharedSecret(ephemeralPrivate, recipientDevicePublicKey);
  const key = deriveMessageKey(shared);
  const iv = options?.iv ?? randomBytes(IV_BYTES);
  const { box } = await aesGcmEncrypt(key, plaintext, iv);
  return toBase64(concat(ephemeralPublic, iv, box));
}

/** Расшифровка конверта текущим устройством. */
export async function decryptForMe(
  devicePrivateKey: Uint8Array,
  envelopeB64: string,
): Promise<Uint8Array> {
  const raw = fromBase64(envelopeB64);
  if (raw.length < MIN_ENVELOPE_BYTES) throw new Error('Конверт слишком короткий');
  const ephemeralPublic = raw.subarray(0, EPH_PUB_BYTES);
  const iv = raw.subarray(EPH_PUB_BYTES, EPH_PUB_BYTES + IV_BYTES);
  const box = raw.subarray(EPH_PUB_BYTES + IV_BYTES);
  const shared = x25519.getSharedSecret(devicePrivateKey, ephemeralPublic);
  const key = deriveMessageKey(shared);
  return aesGcmDecrypt(key, iv, box);
}
