// GhostChat Keys v2 — клиентский модуль.
// Зависимости (должны быть подключены ДО этого файла):
//   - bip39_en.js (window.BIP39_EN: 2048 английских слов)
//   - tweetnacl (window.nacl): Ed25519 (sign) + X25519 (scalarMult).
//
// Web Crypto используется для: PBKDF2, HKDF, AES-256-GCM, randomValues, SHA-256.
//
// Все функции — async (Web Crypto is promise-based).

(function(global){
  'use strict';

  // ── Утилиты base64/hex ────────────────────────────────────────
  const _b64e = buf => btoa(String.fromCharCode(...new Uint8Array(buf)));
  const _b64d = s => {
    const bin = atob(s);
    const out = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
    return out;
  };
  const _u8 = s => new TextEncoder().encode(s);

  // ── BIP-39 ────────────────────────────────────────────────────

  function _binFromBytes(bytes){
    let s = '';
    for (const b of bytes) s += b.toString(2).padStart(8, '0');
    return s;
  }

  async function _sha256(bytes){
    const buf = await crypto.subtle.digest('SHA-256', bytes);
    return new Uint8Array(buf);
  }

  // Генерирует 12-словную mnemonic.
  // entropy: 16 байт → 128 бит → +4 checksum бит → 132 бит → 12 групп по 11 → 12 слов.
  async function generateMnemonic(){
    if (!global.BIP39_EN || global.BIP39_EN.length !== 2048){
      throw new Error('BIP-39 wordlist не загружен');
    }
    const entropy = crypto.getRandomValues(new Uint8Array(16));
    const hash = await _sha256(entropy);
    const checksum = hash[0] >> 4;  // 4 бита
    const bits = _binFromBytes(entropy) + (checksum.toString(2).padStart(4, '0'));
    const words = [];
    for (let i = 0; i < 12; i++){
      const idx = parseInt(bits.slice(i*11, (i+1)*11), 2);
      words.push(global.BIP39_EN[idx]);
    }
    return words.join(' ');
  }

  // Валидация: фраза распарсилась, индексы валидны, checksum совпадает.
  async function validateMnemonic(mnemonic){
    const words = mnemonic.trim().toLowerCase().split(/\s+/);
    if (words.length !== 12) return false;
    const list = global.BIP39_EN;
    let bits = '';
    for (const w of words){
      const idx = list.indexOf(w);
      if (idx < 0) return false;
      bits += idx.toString(2).padStart(11, '0');
    }
    // 132 bit = 128 + 4 чексумма
    const entropy = new Uint8Array(16);
    for (let i = 0; i < 16; i++){
      entropy[i] = parseInt(bits.slice(i*8, (i+1)*8), 2);
    }
    const cs = parseInt(bits.slice(128, 132), 2);
    const hash = await _sha256(entropy);
    return (hash[0] >> 4) === cs;
  }

  // Mnemonic → 64-байтный seed через PBKDF2-HMAC-SHA512.
  // Salt по BIP-39: "mnemonic" + passphrase. Мы используем фиксированный
  // passphrase = "ghostchat-v2" чтобы наша seed не совпадала с другими
  // криптовалютами (защита от кросс-юзаджа).
  async function mnemonicToSeed(mnemonic){
    const norm = mnemonic.trim().toLowerCase().normalize('NFKD');
    const salt = _u8('mnemonic' + 'ghostchat-v2');
    const baseKey = await crypto.subtle.importKey(
      'raw', _u8(norm), 'PBKDF2', false, ['deriveBits']
    );
    const bits = await crypto.subtle.deriveBits(
      {name: 'PBKDF2', salt, iterations: 2048, hash: 'SHA-512'},
      baseKey, 512   // 64 байта
    );
    return new Uint8Array(bits);
  }

  // ── Identity (Ed25519) ────────────────────────────────────────

  // Seed (64 байт) → Ed25519 keypair. Берём первые 32 байта seed-а
  // и пропускаем через HKDF чтобы отделить от других ключей.
  async function seedToIdentity(seed64){
    const baseKey = await crypto.subtle.importKey(
      'raw', seed64, 'HKDF', false, ['deriveBits']
    );
    const bits = await crypto.subtle.deriveBits(
      {name: 'HKDF', hash: 'SHA-256', salt: new Uint8Array(32),
       info: _u8('ghostchat-v2-identity')},
      baseKey, 256
    );
    const seed32 = new Uint8Array(bits);
    const kp = global.nacl.sign.keyPair.fromSeed(seed32);
    return {
      seed: seed32,                // 32 байта
      identity_priv: kp.secretKey, // 64 байт (NaCl secret-key = seed + pubkey)
      identity_pub:  kp.publicKey, // 32 байт
    };
  }

  async function mnemonicToIdentity(mnemonic){
    const seed64 = await mnemonicToSeed(mnemonic);
    return await seedToIdentity(seed64);
  }

  // Подпись произвольного сообщения identity_priv.
  function signWithIdentity(identity_priv_64, msgBytes){
    return global.nacl.sign.detached(msgBytes, identity_priv_64);  // 64 байта
  }

  // ── Device (X25519) ──────────────────────────────────────────

  function generateDeviceKey(){
    const kp = global.nacl.box.keyPair();  // X25519
    return {
      device_priv: kp.secretKey,  // 32 байта
      device_pub:  kp.publicKey,  // 32 байта
    };
  }

  // ── Шифрование v2 ────────────────────────────────────────────
  //
  // Envelope (raw): eph_pub(32) || iv(12) || aes_gcm_ciphertext.
  // ephemeral X25519 пара генерится на каждое сообщение → forward
  // secrecy для отправителя (eph_priv мгновенно уничтожается).
  //
  // Получатель восстанавливает shared = X25519(eph_pub, device_priv).
  // HKDF-SHA-256 (salt = 32 zeros, info = "ghostchat-v2-msg") → AES-256 key.

  async function _deriveMsgKey(shared32){
    const baseKey = await crypto.subtle.importKey(
      'raw', shared32, 'HKDF', false, ['deriveKey']
    );
    return await crypto.subtle.deriveKey(
      {name: 'HKDF', hash: 'SHA-256', salt: new Uint8Array(32),
       info: _u8('ghostchat-v2-msg')},
      baseKey,
      {name: 'AES-GCM', length: 256},
      false, ['encrypt', 'decrypt']
    );
  }

  async function encryptV2(recipient_device_pub_32, plaintextBytes){
    const eph = global.nacl.box.keyPair();
    const shared = global.nacl.scalarMult(eph.secretKey, recipient_device_pub_32);
    const aesKey = await _deriveMsgKey(shared);
    const iv = crypto.getRandomValues(new Uint8Array(12));
    const ct = await crypto.subtle.encrypt(
      {name: 'AES-GCM', iv}, aesKey, plaintextBytes
    );
    const out = new Uint8Array(32 + 12 + ct.byteLength);
    out.set(eph.publicKey, 0);
    out.set(iv, 32);
    out.set(new Uint8Array(ct), 44);
    // ephemeral secretKey остаётся в памяти этого scope и собирается GC.
    return _b64e(out);
  }

  async function decryptV2(my_device_priv_32, envelopeB64){
    const raw = _b64d(envelopeB64);
    if (raw.length < 32 + 12 + 16) throw new Error('envelope слишком короткий');
    const eph_pub = raw.slice(0, 32);
    const iv = raw.slice(32, 44);
    const ct = raw.slice(44);
    const shared = global.nacl.scalarMult(my_device_priv_32, eph_pub);
    const aesKey = await _deriveMsgKey(shared);
    const pt = await crypto.subtle.decrypt({name: 'AES-GCM', iv}, aesKey, ct);
    return new Uint8Array(pt);
  }

  // ── Шифрование identity_priv паролем (для server-mode recovery) ──

  async function _derivePwdKey(password, salt16){
    const baseKey = await crypto.subtle.importKey(
      'raw', _u8(password), 'PBKDF2', false, ['deriveKey']
    );
    return await crypto.subtle.deriveKey(
      {name: 'PBKDF2', salt: salt16, iterations: 260000, hash: 'SHA-256'},
      baseKey, {name: 'AES-GCM', length: 256}, false, ['encrypt', 'decrypt']
    );
  }

  // identity_priv 64 байта → encrypted(iv+ct) base64 + salt base64.
  async function encryptIdentityWithPassword(identity_priv_64, password){
    const salt = crypto.getRandomValues(new Uint8Array(16));
    const aes = await _derivePwdKey(password, salt);
    const iv = crypto.getRandomValues(new Uint8Array(12));
    const ct = await crypto.subtle.encrypt({name: 'AES-GCM', iv}, aes, identity_priv_64);
    const blob = new Uint8Array(12 + ct.byteLength);
    blob.set(iv); blob.set(new Uint8Array(ct), 12);
    return {encrypted: _b64e(blob), salt: _b64e(salt)};
  }

  async function decryptIdentityWithPassword(encryptedB64, saltB64, password){
    const blob = _b64d(encryptedB64);
    const salt = _b64d(saltB64);
    const aes = await _derivePwdKey(password, salt);
    const iv = blob.slice(0, 12);
    const ct = blob.slice(12);
    const pt = await crypto.subtle.decrypt({name: 'AES-GCM', iv}, aes, ct);
    return new Uint8Array(pt);  // 64 байта
  }

  // ── Hash для seed-фразы (хранить не сами слова, а хэш для верификации) ──

  async function hashMnemonic(mnemonic){
    const norm = mnemonic.trim().toLowerCase().normalize('NFKD');
    const hash = await _sha256(_u8(norm));
    return _b64e(hash);  // 32 байта в base64
  }

  // ── Экспорт публичного API ──

  global.GhostKeysV2 = {
    // BIP-39
    generateMnemonic, validateMnemonic, mnemonicToSeed,
    // Identity
    mnemonicToIdentity, seedToIdentity, signWithIdentity,
    // Device
    generateDeviceKey,
    // Сообщения
    encryptV2, decryptV2,
    // Password
    encryptIdentityWithPassword, decryptIdentityWithPassword,
    // Utils
    hashMnemonic,
    _b64e, _b64d, _u8,
  };
})(window);
