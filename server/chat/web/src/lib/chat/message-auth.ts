import { utf8 } from '../crypto/bytes';

/** Домены подписи совпадают с Flutter: byte-в-byte, включая NUL-разделители. */
function nulSeparated(domain: string, fields: string[]): Uint8Array {
  return utf8(`${domain}\u0000${fields.join('\u0000')}`);
}

export function v2EnvelopeBytes(input: {
  senderIdentityPub: string;
  toUsername: string;
  targetDeviceId: number;
  envelope: string;
}): Uint8Array {
  return nulSeparated('ghostchat-v2-envelope-v1', [
    input.senderIdentityPub,
    input.toUsername.trim().toLowerCase(),
    String(input.targetDeviceId),
    input.envelope,
  ]);
}
