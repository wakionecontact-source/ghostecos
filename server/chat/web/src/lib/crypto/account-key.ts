import { p256 } from '@noble/curves/p256';
import { pbkdf2 } from '@noble/hashes/pbkdf2';
import { sha256 } from '@noble/hashes/sha2';
import { argon2id } from 'hash-wasm';

import { fromBase64, randomBytes, toBase64, utf8 } from './bytes';

/** Форматы серверной копии ключа — контракт с приложением (crypto_service.dart). */
export const ACCOUNT_KDF_ARGON2ID = 'argon2id-v1-m65536-t3-p1';
export const ACCOUNT_KDF_PBKDF2 = 'pbkdf2-sha256-v1-i260000';
export const ACCOUNT_FORMAT_P256 = 'p256-pkcs8-aesgcm-v2';

const SALT_BYTES = 16;
const IV_BYTES = 12;
const PRIVATE_BYTES = 32;
const ARGON_MEMORY = 65536;
const ARGON_ITERATIONS = 3;
const ARGON_PARALLELISM = 1;
const PBKDF2_ITERATIONS = 260000;

export interface ServerKeyRecord {
  x25519_pub: string | null;
  encrypted_private_key: string | null;
  key_salt: string | null;
  key_kdf?: string | null;
  key_format?: string | null;
}

export interface AccountKey {
  /** Скаляр d (32 байта) — приватная часть P-256. */
  privateKey: Uint8Array;
  /** Некомпрессированный публичный ключ 0x04||X||Y (65 байт). */
  publicKey: Uint8Array;
  /** Исходный PKCS8 — нужен, чтобы восстановить ключ без пароля. */
  pkcs8: Uint8Array;
  cryptoKey: CryptoKey;
}

/** AAD привязан к аккаунту: чужой контейнер не расшифруется. */
export function accountKeyAad(account: string): Uint8Array {
  return utf8(`ghostchat/e2e-key/${account.trim().toLowerCase()}/v2`);
}

export interface AccountKeyUpload {
  x25519_pub: string;
  encrypted_private_key: string;
  key_salt: string;
  key_kdf: string;
  key_format: string;
}

/** Новая пара P-256 — создаётся локально, до обращения к сети. */
export async function generateAccountKey(): Promise<AccountKey> {
  const pair = await crypto.subtle.generateKey({ name: 'ECDH', namedCurve: 'P-256' }, true, [
    'deriveBits',
  ]);
  const pkcs8 = new Uint8Array(await crypto.subtle.exportKey('pkcs8', pair.privateKey));
  const publicKey = new Uint8Array(await crypto.subtle.exportKey('raw', pair.publicKey));
  if (publicKey.length !== 65) throw new Error('WebCrypto вернул неожимаемый ключ P-256');

  const privateKey = scalarFromPkcs8(pkcs8);
  const derived = p256.getPublicKey(privateKey, false);
  if (derived.length !== publicKey.length || derived.some((b, i) => b !== publicKey[i])) {
    throw new Error('Экспортированный ключ P-256 повреждён');
  }
  return { privateKey, publicKey, pkcs8, cryptoKey: await importPkcs8(pkcs8) };
}

/** Серверная копия готового ключа: приватник под паролем аккаунта. */
export async function sealAccountKey(
  key: AccountKey,
  password: string,
  account: string,
): Promise<AccountKeyUpload> {
  if (!password) throw new Error('Пароль не должен быть пустым');
  const salt = randomBytes(SALT_BYTES);
  const iv = randomBytes(IV_BYTES);
  const master = await deriveArgon2id(password, salt);
  const aesKey = await crypto.subtle.importKey('raw', bufferOf(master), 'AES-GCM', false, [
    'encrypt',
  ]);
  const sealed = new Uint8Array(
    await crypto.subtle.encrypt(
      {
        name: 'AES-GCM',
        iv: bufferOf(iv),
        additionalData: bufferOf(accountKeyAad(account)),
      },
      aesKey,
      bufferOf(key.pkcs8),
    ),
  );
  const container = new Uint8Array(IV_BYTES + sealed.length);
  container.set(iv, 0);
  container.set(sealed, IV_BYTES);

  return {
    x25519_pub: toBase64(key.publicKey),
    encrypted_private_key: toBase64(container),
    key_salt: toBase64(salt),
    key_kdf: ACCOUNT_KDF_ARGON2ID,
    key_format: ACCOUNT_FORMAT_P256,
  };
}

async function deriveArgon2id(password: string, salt: Uint8Array): Promise<Uint8Array> {
  return (await argon2id({
    password,
    salt,
    parallelism: ARGON_PARALLELISM,
    iterations: ARGON_ITERATIONS,
    memorySize: ARGON_MEMORY,
    hashLength: 32,
    outputType: 'binary',
  })) as Uint8Array;
}

function derivePbkdf2(password: string, salt: Uint8Array): Uint8Array {
  return pbkdf2(sha256, utf8(password), salt, { c: PBKDF2_ITERATIONS, dkLen: 32 });
}

function bufferOf(bytes: Uint8Array): ArrayBuffer {
  return bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength) as ArrayBuffer;
}

async function openWith(
  rawKey: Uint8Array,
  blob: Uint8Array,
  aad?: Uint8Array,
): Promise<Uint8Array | null> {
  try {
    const key = await crypto.subtle.importKey('raw', bufferOf(rawKey), 'AES-GCM', false, [
      'decrypt',
    ]);
    const plain = await crypto.subtle.decrypt(
      {
        name: 'AES-GCM',
        iv: bufferOf(blob.subarray(0, IV_BYTES)),
        ...(aad ? { additionalData: bufferOf(aad) } : {}),
      },
      key,
      bufferOf(blob.subarray(IV_BYTES)),
    );
    return new Uint8Array(plain);
  } catch {
    return null;
  }
}

/** Достаёт скаляр из PKCS8: последнее OCTET STRING длиной 32 байта. */
export function scalarFromPkcs8(pkcs8: Uint8Array): Uint8Array {
  for (let i = pkcs8.length - PRIVATE_BYTES - 2; i >= 0; i -= 1) {
    if (pkcs8[i] === 0x04 && pkcs8[i + 1] === PRIVATE_BYTES) {
      return pkcs8.slice(i + 2, i + 2 + PRIVATE_BYTES);
    }
  }
  throw new Error('Не удалось разобрать PKCS8 ключа');
}

/** Расшифровывает серверную копию ключа паролем аккаунта. */
export async function decryptAccountKey(
  record: ServerKeyRecord,
  password: string,
  account: string,
): Promise<AccountKey> {
  if (!record.encrypted_private_key || !record.key_salt) {
    throw new Error('На сервере нет ключа аккаунта — создай его в приложении');
  }
  const blob = fromBase64(record.encrypted_private_key);
  const salt = fromBase64(record.key_salt);
  if (salt.length !== SALT_BYTES) throw new Error('Неверная соль ключа аккаунта');
  if (blob.length <= IV_BYTES + 16) throw new Error('Контейнер ключа повреждён');

  const kdf = record.key_kdf ?? null;
  const format = record.key_format ?? null;
  const argonFirst = kdf === ACCOUNT_KDF_ARGON2ID || (kdf === null && format === null);
  const aad = accountKeyAad(account);

  let pkcs8: Uint8Array | null = null;
  if (argonFirst) {
    pkcs8 = await openWith(await deriveArgon2id(password, salt), blob, aad);
  }
  if (!pkcs8 && kdf !== ACCOUNT_KDF_ARGON2ID) {
    pkcs8 = await openWith(derivePbkdf2(password, salt), blob);
  }
  if (!pkcs8) throw new Error('Пароль не подошёл к ключу аккаунта');

  const privateKey = scalarFromPkcs8(pkcs8);
  const publicKey = p256.getPublicKey(privateKey, false);
  if (record.x25519_pub && record.x25519_pub !== btoa(String.fromCharCode(...publicKey))) {
    throw new Error('Ключ не совпадает с опубликованным на сервере');
  }

  const cryptoKey = await importPkcs8(pkcs8);
  return { privateKey, publicKey, pkcs8, cryptoKey };
}

async function importPkcs8(pkcs8: Uint8Array): Promise<CryptoKey> {
  return crypto.subtle.importKey('pkcs8', bufferOf(pkcs8), { name: 'ECDH', namedCurve: 'P-256' }, false, [
    'deriveBits',
  ]);
}

/** Поднимает ключ из локального хранилища устройства, без пароля. */
export async function accountKeyFromPkcs8(
  pkcs8: Uint8Array,
  publicKey: Uint8Array,
): Promise<AccountKey> {
  const privateKey = scalarFromPkcs8(pkcs8);
  const derived = p256.getPublicKey(privateKey, false);
  if (derived.length !== publicKey.length || derived.some((b, i) => b !== publicKey[i])) {
    throw new Error('Локальный ключ повреждён');
  }
  return { privateKey, publicKey, pkcs8, cryptoKey: await importPkcs8(pkcs8) };
}
