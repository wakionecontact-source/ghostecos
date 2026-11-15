import type { ChatClient } from '../api/chat';
import { ApiError } from '../api/http';
import { saveDeviceVault, unlockDeviceVault } from '../auth/vault';
import { validateMnemonic } from '../crypto/bip39';
import { fromBase64, toBase64 } from '../crypto/bytes';
import {
  createDeviceKeyPair,
  deviceKeyPairFromPrivate,
  identityFromMnemonic,
  identityFromSeed,
  signDevicePrekey,
  verifySignedPrekey,
  type DeviceKeyPair,
  type IdentityKeyPair,
} from '../crypto/identity';
import { importEncryptedIdentity } from '../crypto/identity-backup';

/** Пара «identity аккаунта + ключ этого устройства» — как CryptoV2 в приложении. */
export interface V2Keys {
  identity: IdentityKeyPair;
  device: DeviceKeyPair;
}

export function identityPubB64(keys: V2Keys): string {
  return toBase64(keys.identity.publicKey);
}

/** Ключи v2 из хранилища устройства; проверяем, что seed даёт тот же публичный ключ. */
export async function v2FromDevice(): Promise<V2Keys | null> {
  const secrets = await unlockDeviceVault();
  if (!secrets?.identitySeed || !secrets.identityPublic || !secrets.devicePrivate) return null;
  const identity = identityFromSeed(secrets.identitySeed);
  if (toBase64(identity.publicKey) !== toBase64(secrets.identityPublic)) return null;
  return { identity, device: deviceKeyPairFromPrivate(secrets.devicePrivate) };
}

/** Сервер отказался заменить уже опубликованный ключ без явного согласия. */
export class ReplaceRequiredError extends Error {
  readonly scope: 'device' | 'v1';

  constructor(scope: 'device' | 'v1') {
    super(
      scope === 'device'
        ? 'У этого устройства уже опубликован другой ключ шифрования'
        : 'У аккаунта уже опубликован другой ключ v1',
    );
    this.name = 'ReplaceRequiredError';
    this.scope = scope;
  }
}

/** Публикуем ключ устройства, только если сервер ещё не знает этот device_pub. */
async function ensureDevicePublished(
  api: ChatClient,
  username: string,
  keys: V2Keys,
  replace = false,
): Promise<void> {
  const pubB64 = toBase64(keys.device.publicKey);
  try {
    const own = await api.peerKeys(username);
    if (own.devices.some((device) => device.device_pub === pubB64)) return;
  } catch {
    // Проверка — оптимизация; при сбое пробуем публикацию.
  }
  try {
    await api.publishDevice({
      device_pub: pubB64,
      signed_prekey_sig: toBase64(signDevicePrekey(keys.identity, keys.device.publicKey)),
      replace,
    });
  } catch (cause) {
    if (cause instanceof ApiError && cause.status === 409 && !replace) {
      throw new ReplaceRequiredError('device');
    }
    throw cause;
  }
}

interface V2UnlockOptions {
  /** Пароль нужен только для первой разблокировки: серверная копия identity. */
  password?: string;
  /** Нужен для проверки уже опубликованного device_pub. */
  username: string;
  /** Подтверждённая замена уже опубликованного ключа этого устройства. */
  replace?: boolean;
}

/** Поднимает v2-ключи: из хранилища устройства либо из серверного бэкапа по паролю. */
export async function unlockV2(api: ChatClient, options: V2UnlockOptions): Promise<V2Keys | null> {
  const me = await api.myIdentity();
  if (!me.identity_pub) return null;

  const stored = await v2FromDevice();
  if (stored && toBase64(stored.identity.publicKey) === me.identity_pub) {
    await ensureDevicePublished(api, options.username, stored, options.replace ?? false);
    return stored;
  }

  if (!options.password || !me.identity_priv_encrypted || !me.identity_salt) return null;

  const identity = await importEncryptedIdentity({
    encryptedB64: me.identity_priv_encrypted,
    saltB64: me.identity_salt,
    password: options.password,
    expectedIdentityPubB64: me.identity_pub,
  });
  const device = createDeviceKeyPair();
  const keys: V2Keys = { identity, device };
  await ensureDevicePublished(api, options.username, keys);
  await saveDeviceVault({
    identitySeed: identity.seed,
    identityPublic: identity.publicKey,
    devicePrivate: device.privateKey,
  });
  return keys;
}

/** Привязка нового устройства по seed-фразе — как в настройках приложения. */
export async function bindDeviceWithMnemonic(
  api: ChatClient,
  username: string,
  mnemonic: string,
  expectedIdentityPubB64: string,
  replace = false,
): Promise<V2Keys> {
  if (!validateMnemonic(mnemonic)) throw new Error('Неверная seed-фраза: нужно 12 слов');
  const identity = identityFromMnemonic(mnemonic);
  if (toBase64(identity.publicKey) !== expectedIdentityPubB64) {
    throw new Error('Эта seed-фраза не подходит к ключу аккаунта');
  }
  const device = createDeviceKeyPair();
  const keys: V2Keys = { identity, device };
  await ensureDevicePublished(api, username, keys, replace);
  await saveDeviceVault({
    identitySeed: identity.seed,
    identityPublic: identity.publicKey,
    devicePrivate: device.privateKey,
  });
  return keys;
}

/** Проверка доверия к устройству собеседника: подпись identity над device_pub. */
export function trustedPeerDevice(
  identityPub: string,
  devicePub: string,
  signature: string,
): boolean {
  try {
    return verifySignedPrekey(fromBase64(identityPub), fromBase64(devicePub), fromBase64(signature));
  } catch {
    return false;
  }
}
