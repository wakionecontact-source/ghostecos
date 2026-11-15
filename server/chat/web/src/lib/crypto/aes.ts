import { concat } from './bytes';

const TAG_BYTES = 16;
const IV_BYTES = 12;

// TS 5.9 различает ArrayBufferLike и ArrayBuffer, рантайму WebCrypto это безразлично.
function asBytes(value: Uint8Array): BufferSource {
  return value as unknown as BufferSource;
}

async function importKey(raw: Uint8Array): Promise<CryptoKey> {
  return crypto.subtle.importKey('raw', asBytes(raw), { name: 'AES-GCM' }, false, ['encrypt', 'decrypt']);
}

/** AES-256-GCM: возвращает ciphertext||tag, как ожидает Dart-клиент. */
export async function aesGcmEncrypt(
  key: Uint8Array,
  plaintext: Uint8Array,
  iv: Uint8Array = crypto.getRandomValues(new Uint8Array(IV_BYTES)),
): Promise<{ iv: Uint8Array; box: Uint8Array }> {
  if (key.length !== 32 || iv.length !== IV_BYTES) throw new Error('AES-GCM: неверный размер ключа или iv');
  const cryptoKey = await importKey(key);
  const sealed = new Uint8Array(
    await crypto.subtle.encrypt(
      { name: 'AES-GCM', iv: asBytes(iv), tagLength: TAG_BYTES * 8 },
      cryptoKey,
      asBytes(plaintext),
    ),
  );
  return { iv, box: sealed };
}

export async function aesGcmDecrypt(
  key: Uint8Array,
  iv: Uint8Array,
  box: Uint8Array,
): Promise<Uint8Array> {
  if (key.length !== 32 || iv.length !== IV_BYTES || box.length < TAG_BYTES) {
    throw new Error('AES-GCM: повреждён контейнер');
  }
  const cryptoKey = await importKey(key);
  const opened = await crypto.subtle.decrypt(
    { name: 'AES-GCM', iv: asBytes(iv), tagLength: TAG_BYTES * 8 },
    cryptoKey,
    asBytes(box),
  );
  return new Uint8Array(opened);
}

/** Контейнер iv||ciphertext||tag — формат identity-бэкапа и вложений. */
export async function sealContainer(key: Uint8Array, plaintext: Uint8Array): Promise<Uint8Array> {
  const { iv, box } = await aesGcmEncrypt(key, plaintext);
  return concat(iv, box);
}

export async function openContainer(key: Uint8Array, container: Uint8Array): Promise<Uint8Array> {
  if (container.length < IV_BYTES + TAG_BYTES) throw new Error('Контейнер слишком короткий');
  const iv = container.subarray(0, IV_BYTES);
  const box = container.subarray(IV_BYTES);
  return aesGcmDecrypt(key, iv, box);
}

export const AES_IV_BYTES = IV_BYTES;
export const AES_TAG_BYTES = TAG_BYTES;
