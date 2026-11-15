import { pbkdf2 } from '@noble/hashes/pbkdf2';
import { sha256 } from '@noble/hashes/sha2';
import { openContainer, sealContainer } from '../crypto/aes';
import { concat, fromBase64, randomBytes, toBase64, utf8 } from '../crypto/bytes';
import { idbDelete, idbGet, idbPut, STORE_KEYS, STORE_VAULT } from '../storage/db';

const VAULT_KEY = 'main';
const DEVICE_VAULT_KEY = 'device';
const WRAP_KEY = 'vault-wrap';
const KDF_ITERATIONS = 260000;
const SALT_BYTES = 16;
const IV_BYTES = 12;

/** WebCrypto принимает только ArrayBuffer, а не view поверх общего буфера. */
function bufferOf(bytes: Uint8Array): ArrayBuffer {
  return bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength) as ArrayBuffer;
}

export interface VaultSecrets {
  identitySeed?: Uint8Array;
  identityPublic?: Uint8Array;
  devicePrivate?: Uint8Array;
  accountPkcs8?: Uint8Array;
  accountPublic?: Uint8Array;
}

interface StoredVault {
  salt: ArrayBuffer;
  blob: ArrayBuffer;
}

async function deriveKey(password: string, salt: Uint8Array): Promise<Uint8Array> {
  if (!password) throw new Error('Пароль не должен быть пустым');
  return pbkdf2(sha256, utf8(password), salt, { c: KDF_ITERATIONS, dkLen: 32 });
}

function encode(secrets: VaultSecrets): Uint8Array {
  const payload: Record<string, string> = {};
  if (secrets.identitySeed) payload.identity_seed = toBase64(secrets.identitySeed);
  if (secrets.identityPublic) payload.identity_public = toBase64(secrets.identityPublic);
  if (secrets.devicePrivate) payload.device_private = toBase64(secrets.devicePrivate);
  if (secrets.accountPkcs8) payload.account_pkcs8 = toBase64(secrets.accountPkcs8);
  if (secrets.accountPublic) payload.account_public = toBase64(secrets.accountPublic);
  return utf8(JSON.stringify(payload));
}

function decode(raw: Uint8Array): VaultSecrets {
  const parsed = JSON.parse(new TextDecoder().decode(raw)) as Record<string, string>;
  const optional = (value?: string) => (value ? fromBase64(value) : undefined);
  return {
    identitySeed: optional(parsed.identity_seed),
    identityPublic: optional(parsed.identity_public),
    devicePrivate: optional(parsed.device_private),
    accountPkcs8: optional(parsed.account_pkcs8),
    accountPublic: optional(parsed.account_public),
  };
}

export async function hasVault(): Promise<boolean> {
  return (await idbGet<StoredVault>(STORE_VAULT, VAULT_KEY)) !== null;
}

/** Локальный сейф: seed identity и device-ключ под паролем пользователя. */
export async function saveVault(password: string, secrets: VaultSecrets): Promise<void> {
  const salt = randomBytes(SALT_BYTES);
  const key = await deriveKey(password, salt);
  const container = await sealContainer(key, encode(secrets));
  await idbPut(STORE_VAULT, VAULT_KEY, { salt: salt.buffer, blob: container.buffer });
}

export async function unlockVault(password: string): Promise<VaultSecrets> {
  const stored = await idbGet<StoredVault>(STORE_VAULT, VAULT_KEY);
  if (!stored) throw new Error('Локальный сейф не найден');
  const salt = new Uint8Array(stored.salt);
  const key = await deriveKey(password, salt);
  const raw = await openContainer(key, new Uint8Array(stored.blob));
  return decode(raw);
}

export async function clearVault(): Promise<void> {
  await idbDelete(STORE_VAULT, VAULT_KEY);
}

/* ── Хранилище устройства ────────────────────────────────
   Как SecureStore в приложении: ключ не выводится из пароля, а живёт
   неизвлекаемым CryptoKey в IndexedDB и защищён самим браузером. */

async function wrapKey(create: boolean): Promise<CryptoKey | null> {
  const existing = await idbGet<CryptoKey>(STORE_KEYS, WRAP_KEY);
  if (existing) return existing;
  if (!create) return null;
  const key = await crypto.subtle.generateKey({ name: 'AES-GCM', length: 256 }, false, [
    'encrypt',
    'decrypt',
  ]);
  await idbPut(STORE_KEYS, WRAP_KEY, key);
  return key;
}

/** Кладёт ключи в хранилище устройства — дальше вход без пароля. */
export async function saveDeviceVault(secrets: VaultSecrets): Promise<void> {
  const key = await wrapKey(true);
  if (!key) return;
  // Дополняем контейнер: identity и ключ аккаунта могут прийти в разное время.
  const current = await unlockDeviceVault();
  const merged: VaultSecrets = { ...current, ...secrets };
  const iv = randomBytes(IV_BYTES);
  const sealed = await crypto.subtle.encrypt(
    { name: 'AES-GCM', iv: bufferOf(iv) },
    key,
    bufferOf(encode(merged)),
  );
  const blob = new Uint8Array(IV_BYTES + sealed.byteLength);
  blob.set(iv, 0);
  blob.set(new Uint8Array(sealed), IV_BYTES);
  await idbPut(STORE_VAULT, DEVICE_VAULT_KEY, blob.buffer);
}

/** Читает ключи устройства; null — если хранилища нет или оно повреждено. */
export async function unlockDeviceVault(): Promise<VaultSecrets | null> {
  const key = await wrapKey(false);
  const stored = await idbGet<ArrayBuffer>(STORE_VAULT, DEVICE_VAULT_KEY);
  if (!key || !stored) return null;
  const raw = new Uint8Array(stored);
  try {
    const plain = await crypto.subtle.decrypt(
      { name: 'AES-GCM', iv: bufferOf(raw.slice(0, IV_BYTES)) },
      key,
      bufferOf(raw.slice(IV_BYTES)),
    );
    return decode(new Uint8Array(plain));
  } catch {
    return null;
  }
}

export async function hasDeviceVault(): Promise<boolean> {
  return (await idbGet<ArrayBuffer>(STORE_VAULT, DEVICE_VAULT_KEY)) !== null;
}

/** Забыть устройство: выход из аккаунта стирает и ключ, и контейнер. */
export async function clearDeviceVault(): Promise<void> {
  await idbDelete(STORE_VAULT, DEVICE_VAULT_KEY);
  await idbDelete(STORE_KEYS, WRAP_KEY);
}

/** Экспорт для смены пароля: данные те же, контейнер пересобирается. */
export async function reencryptVault(
  oldPassword: string,
  newPassword: string,
): Promise<void> {
  const secrets = await unlockVault(oldPassword);
  await saveVault(newPassword, secrets);
}

export function vaultSecretsFrom(parts: {
  identitySeed: Uint8Array;
  identityPublic: Uint8Array;
  devicePrivate: Uint8Array;
}): VaultSecrets {
  return {
    identitySeed: concat(parts.identitySeed),
    identityPublic: concat(parts.identityPublic),
    devicePrivate: concat(parts.devicePrivate),
  };
}
