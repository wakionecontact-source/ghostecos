import type { ChatClient } from '../api/chat';
import { ApiError } from '../api/http';
import { saveDeviceVault } from '../auth/vault';
import { generateAccountKey, sealAccountKey, type AccountKey } from '../crypto/account-key';
import { toBase64 } from '../crypto/bytes';
import {
  createDeviceKeyPair,
  identityClaimSignature,
  identityFromSeed,
  randomSeed,
  signDevicePrekey,
} from '../crypto/identity';
import { exportEncryptedIdentity } from '../crypto/identity-backup';
import { ReplaceRequiredError, type V2Keys } from './keys';

export type KeyStorageMode = 'server' | 'local';

export interface GeneratedKeys {
  account: AccountKey;
  v2: V2Keys;
}

/** Оба ключа создаются на устройстве, до обращения к сети — как в приложении. */
export async function generateKeys(): Promise<GeneratedKeys> {
  const account = await generateAccountKey();
  const identity = identityFromSeed(randomSeed());
  const device = createDeviceKeyPair();
  return { account, v2: { identity, device } };
}

/** Публикация ключа аккаунта по выбранному режиму. */
export async function publishAccountKey(
  api: ChatClient,
  username: string,
  account: AccountKey,
  mode: KeyStorageMode,
  password = '',
  replace = false,
): Promise<void> {
  try {
    if (mode === 'server') {
      if (!password) throw new Error('Пароль не должен быть пустым');
      const sealed = await sealAccountKey(account, password, username);
      await api.uploadKeys({ ...sealed, storage_mode: 'server', replace });
      return;
    }
    // Только публичная часть: приватник остаётся в сейфе устройства.
    await api.uploadKeys({
      x25519_pub: toBase64(account.publicKey),
      storage_mode: 'local',
      replace,
    });
  } catch (cause) {
    if (cause instanceof ApiError && cause.status === 409 && !replace) {
      throw new ReplaceRequiredError('v1');
    }
    throw cause;
  }
}

/** Публикует ключи по выбранному режиму: серверная копия либо только устройство. */
export async function publishKeys(
  api: ChatClient,
  username: string,
  keys: GeneratedKeys,
  mode: KeyStorageMode,
  password = '',
  replace = false,
): Promise<void> {
  await publishAccountKey(api, username, keys.account, mode, password, replace);

  const backup =
    mode === 'server' ? await exportEncryptedIdentity(keys.v2.identity, password) : {};
  await api.publishIdentity({
    identity_pub: toBase64(keys.v2.identity.publicKey),
    proof_signature: toBase64(identityClaimSignature(keys.v2.identity)),
    ...backup,
  });

  await api.publishDevice({
    device_pub: toBase64(keys.v2.device.publicKey),
    signed_prekey_sig: toBase64(signDevicePrekey(keys.v2.identity, keys.v2.device.publicKey)),
    replace,
  });

  await saveDeviceVault({
    identitySeed: keys.v2.identity.seed,
    identityPublic: keys.v2.identity.publicKey,
    devicePrivate: keys.v2.device.privateKey,
    accountPkcs8: keys.account.pkcs8,
    accountPublic: keys.account.publicKey,
  });
}
