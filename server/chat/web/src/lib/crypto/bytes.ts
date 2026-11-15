export function randomBytes(length: number): Uint8Array {
  const out = new Uint8Array(length);
  crypto.getRandomValues(out);
  return out;
}

export function concat(...parts: Uint8Array[]): Uint8Array {
  const total = parts.reduce((sum, part) => sum + part.length, 0);
  const out = new Uint8Array(total);
  let offset = 0;
  for (const part of parts) {
    out.set(part, offset);
    offset += part.length;
  }
  return out;
}

export function toBase64(bytes: Uint8Array): string {
  let binary = '';
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary);
}

export function fromBase64(value: string): Uint8Array {
  const binary = atob(value);
  const out = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) out[i] = binary.charCodeAt(i);
  return out;
}

export function toBase64Url(bytes: Uint8Array): string {
  return toBase64(bytes).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

export function fromBase64Url(value: string): Uint8Array {
  const padded = value.padEnd(value.length + ((4 - (value.length % 4)) % 4), '=');
  return fromBase64(padded.replace(/-/g, '+').replace(/_/g, '/'));
}

export function toHex(bytes: Uint8Array): string {
  return Array.from(bytes, (byte) => byte.toString(16).padStart(2, '0')).join('');
}

export function utf8(value: string): Uint8Array {
  return new TextEncoder().encode(value);
}

export function fromUtf8(bytes: Uint8Array): string {
  return new TextDecoder().decode(bytes);
}

/** Сравнение за постоянное время: секреты не должны утекать по таймингам. */
export function equalBytes(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a[i] ^ b[i];
  return diff === 0;
}

export function xorBytes(a: Uint8Array, b: Uint8Array): Uint8Array {
  if (a.length !== b.length) throw new Error('xorBytes: разная длина');
  const out = new Uint8Array(a.length);
  for (let i = 0; i < a.length; i++) out[i] = a[i] ^ b[i];
  return out;
}
