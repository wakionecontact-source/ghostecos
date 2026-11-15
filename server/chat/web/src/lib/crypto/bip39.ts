import { hkdf } from '@noble/hashes/hkdf';
import { pbkdf2 } from '@noble/hashes/pbkdf2';
import { sha256, sha512 } from '@noble/hashes/sha2';
import wordlistRaw from './bip39-en.txt?raw';
import { randomBytes, utf8 } from './bytes';

const WORDLIST: string[] = wordlistRaw
  .split('\n')
  .map((word) => word.trim())
  .filter((word) => word.length > 0);

if (WORDLIST.length !== 2048) {
  throw new Error(`BIP-39 wordlist: 2048 ожидалось, ${WORDLIST.length}`);
}

// Параметры совпадают с crypto_v2.dart: соль и info — часть протокола.
const SEED_SALT = 'mnemonicghostchat-v2';
const IDENTITY_INFO = 'ghostchat-v2-identity';
const PBKDF2_ITERATIONS = 2048;

function bitsFromBytes(bytes: Uint8Array): string {
  return Array.from(bytes, (byte) => byte.toString(2).padStart(8, '0')).join('');
}

export function generateMnemonic(): string {
  const entropy = randomBytes(16);
  const checksum = sha256(entropy)[0] >> 4;
  const bits = bitsFromBytes(entropy) + checksum.toString(2).padStart(4, '0');
  const words: string[] = [];
  for (let i = 0; i < 12; i++) {
    words.push(WORDLIST[parseInt(bits.slice(i * 11, (i + 1) * 11), 2)]);
  }
  return words.join(' ');
}

export function validateMnemonic(mnemonic: string): boolean {
  const parts = mnemonic.trim().toLowerCase().split(/\s+/);
  if (parts.length !== 12) return false;

  let bits = '';
  for (const word of parts) {
    const index = WORDLIST.indexOf(word);
    if (index < 0) return false;
    bits += index.toString(2).padStart(11, '0');
  }

  const entropy = new Uint8Array(16);
  for (let i = 0; i < 16; i++) {
    entropy[i] = parseInt(bits.slice(i * 8, (i + 1) * 8), 2);
  }
  const checksum = parseInt(bits.slice(128, 132), 2);
  return sha256(entropy)[0] >> 4 === checksum;
}

/** BIP-39 seed → HKDF → 32-байтовый seed identity (как в Dart-клиенте). */
export function mnemonicToIdentitySeed(mnemonic: string): Uint8Array {
  const seed64 = pbkdf2(sha512, utf8(mnemonic.trim().toLowerCase()), utf8(SEED_SALT), {
    c: PBKDF2_ITERATIONS,
    dkLen: 64,
  });
  return hkdf(sha256, seed64, new Uint8Array(32), utf8(IDENTITY_INFO), 32);
}
