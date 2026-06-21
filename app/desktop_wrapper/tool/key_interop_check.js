// Node WebCrypto-сторона кросс-проверки server-режима (тот же движок, что веб).
// Читает tool/dart_fixture.json, валидирует, пишет tool/node_fixture.json.
//
// Запуск: node tool/key_interop_check.js
const { webcrypto } = require('crypto');
const fs = require('fs');
const subtle = webcrypto.subtle;

const b64ToBuf = (s) => Buffer.from(s, 'base64');
const bufToB64 = (b) => Buffer.from(b).toString('base64');
const b64urlToBuf = (s) => Buffer.from(s.replace(/-/g, '+').replace(/_/g, '/'), 'base64');

async function deriveMaster(password, salt) {
  const base = await subtle.importKey('raw', Buffer.from(password, 'utf8'), 'PBKDF2', false, ['deriveKey']);
  return subtle.deriveKey(
    { name: 'PBKDF2', salt, iterations: 260000, hash: 'SHA-256' },
    base, { name: 'AES-GCM', length: 256 }, false, ['encrypt', 'decrypt']
  );
}

// jwk.x/y (base64url, 32) → raw pub 0x04||X||Y (65) base64
function jwkToPubB64(jwk) {
  const x = b64urlToBuf(jwk.x), y = b64urlToBuf(jwk.y);
  return bufToB64(Buffer.concat([Buffer.from([0x04]), x, y]));
}

(async () => {
  const fx = JSON.parse(fs.readFileSync(__dirname + '/dart_fixture.json', 'utf8'));
  let pass = true;
  const log = (ok, msg) => { if (!ok) pass = false; console.log((ok ? 'PASS' : 'FAIL') + ' — ' + msg); };

  // 1. Импорт Dart-PKCS8 настоящим WebCrypto importKey('pkcs8', ECDH P-256).
  let dartPrivKey;
  try {
    dartPrivKey = await subtle.importKey('pkcs8', b64ToBuf(fx.pkcs8),
      { name: 'ECDH', namedCurve: 'P-256' }, true, ['deriveBits']);
    log(true, 'WebCrypto импортировал Dart-PKCS8');
  } catch (e) {
    log(false, 'WebCrypto НЕ импортировал Dart-PKCS8: ' + e.message);
  }
  // d и pub из импортированного ключа совпадают с фикстурой?
  if (dartPrivKey) {
    const jwk = await subtle.exportKey('jwk', dartPrivKey);
    const dHex = Buffer.from(b64urlToBuf(jwk.d)).toString('hex');
    log(dHex === fx.d, `d совпал (web=${dHex.slice(0, 12)}… dart=${fx.d.slice(0, 12)}…)`);
    log(jwkToPubB64(jwk) === fx.pub, 'pub совпал');
  }

  // 2. Полный server-блоб: WebCrypto расшифровывает Dart enc паролем → PKCS8 → import.
  try {
    const enc = b64ToBuf(fx.enc);
    const iv = enc.subarray(0, 12), ct = enc.subarray(12);
    const master = await deriveMaster(fx.password, b64ToBuf(fx.salt));
    const pkcs8 = Buffer.from(await subtle.decrypt({ name: 'AES-GCM', iv }, master, ct));
    const k = await subtle.importKey('pkcs8', pkcs8, { name: 'ECDH', namedCurve: 'P-256' }, true, ['deriveBits']);
    const jwk = await subtle.exportKey('jwk', k);
    const dHex = Buffer.from(b64urlToBuf(jwk.d)).toString('hex');
    log(dHex === fx.d, 'WebCrypto расшифровал Dart-блоб паролем → d совпал');
  } catch (e) {
    log(false, 'WebCrypto не расшифровал Dart-блоб: ' + e.message);
  }

  // 3. Обратная фикстура: WebCrypto генерит ключ, экспортит PKCS8, шифрует приват паролем.
  const pair = await subtle.generateKey({ name: 'ECDH', namedCurve: 'P-256' }, true, ['deriveBits']);
  const pkcs8 = Buffer.from(await subtle.exportKey('pkcs8', pair.privateKey));
  const jwk = await subtle.exportKey('jwk', pair.privateKey);
  const dHex = Buffer.from(b64urlToBuf(jwk.d)).toString('hex');
  const pubB64 = jwkToPubB64(jwk);
  const password = 'NodeSide456!';
  const salt = webcrypto.getRandomValues(new Uint8Array(16));
  const iv = webcrypto.getRandomValues(new Uint8Array(12));
  const master = await deriveMaster(password, salt);
  const ct = Buffer.from(await subtle.encrypt({ name: 'AES-GCM', iv }, master, pkcs8));
  const blob = Buffer.concat([Buffer.from(iv), ct]);
  fs.writeFileSync(__dirname + '/node_fixture.json', JSON.stringify({
    pkcs8: bufToB64(pkcs8), enc: bufToB64(blob), salt: bufToB64(salt),
    password, d: dHex, pub: pubB64,
  }));
  console.log('node_fixture.json записан (WebCrypto-PKCS8 для обратной сверки в Dart)');

  console.log(pass ? '\nИТОГ: ВСЕ ПРОВЕРКИ ПРОЙДЕНЫ ✓' : '\nИТОГ: ЕСТЬ ПРОВАЛЫ ✗');
  process.exit(pass ? 0 : 1);
})();
