import type { ChatClient } from '../api/chat';
import { ApiError } from '../api/http';
import { accountFromDevice } from '../auth/account';
import { saveDeviceVault } from '../auth/vault';
import { generateAccountKey, type AccountKey } from '../crypto/account-key';
import { toBase64 } from '../crypto/bytes';
import { createDeviceKeyPair, identityFromSeed, randomSeed } from '../crypto/identity';
import { activateV2Pair, v2FromDevice, type V2Keys } from './keys';
import { publishAccountKey } from './provision';

export type SetupStep = 'account' | 'identity' | 'device';

export interface SetupResult {
  account: AccountKey;
  v2: V2Keys | null;
  /** Почему v2 не поднят — показываем, но вход не блокируем. */
  note: string;
}

/** Ключ аккаунта: из сейфа браузера, иначе новый — сразу с заменой прежнего. */
async function prepareAccountKey(
  api: ChatClient,
  username: string,
  step: (value: SetupStep) => void,
): Promise<AccountKey> {
  const stored = await accountFromDevice();
  if (stored) return stored;

  step('account');
  const account = await generateAccountKey();
  // Пароль не нужен: приватная часть остаётся в сейфе браузера, на сервер уходит
  // только публичный ключ. replace=true — ключ прежнего устройства всё равно потерян.
  await publishAccountKey(api, username, account, 'local', '', true);
  await saveDeviceVault({ accountPkcs8: account.pkcs8, accountPublic: account.publicKey });
  return account;
}

/**
 * Пара v2 поднимается без пароля: identity либо уже в сейфе, либо создаётся здесь.
 * Чужую identity не подменяем — иначе телефон перестанет сходиться с сервером.
 */
async function prepareV2(
  api: ChatClient,
  username: string,
  step: (value: SetupStep) => void,
): Promise<{ v2: V2Keys | null; note: string }> {
  const me = await api.myIdentity().catch(() => null);
  const stored = await v2FromDevice();

  if (!me?.identity_pub) {
    step('identity');
    const keys: V2Keys = {
      identity: identityFromSeed(randomSeed()),
      device: createDeviceKeyPair(),
    };
    await activateV2Pair(api, { username, keys, uploadCopy: false, password: '' });
    return { v2: keys, note: '' };
  }

  if (!stored) {
    return {
      v2: null,
      note: 'Ключ переписки создан в другом клиенте — здесь доступны только старые сообщения.',
    };
  }

  if (toBase64(stored.identity.publicKey) !== me.identity_pub) {
    return {
      v2: null,
      note: 'В браузере лежит ключ другого аккаунта — он не используется.',
    };
  }

  step('device');
  try {
    await activateV2Pair(api, { username, keys: stored, uploadCopy: false, password: '' });
  } catch (cause) {
    if (!(cause instanceof ApiError)) throw cause;
  }
  return { v2: stored, note: '' };
}

/** Полная подготовка аккаунта после входа: ключ аккаунта и пара v2 из сейфа браузера. */
export async function prepareAccount(
  api: ChatClient,
  username: string,
  step: (value: SetupStep) => void = () => {},
): Promise<SetupResult> {
  const account = await prepareAccountKey(api, username, step);
  const { v2, note } = await prepareV2(api, username, step);
  return { account, v2, note };
}
