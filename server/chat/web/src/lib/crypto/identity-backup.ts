import { pbkdf2 } from '@noble/hashes/pbkdf2';
import { sha256 } from '@noble/hashes/sha2';
import { aesGcmEncrypt, openContainer } from './aes';
import { concat, equalBytes, fromBase64, randomBytes, toBase64, utf8 } from './bytes';
import { identityFromSeed, type IdentityKeyPair } from './identity';

/** Идентификатор KDF в контейнере — часть контракта с Dart-клиентом. */
export const IDENTITY_KDF = 'pbkdf2-sha256-v1-i260000';
const PBKDF2_ITERATIONS = 260000;
const SALT_BYTES = 16;
const SECRET_BYTES = 64;

async function deriveBackupKey(password: string, salt: Uint8Array): Promise<Uint8Array> {
  if (!password) throw new Error('Пароль не должен быть пустым');
  return pbkdf2(sha256, utf8(password), salt, { c: PBKDF2_ITERATIONS, dkLen: 32 });
}

export interface EncryptedIdentityBackup {
  identity_priv_encrypted: string;
  identity_salt: string;
  identity_kdf: string;
}

/** Серверная копия identity: seed||pub под паролем, без открытого ключа в контейнере. */
export async function exportEncryptedIdentity(
  identity: IdentityKeyPair,
  password: string,
  options?: { salt?: Uint8Array; iv?: Uint8Array },
): Promise<EncryptedIdentityBackup> {
  const salt = options?.salt ?? randomBytes(SALT_BYTES);
  const key = await deriveBackupKey(password, salt);
  const secret = new Uint8Array(SECRET_BYTES);
  secret.set(identity.seed, 0);
  secret.set(identity.publicKey, 32);
  const { iv, box } = await aesGcmEncrypt(key, secret, options?.iv);
  const container = concat(iv, box);
  return {
    identity_priv_encrypted: toBase64(container),
    identity_salt: toBase64(salt),
    identity_kdf: IDENTITY_KDF,
  };
}

export interface ImportIdentityBackupInput {
  encryptedB64: string;
  saltB64: string;
  password: string;
  expectedIdentityPubB64: string;
}

/** Восстановление identity на новом устройстве; device-ключ остаётся своим. */
export async function importEncryptedIdentity(input: ImportIdentityBackupInput): Promise<IdentityKeyPair> {
  const salt = fromBase64(input.saltB64);
  const container = fromBase64(input.encryptedB64);
  if (salt.length !== SALT_BYTES) throw new Error('Неверная соль identity-бэкапа');

  const key = await deriveBackupKey(input.password, salt);
  const secret = await openContainer(key, container);
  if (secret.length !== SECRET_BYTES) throw new Error('Неверная длина identity-бэкапа');

  const seed = secret.subarray(0, 32);
  const expectedPublic = secret.subarray(32, 64);
  const identity = identityFromSeed(seed);
  if (!equalBytes(expectedPublic, identity.publicKey)) {
    throw new Error('Публичный ключ не соответствует seed');
  }

  const serverPublic = fromBase64(input.expectedIdentityPubB64);
  if (!equalBytes(serverPublic, identity.publicKey)) {
    throw new Error('Identity-бэкап не совпадает с ключом на сервере');
  }
  return identity;
}
