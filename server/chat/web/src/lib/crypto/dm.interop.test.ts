import { hkdf } from '@noble/hashes/hkdf';
import { sha256 } from '@noble/hashes/sha2';
import { p256 } from '@noble/curves/p256';
import { describe, expect, it } from 'vitest';

import { generateAccountKey } from './account-key';
import { encryptDm } from './dm';
import { fromBase64, utf8 } from './bytes';

/** Независимая расшифровка по схеме crypto_service.dart: ECDH→HKDF→AES-GCM. */
function bufferOf(bytes: Uint8Array): ArrayBuffer {
  return bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength) as ArrayBuffer;
}
async function decryptAsDart(
  peerScalar: Uint8Array,
  senderPub: Uint8Array,
  envelopeB64: string,
): Promise<string> {
  const secret = p256.getSharedSecret(peerScalar, senderPub, false);
  const x = secret.subarray(1, 33);
  const key = hkdf(sha256, x, new Uint8Array(32), utf8('ghostchat-msg-v1'), 32);
  const raw = fromBase64(envelopeB64);
  const iv = bufferOf(raw.subarray(0, 12));
  const body = bufferOf(raw.subarray(12));
  const cryptoKey = await crypto.subtle.importKey('raw', bufferOf(key), 'AES-GCM', false, ['decrypt']);
  const plain = await crypto.subtle.decrypt(
    { name: 'AES-GCM', iv },
    cryptoKey,
    body,
  );
  return new TextDecoder().decode(plain);
}

describe('легаси-конверт как в приложении', () => {
  it('пир расшифровывает payload', async () => {
    const sender = await generateAccountKey();
    const peer = await generateAccountKey();
    const payload = JSON.stringify({ type: 'msg', text: 'привет' });

    const envelope = await encryptDm(sender.cryptoKey, peer.publicKey, payload);
    const decoded = await decryptAsDart(peer.privateKey, sender.publicKey, envelope);

    expect(decoded).toBe(payload);
  });
});
