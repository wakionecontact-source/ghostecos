export interface CryptoStatusItem {
  name: string;
  ok: boolean;
  detail: string;
}

const hasSubtle = typeof crypto !== 'undefined' && !!crypto.subtle;
const hasWasm = typeof WebAssembly === 'object';
const hasIdb = typeof indexedDB !== 'undefined';

export const cryptoStatus: CryptoStatusItem[] = [
  {
    name: 'WebCrypto (AES-GCM, PBKDF2)',
    ok: hasSubtle,
    detail: hasSubtle ? 'доступен' : 'нет',
  },
  {
    name: 'WebAssembly (Argon2id)',
    ok: hasWasm,
    detail: hasWasm ? 'доступен' : 'нет',
  },
  {
    name: 'IndexedDB (локальное хранилище)',
    ok: hasIdb,
    detail: hasIdb ? 'доступен' : 'нет',
  },
];
