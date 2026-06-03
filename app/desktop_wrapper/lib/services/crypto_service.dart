// E2E-криптография Ghost. Совместима с WebCrypto на веб-фронте.
//
// Схема (parity с server/chat/index.html):
//   1. Генерация пары P-256 (ECDH) per-user, приват хранится в SecureStorage.
//   2. Загрузка чужих публичных ключей (TOFU pinning будет в DbService).
//   3. ECDH(my_priv, their_pub) → shared bits (32 байта).
//   4. HKDF-SHA256(shared, salt=zeros32, info='ghostchat-msg-v1') → AES-256 ключ.
//   5. AES-GCM(key, iv=random12) → ciphertext.
//   6. Wire-формат envelope: base64(iv || ciphertext || tag).
//
// Веб-фронт сейчас использует HKDF с нулевым salt — повторяем тот же подход
// чтобы native мог расшифровать сообщения, отправленные с веба. Per-pair salt
// будет в Phase 3 крипто-апгрейда (синхронно с веб-фронтом).

import 'dart:convert';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class CryptoService {
  CryptoService._();
  static final CryptoService instance = CryptoService._();

  static const _secureKeyPrivD = 'gs_e2e_priv_d';        // только D (32 байта)
  static const _secureKeyPubRaw = 'gs_e2e_pub_raw';      // 65 байт raw (04 || X || Y)
  static const _secure = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  final Ecdh _ecdh = Ecdh.p256(length: 32);
  final Hkdf _hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
  final AesGcm _aes = AesGcm.with256bits();

  EcKeyPair? _keyPair;            // приватная половина живёт здесь
  Uint8List? _myPubRaw;           // публичная половина

  /// Загрузить ключи из secure storage или сгенерировать новые. Вызывать после
  /// успешного login/register, до того как чат начнёт работать.
  Future<Uint8List> ensureKeys() async {
    if (_keyPair != null && _myPubRaw != null) return _myPubRaw!;
    final priv = await _secure.read(key: _secureKeyPrivD);
    final pub = await _secure.read(key: _secureKeyPubRaw);
    if (priv != null && pub != null) {
      final d = base64Decode(priv);
      final pubRaw = base64Decode(pub);
      final xy = _rawToXY(pubRaw);
      _keyPair = EcKeyPairData(
        d: d,
        x: xy[0],
        y: xy[1],
        type: KeyPairType.p256,
      );
      _myPubRaw = Uint8List.fromList(pubRaw);
      return _myPubRaw!;
    }
    return _generateAndStore();
  }

  Future<Uint8List> _generateAndStore() async {
    final pair = await _ecdh.newKeyPair();
    final data = await pair.extract();
    final rawPub = _xyToRaw(data.x, data.y);
    await _secure.write(key: _secureKeyPrivD, value: base64Encode(data.d));
    await _secure.write(key: _secureKeyPubRaw, value: base64Encode(rawPub));
    _keyPair = data;
    _myPubRaw = rawPub;
    return rawPub;
  }

  /// Мой публичный ключ в формате который сервер ожидает (raw 65 байт).
  /// Передаётся в POST /api/chat/keys.
  Future<Uint8List> myPublicKeyRaw() async {
    if (_myPubRaw != null) return _myPubRaw!;
    return ensureKeys();
  }

  /// Стереть приватный ключ (logout / смена пароля / удаление аккаунта).
  Future<void> wipe() async {
    _keyPair = null;
    _myPubRaw = null;
    await _secure.delete(key: _secureKeyPrivD);
    await _secure.delete(key: _secureKeyPubRaw);
  }

  /// Зашифровать payload для конкретного peer-а.
  /// [theirPubRaw] = 65-байт uncompressed (как сервер хранит x25519_pub).
  /// Возвращает envelope в base64 = iv(12) || ciphertext || tag(16).
  Future<String> encryptFor({
    required Uint8List theirPubRaw,
    required String plaintext,
  }) async {
    final aesKey = await _deriveAesKey(theirPubRaw);
    final iv = _aes.newNonce();
    final secret = await _aes.encrypt(
      utf8.encode(plaintext),
      secretKey: aesKey,
      nonce: iv,
    );
    final out = BytesBuilder()
      ..add(iv)
      ..add(secret.cipherText)
      ..add(secret.mac.bytes);
    return base64Encode(out.toBytes());
  }

  /// Расшифровать envelope от конкретного peer-а.
  /// Возвращает plaintext или бросает исключение.
  Future<String> decryptFrom({
    required Uint8List theirPubRaw,
    required String envelopeB64,
  }) async {
    final aesKey = await _deriveAesKey(theirPubRaw);
    final bytes = base64Decode(envelopeB64);
    if (bytes.length < 12 + 16) {
      throw Exception('envelope too short');
    }
    final iv = bytes.sublist(0, 12);
    final macBytes = bytes.sublist(bytes.length - 16);
    final ct = bytes.sublist(12, bytes.length - 16);
    final clear = await _aes.decrypt(
      SecretBox(ct, nonce: iv, mac: Mac(macBytes)),
      secretKey: aesKey,
    );
    return utf8.decode(clear);
  }

  /// ECDH(my_priv, their_pub) → HKDF → AES-256 ключ.
  /// salt = zeros(32), info = 'ghostchat-msg-v1' (parity с веб-фронтом).
  Future<SecretKey> _deriveAesKey(Uint8List theirPubRaw) async {
    if (_keyPair == null) await ensureKeys();
    final theirXY = _rawToXY(theirPubRaw);
    final theirPub = EcPublicKey(
      x: theirXY[0],
      y: theirXY[1],
      type: KeyPairType.p256,
    );
    final shared = await _ecdh.sharedSecretKey(
      keyPair: _keyPair!,
      remotePublicKey: theirPub,
    );
    return _hkdf.deriveKey(
      secretKey: shared,
      nonce: Uint8List(32),                        // salt — нули
      info: utf8.encode('ghostchat-msg-v1'),
    );
  }

  // ─── Helpers для конвертации raw ↔ XY ────────────────────────────────
  /// 65 байт `04 || X || Y` → [X(32), Y(32)].
  List<List<int>> _rawToXY(List<int> raw) {
    final body = (raw.length == 65 && raw[0] == 0x04) ? raw.sublist(1) : raw;
    if (body.length != 64) {
      throw Exception('expected 64-byte (X||Y) public key, got ${body.length}');
    }
    return [body.sublist(0, 32), body.sublist(32, 64)];
  }

  /// X(32) + Y(32) → 65 байт `04 || X || Y` (uncompressed marker первым).
  Uint8List _xyToRaw(List<int> x, List<int> y) {
    final out = Uint8List(65)..[0] = 0x04;
    out.setRange(1, 33, x);
    out.setRange(33, 65, y);
    return out;
  }
}
