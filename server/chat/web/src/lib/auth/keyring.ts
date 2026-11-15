import type { ChatClient } from '../api/chat';
import { fromBase64, toBase64 } from '../crypto/bytes';
import { generateMnemonic, validateMnemonic } from '../crypto/bip39';
import {
  createDeviceKeyPair,
  deviceKeyPairFromPrivate,
  identityClaimSignature,
  identityFromMnemonic,
  identityFromSeed,
  signDevicePrekey,
  verifySignedPrekey,
  type DeviceKeyPair,
  type IdentityKeyPair,
} from '../crypto/identity';
import { exportEncryptedIdentity, importEncryptedIdentity } from '../crypto/identity-backup';
import { saveDeviceVault, saveVault, unlockDeviceVault, unlockVault, vaultSecretsFrom } from './vault';

export interface UnlockedKeys {
  identity: IdentityKeyPair;
  device: DeviceKeyPair;
}

async function publishDevice(api: ChatClient, identity: IdentityKeyPair, device: DeviceKeyPair): Promise<void> {
  await api.publishDevice({
    device_pub: toBase64(device.publicKey),
    signed_prekey_sig: toBase64(signDevicePrekey(identity, device.publicKey)),
  });
}

async function finish(
  api: ChatClient,
  identity: IdentityKeyPair,
  password: string,
  devicePrivate?: Uint8Array,
): Promise<UnlockedKeys> {
  const device = deviceKeyPairFromPrivate(devicePrivate ?? createDeviceKeyPair().privateKey);
  await publishDevice(api, identity, device);
  const secrets = vaultSecretsFrom({
    identitySeed: identity.seed,
    identityPublic: identity.publicKey,
    devicePrivate: device.privateKey,
  });
  await saveVault(password, secrets);
  // Второй контейнер — для входа без пароля, как SecureStore в приложении.
  await saveDeviceVault(secrets);
  return { identity, device };
}

async function existingDevicePrivate(password: string): Promise<Uint8Array | undefined> {
  try {
    return (await unlockVault(password)).devicePrivate;
  } catch {
    return undefined;
  }
}

/** Вход без пароля из хранилища устройства; null — если ключей там нет. */
export async function unlockFromDevice(api: ChatClient): Promise<UnlockedKeys | null> {
  const secrets = await unlockDeviceVault();
  if (!secrets?.identitySeed || !secrets.identityPublic || !secrets.devicePrivate) return null;

  const identity = identityFromSeed(secrets.identitySeed);
  // Защита от рассинхрона: seed обязан давать тот же публичный ключ.
  if (toBase64(identity.publicKey) !== toBase64(secrets.identityPublic)) return null;

  const device = deviceKeyPairFromPrivate(secrets.devicePrivate);
  await publishDevice(api, identity, device);
  return { identity, device };
}

/** Восстановление identity из серверной копии, зашифрованной паролем. */
export async function unlockWithPassword(api: ChatClient, password: string): Promise<UnlockedKeys> {
  const me = await api.myIdentity();
  if (!me.identity_pub || !me.identity_priv_encrypted || !me.identity_salt) {
    throw new Error('На сервере нет резервной копии ключей — введи мнемонику или создай ключи');
  }
  const identity = await importEncryptedIdentity({
    encryptedB64: me.identity_priv_encrypted,
    saltB64: me.identity_salt,
    password,
    expectedIdentityPubB64: me.identity_pub,
  });
  return finish(api, identity, password, await existingDevicePrivate(password));
}

/** Восстановление по seed-фразе: ключ обязан совпасть с опубликованным. */
export async function restoreWithMnemonic(
  api: ChatClient,
  mnemonic: string,
  password: string,
): Promise<UnlockedKeys> {
  if (!validateMnemonic(mnemonic)) throw new Error('Проверь seed-фразу: контрольная сумма не сходится');
  const identity = identityFromMnemonic(mnemonic);
  const me = await api.myIdentity();

  if (me.identity_pub) {
    if (me.identity_pub !== toBase64(identity.publicKey)) {
      throw new Error('Эта мнемоника не подходит к ключу аккаунта');
    }
  } else {
    const backup = await exportEncryptedIdentity(identity, password);
    await api.publishIdentity({
      identity_pub: toBase64(identity.publicKey),
      proof_signature: toBase64(identityClaimSignature(identity)),
      ...backup,
    });
  }
  return finish(api, identity, password, await existingDevicePrivate(password));
}

export interface CreatedIdentity {
  mnemonic: string;
  keys: UnlockedKeys;
}

/** Новая identity: мнемоника показывается один раз и служит бэкапом. */
export async function createIdentity(api: ChatClient, password: string): Promise<CreatedIdentity> {
  const me = await api.myIdentity();
  if (me.identity_pub) throw new Error('У аккаунта уже есть ключи — восстанови их паролем или мнемоникой');

  const mnemonic = generateMnemonic();
  const identity = identityFromMnemonic(mnemonic);
  const backup = await exportEncryptedIdentity(identity, password);
  await api.publishIdentity({
    identity_pub: toBase64(identity.publicKey),
    proof_signature: toBase64(identityClaimSignature(identity)),
    ...backup,
  });
  return { mnemonic, keys: await finish(api, identity, password) };
}

/** Проверка доверия к устройству собеседника: подпись identity над device_pub. */
export function isTrustedPeerDevice(peerIdentityPubB64: string, devicePubB64: string, signatureB64: string): boolean {
  try {
    return verifySignedPrekey(
      fromBase64(peerIdentityPubB64),
      fromBase64(devicePubB64),
      fromBase64(signatureB64),
    );
  } catch {
    return false;
  }
}
