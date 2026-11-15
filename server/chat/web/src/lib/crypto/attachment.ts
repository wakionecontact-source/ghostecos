import { aesGcmDecrypt, aesGcmEncrypt } from './aes';
import { fromBase64, randomBytes, toBase64 } from './bytes';

export interface EncryptedAttachment {
  blob: string;
  key: string;
  iv: string;
}

/** Вложение шифруется своим ключом; ключ и iv едут только внутри E2E-конверта. */
export async function encryptAttachment(
  plaintext: Uint8Array,
  options?: { key?: Uint8Array; iv?: Uint8Array },
): Promise<EncryptedAttachment> {
  const key = options?.key ?? randomBytes(32);
  const { iv, box } = await aesGcmEncrypt(key, plaintext, options?.iv);
  return { blob: toBase64(box), key: toBase64(key), iv: toBase64(iv) };
}

export async function decryptAttachment(attachment: EncryptedAttachment): Promise<Uint8Array> {
  const key = fromBase64(attachment.key);
  const iv = fromBase64(attachment.iv);
  const box = fromBase64(attachment.blob);
  if (key.length !== 32 || iv.length !== 12 || box.length < 16) {
    throw new Error('Повреждён ключ или контейнер вложения');
  }
  return aesGcmDecrypt(key, iv, box);
}

/** Байты вложения для загрузки: ciphertext || tag, без iv. */
export function attachmentBlobBytes(attachment: EncryptedAttachment): Uint8Array {
  return fromBase64(attachment.blob);
}
