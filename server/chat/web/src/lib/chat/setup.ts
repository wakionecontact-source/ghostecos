import type { ChatClient } from '../api/chat';
import { ApiError } from '../api/http';
import { accountFromDevice, unlockAccount } from '../auth/account';
import { saveDeviceVault } from '../auth/vault';
import { generateAccountKey, type AccountKey } from '../crypto/account-key';
import { toBase64 } from '../crypto/bytes';
import { createDeviceKeyPair, identityFromSeed, randomSeed } from '../crypto/identity';
import { activateV2Pair, unlockV2, v2FromDevice, type V2Keys } from './keys';
import { publishAccountKey } from './provision';

export type SetupStep = 'account' | 'identity' | 'device';

/** Что делать на этом устройстве: открыть сейф, спросить пароль или создать ключ. */
export type AccountState = 'vault' | 'password' | 'new';

export interface SetupResult {
  account: AccountKey;
  v2: V2Keys | null;
  /** Почему v2 не поднят — показываем, но вход не блокируем. */
  note: string;
}

/**
 * Порядок один и тот же: сейф браузера → серверная копия (нужен пароль) → новый ключ.
 * Молча ничего не создаём, иначе старые сообщения теряются без спроса.
 */
export async function checkAccount(api: ChatClient): Promise<AccountState> {
  if (await accountFromDevice()) return 'vault';
  const keys = await api.myKeys().catch(() => null);
  return keys?.encrypted_private_key && keys?.key_salt ? 'password' : 'new';
}

/** Ключ аккаунта: только сейф браузера, без сети. */
export async function accountFromVault(): Promise<AccountKey | null> {
  return accountFromDevice();
}

async function createAccountKey(
  api: ChatClient,
  username: string,
  step: (value: SetupStep) => void,
): Promise<AccountKey> {
  step('account');
  const account = await generateAccountKey();
  // Пароль не нужен: приватная часть остаётся в сейфе браузера, на сервер уходит
  // только публичный ключ. replace=true — прежний ключ всё равно недоступен.
  await publishAccountKey(api, username, account, 'local', '', true);
  await saveDeviceVault({ accountPkcs8: account.pkcs8, accountPublic: account.publicKey });
  return account;
}

/**
 * Пара v2: из сейфа, из серверной копии по паролю либо новая.
 * Чужую identity не подменяем — иначе телефон перестанет сходиться с сервером.
 */
async function prepareV2(
  api: ChatClient,
  username: string,
  step: (value: SetupStep) => void,
  password = '',
): Promise<{ v2: V2Keys | null; note: string }> {
  const me = await api.myIdentity().catch(() => null);

  if (!me?.identity_pub) {
    step('identity');
    const keys: V2Keys = {
      identity: identityFromSeed(randomSeed()),
      device: createDeviceKeyPair(),
    };
    await activateV2Pair(api, { username, keys, uploadCopy: false, password: '' });
    return { v2: keys, note: '' };
  }

  const stored = await v2FromDevice();
  if (stored && toBase64(stored.identity.publicKey) === me.identity_pub) {
    step('device');
    try {
      await activateV2Pair(api, { username, keys: stored, uploadCopy: false, password: '' });
    } catch (cause) {
      if (!(cause instanceof ApiError)) throw cause;
    }
    return { v2: stored, note: '' };
  }

  if (password && me.identity_priv_encrypted && me.identity_salt) {
    const restored = await unlockV2(api, { password, username }).catch(() => null);
    if (restored) return { v2: restored, note: '' };
  }

  return {
    v2: null,
    note: 'Ключ переписки создан в другом клиенте — здесь доступны только старые сообщения.',
  };
}

/** Сейф браузера пуст: либо открываем серверную копию паролем, либо создаём новую. */
export async function prepareAccount(
  api: ChatClient,
  username: string,
  step: (value: SetupStep) => void = () => {},
  password = '',
): Promise<SetupResult> {
  const account = password
    ? await unlockAccount(api, password, username)
    : (await accountFromDevice()) ?? (await createAccountKey(api, username, step));
  const { v2, note } = await prepareV2(api, username, step, password);
  return { account, v2, note };
}
