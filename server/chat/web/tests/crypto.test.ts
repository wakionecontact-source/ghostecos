import { describe, expect, it } from 'vitest';
import vectors from './vectors.json';
import { decryptAttachment, encryptAttachment } from '../src/lib/crypto/attachment';
import { fromBase64, fromUtf8, toBase64, toBase64Url } from '../src/lib/crypto/bytes';
import { decryptForMe, encryptV2 } from '../src/lib/crypto/envelope';
import { mnemonicToIdentitySeed, validateMnemonic } from '../src/lib/crypto/bip39';
import {
  deviceKeyPairFromPrivate,
  identityFromSeed,
  signDevicePrekey,
  verifySignedPrekey,
} from '../src/lib/crypto/identity';
import { exportEncryptedIdentity, importEncryptedIdentity } from '../src/lib/crypto/identity-backup';
import {
  REGISTRATION_KDF,
  contextForLogin,
  createVerifier,
  deriveSaltedPassword,
  prove,
  verifyServerProof,
} from '../src/lib/crypto/password';

const identity = identityFromSeed(fromBase64(vectors.seed32));
const device = deviceKeyPairFromPrivate(fromBase64(vectors.device_priv));

describe('BIP-39 и identity', () => {
  it('мнемоника валидна по контрольной сумме', () => {
    expect(validateMnemonic(vectors.mnemonic)).toBe(true);
  });

  it('seed и Ed25519-ключ совпадают с Dart', () => {
    expect(toBase64(mnemonicToIdentitySeed(vectors.mnemonic))).toBe(vectors.seed32);
    expect(toBase64(identity.publicKey)).toBe(vectors.identity_pub);
  });

  it('подпись device_pub проверяется identity', () => {
    const signature = signDevicePrekey(identity, device.publicKey);
    expect(toBase64(device.publicKey)).toBe(vectors.device_pub);
    expect(toBase64(signature)).toBe(vectors.signed_prekey_sig);
    expect(
      verifySignedPrekey(identity.publicKey, device.publicKey, fromBase64(vectors.signed_prekey_sig)),
    ).toBe(true);
  });
});

describe('E2E-конверт v2', () => {
  it('шифрует в конверт, идентичный Dart', async () => {
    const envelope = await encryptV2(device.publicKey, fromBase64(vectors.envelope_plaintext), {
      ephemeralPrivate: fromBase64(vectors.ephemeral_priv),
      iv: fromBase64(vectors.envelope_iv),
    });
    expect(envelope).toBe(vectors.envelope);
  });

  it('расшифровывает конверт Dart', async () => {
    const plain = await decryptForMe(device.privateKey, vectors.envelope);
    expect(fromUtf8(plain)).toBe('привет, ghost');
  });
});

describe('вложения', () => {
  it('шифрование совпадает с Dart', async () => {
    const attachment = await encryptAttachment(fromBase64(vectors.attachment_plaintext), {
      key: fromBase64(vectors.attachment_key),
      iv: fromBase64(vectors.attachment_iv),
    });
    expect(attachment.blob).toBe(vectors.attachment_blob);
    const decrypted = await decryptAttachment(attachment);
    expect(fromUtf8(decrypted)).toBe('файл');
  });
});

describe('identity-бэкап', () => {
  it('контейнер совпадает с Dart и восстанавливается', async () => {
    const backup = await exportEncryptedIdentity(identity, vectors.backup_password, {
      salt: fromBase64(vectors.backup_salt),
      iv: fromBase64(vectors.backup_iv),
    });
    expect(backup.identity_priv_encrypted).toBe(vectors.backup_container);
    expect(backup.identity_kdf).toBe('pbkdf2-sha256-v1-i260000');

    const restored = await importEncryptedIdentity({
      encryptedB64: vectors.backup_container,
      saltB64: vectors.backup_salt,
      password: vectors.backup_password,
      expectedIdentityPubB64: vectors.identity_pub,
    });
    expect(toBase64(restored.seed)).toBe(vectors.seed32);
  });
});

describe('пароль (Argon2id + challenge)', () => {
  const salt = fromBase64(vectors.verifier_salt);

  it('salted password и ключи совпадают с Dart', async () => {
    const salted = await deriveSaltedPassword(vectors.verifier_password, salt, { ...REGISTRATION_KDF });
    expect(toBase64(salted)).toBe(vectors.verifier_salted_password);

    const verifier = await createVerifier(vectors.verifier_password, salt);
    expect(verifier.stored_key).toBe(vectors.verifier_stored_key);
    expect(verifier.server_key).toBe(vectors.verifier_server_key);
  });

  it('proof совпадает с Dart', async () => {
    const proof = await prove(vectors.verifier_password, {
      purpose: 'login',
      username: vectors.proof_username,
      challenge_id: vectors.proof_challenge_id,
      client_nonce: vectors.proof_client_nonce,
      server_nonce: vectors.proof_server_nonce,
      context: vectors.proof_context,
      salt: toBase64Url(salt),
      kdf: { ...REGISTRATION_KDF },
    });
    expect(proof.clientProof).toBe(vectors.proof_client_proof);
    expect(verifyServerProof(proof.expectedServerProof, vectors.proof_server_proof)).toBe(true);
  });

  it('контекст входа не зависит от порядка полей', async () => {
    const a = await contextForLogin({ deviceId: 'd1', deviceName: 'Web', platform: 'browser' });
    const b = await contextForLogin({ platform: 'browser', deviceName: 'Web', deviceId: 'd1' });
    expect(a).toBe(b);
    expect(a).toMatch(/^[A-Za-z0-9_-]+$/);
  });
});
