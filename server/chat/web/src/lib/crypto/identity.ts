import { ed25519, x25519 } from '@noble/curves/ed25519';
import { equalBytes, randomBytes } from './bytes';
import { mnemonicToIdentitySeed } from './bip39';

export interface IdentityKeyPair {
  seed: Uint8Array;
  publicKey: Uint8Array;
}

export interface DeviceKeyPair {
  privateKey: Uint8Array;
  publicKey: Uint8Array;
}

export function identityFromSeed(seed: Uint8Array): IdentityKeyPair {
  if (seed.length !== 32) throw new Error('Identity seed: ожидается 32 байта');
  return { seed, publicKey: ed25519.getPublicKey(seed) };
}

export function identityFromMnemonic(mnemonic: string): IdentityKeyPair {
  return identityFromSeed(mnemonicToIdentitySeed(mnemonic));
}

export function signWithIdentity(identity: IdentityKeyPair, message: Uint8Array): Uint8Array {
  return ed25519.sign(message, identity.seed);
}

export function verifyIdentitySignature(
  identityPublicKey: Uint8Array,
  signature: Uint8Array,
  message: Uint8Array,
): boolean {
  if (identityPublicKey.length !== 32 || signature.length !== 64) return false;
  try {
    return ed25519.verify(signature, message, identityPublicKey);
  } catch {
    return false;
  }
}

export function createDeviceKeyPair(): DeviceKeyPair {
  const privateKey = x25519.utils.randomPrivateKey();
  return { privateKey, publicKey: x25519.getPublicKey(privateKey) };
}

export function deviceKeyPairFromPrivate(privateKey: Uint8Array): DeviceKeyPair {
  if (privateKey.length !== 32) throw new Error('Device key: ожидается 32 байта');
  return { privateKey, publicKey: x25519.getPublicKey(privateKey) };
}

/** Подпись identity над device_pub — сервер проверяет её при публикации. */
export function signDevicePrekey(identity: IdentityKeyPair, devicePublicKey: Uint8Array): Uint8Array {
  return signWithIdentity(identity, devicePublicKey);
}

export function verifySignedPrekey(
  identityPublicKey: Uint8Array,
  devicePublicKey: Uint8Array,
  signature: Uint8Array,
): boolean {
  return verifyIdentitySignature(identityPublicKey, signature, devicePublicKey);
}

export function samePublicKey(a: Uint8Array, b: Uint8Array): boolean {
  return equalBytes(a, b);
}

export const IDENTITY_CLAIM = new TextEncoder().encode('ghostchat-v2-identity-claim');

export function identityClaimSignature(identity: IdentityKeyPair): Uint8Array {
  return signWithIdentity(identity, IDENTITY_CLAIM);
}

/** Случайный device-ключ с нуля: удобно для тестов и первичной установки. */
export function randomSeed(): Uint8Array {
  return randomBytes(32);
}
