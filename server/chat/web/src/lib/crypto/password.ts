import { hmac } from '@noble/hashes/hmac';
import { pbkdf2 } from '@noble/hashes/pbkdf2';
import { sha256 } from '@noble/hashes/sha2';
import { argon2id } from 'hash-wasm';
import { equalBytes, fromBase64Url, randomBytes, toBase64Url, utf8, xorBytes } from './bytes';

/** Параметры регистрации: сервер обязан принимать ровно эти границы. */
export const REGISTRATION_KDF = {
  name: 'argon2id',
  version: 19,
  iterations: 3,
  memory_kib: 65536,
  parallelism: 1,
  hash_len: 32,
} as const;

export interface PasswordVerifier {
  salt: string;
  kdf: typeof REGISTRATION_KDF;
  stored_key: string;
  server_key: string;
}

export interface PasswordChallenge {
  purpose: string;
  username: string;
  challenge_id: string;
  client_nonce: string;
  server_nonce: string;
  context: string;
  salt: string;
  kdf: Record<string, unknown>;
}

export interface PasswordProof {
  clientProof: string;
  expectedServerProof: string;
}

function canonicalJson(value: unknown): string {
  return JSON.stringify(canonicalize(value));
}

function canonicalize(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(canonicalize);
  if (value && typeof value === 'object') {
    const source = value as Record<string, unknown>;
    const out: Record<string, unknown> = {};
    for (const key of Object.keys(source).sort()) out[key] = canonicalize(source[key]);
    return out;
  }
  return value;
}

function intParam(map: Record<string, unknown>, key: string): number {
  const value = map[key];
  if (typeof value === 'number' && Number.isInteger(value)) return value;
  throw new Error(`Нет параметра KDF: ${key}`);
}

function requireString(map: Record<string, unknown>, key: string): string {
  const value = map[key];
  if (typeof value === 'string' && value.length > 0) return value;
  throw new Error(`Нет поля challenge: ${key}`);
}

export async function deriveSaltedPassword(
  password: string,
  salt: Uint8Array,
  kdf: Record<string, unknown>,
): Promise<Uint8Array> {
  const hashLength = intParam(kdf, 'hash_len');
  if (hashLength !== 32 || salt.length < 16 || salt.length > 64) {
    throw new Error('Некорректные параметры проверки пароля');
  }

  if (kdf.name === 'argon2id') {
    const version = intParam(kdf, 'version');
    const iterations = intParam(kdf, 'iterations');
    const memory = intParam(kdf, 'memory_kib');
    const parallelism = intParam(kdf, 'parallelism');
    if (version !== 19 || iterations < 1 || iterations > 10 || memory < 8192 || memory > 262144) {
      throw new Error('Параметры Argon2id вне допустимых границ');
    }
    if (parallelism < 1 || parallelism > 8) throw new Error('Параллелизм Argon2id вне границ');
    return argon2id({
      password,
      salt,
      parallelism,
      iterations,
      memorySize: memory,
      hashLength,
      outputType: 'binary',
    });
  }

  if (kdf.name === 'pbkdf2-sha256') {
    const iterations = intParam(kdf, 'iterations');
    if (iterations < 100000 || iterations > 2000000) {
      throw new Error('Параметры PBKDF2 вне допустимых границ');
    }
    return pbkdf2(sha256, utf8(password), salt, { c: iterations, dkLen: hashLength });
  }

  throw new Error('Неизвестный алгоритм проверки пароля');
}

function keysFromSaltedPassword(salted: Uint8Array) {
  const clientKey = hmac(sha256, salted, utf8('GhostChat Client Key v1'));
  const storedKey = sha256(clientKey);
  const serverKey = hmac(sha256, salted, utf8('GhostChat Server Key v1'));
  return { clientKey, storedKey, serverKey };
}

export async function createVerifier(password: string, salt?: Uint8Array): Promise<PasswordVerifier> {
  const verifierSalt = salt ?? randomBytes(16);
  const salted = await deriveSaltedPassword(password, verifierSalt, { ...REGISTRATION_KDF });
  const keys = keysFromSaltedPassword(salted);
  return {
    salt: toBase64Url(verifierSalt),
    kdf: REGISTRATION_KDF,
    stored_key: toBase64Url(keys.storedKey),
    server_key: toBase64Url(keys.serverKey),
  };
}

export async function contextForLogin(input: {
  deviceId?: string;
  deviceName?: string;
  platform?: string;
}): Promise<string> {
  const body = canonicalJson({
    device_id: input.deviceId ?? '',
    device_name: input.deviceName ?? '',
    platform: input.platform ?? '',
  });
  return toBase64Url(sha256(utf8(body)));
}

export async function contextForVerifier(verifier: PasswordVerifier): Promise<string> {
  return toBase64Url(sha256(utf8(canonicalJson(verifier))));
}

export async function prove(password: string, challenge: PasswordChallenge): Promise<PasswordProof> {
  const kdf = { ...challenge.kdf } as Record<string, unknown>;
  const salt = fromBase64Url(requireString({ salt: challenge.salt }, 'salt'));
  const salted = await deriveSaltedPassword(password, salt, kdf);
  const keys = keysFromSaltedPassword(salted);

  const transcript = utf8(
    `ghostchat-password-v1\n${challenge.purpose}\n${challenge.username.toLowerCase()}\n` +
      `${challenge.challenge_id}\n${challenge.client_nonce}\n${challenge.server_nonce}\n${challenge.context}`,
  );

  const signature = hmac(sha256, keys.storedKey, transcript);
  const proof = xorBytes(keys.clientKey, signature);
  const serverProof = hmac(sha256, keys.serverKey, new Uint8Array([...utf8('GhostChat Server Proof v1\n'), ...transcript]));

  return {
    clientProof: toBase64Url(proof),
    expectedServerProof: toBase64Url(serverProof),
  };
}

export function verifyServerProof(expected: string, received: unknown): boolean {
  if (typeof received !== 'string') return false;
  try {
    return equalBytes(fromBase64Url(expected), fromBase64Url(received));
  } catch {
    return false;
  }
}

export function newNonce(): string {
  return toBase64Url(randomBytes(32));
}
