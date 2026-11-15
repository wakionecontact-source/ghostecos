import type { ChatClient } from '../api/chat';
import { accountKeyFromPkcs8, decryptAccountKey, type AccountKey } from '../crypto/account-key';
import { saveDeviceVault, unlockDeviceVault } from './vault';

/** Разблокировка серверной копии ключа паролем и сохранение на устройстве. */
export async function unlockAccount(
  api: ChatClient,
  password: string,
  account: string,
): Promise<AccountKey> {
  const record = await api.myKeys();
  const key = await decryptAccountKey(record, password, account);
  await saveDeviceVault({ accountPkcs8: key.pkcs8, accountPublic: key.publicKey });
  return key;
}

/** Ключ аккаунта из хранилища устройства: вход без пароля. */
export async function accountFromDevice(): Promise<AccountKey | null> {
  const secrets = await unlockDeviceVault();
  if (!secrets?.accountPkcs8 || !secrets.accountPublic) return null;
  try {
    return await accountKeyFromPkcs8(secrets.accountPkcs8, secrets.accountPublic);
  } catch {
    return null;
  }
}
