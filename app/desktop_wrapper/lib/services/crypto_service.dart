// E2E-криптография Ghost — pure Dart через pointycastle.
//
// Bit-by-bit совместимо с веб-фронтом (WebCrypto subtle):
//   1. ECDH на кривой P-256 (secp256r1)
//   2. HKDF-SHA256(shared, salt=zeros32, info='ghostchat-msg-v1') → 32-byte AES key
//   3. AES-GCM(key, iv=12 random bytes) → ciphertext+tag
//   4. Wire-формат envelope: base64(iv(12) || ciphertext || tag(16))
//
// Приват хранится в SecureStorage как PKCS8 (Keystore/Keychain).
// Публичный — 65 байт uncompressed (0x04 || X(32) || Y(32)).
//
// Pure Dart — без native plugin'ов, работает на любой compileSdk.

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:pointycastle/export.dart';

class CryptoService {
  CryptoService._();
  static final CryptoService instance = CryptoService._();

  static const _kPrivD = 'gs_e2e_priv_d_v3';        // приват D-coordinate (32 bytes b64)
  static const _kPubRaw = 'gs_e2e_pub_raw_v3';       // 65 bytes uncompressed (b64)
  /// EncryptedSharedPreferences=true — AES-GCM шифрование значений в SharedPrefs,
  /// иначе на старом Android приват-ключ лежит в plain SharedPrefs.
  static const _secure = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  // Curve params
  static final ECDomainParameters _curve = ECDomainParameters('secp256r1');

  // Cached keys per-session
  BigInt? _privD;
  ECPublicKey? _myPub;
  Uint8List? _myPubRaw;

  /// Загрузить ключи из SecureStorage или сгенерировать новые.
  /// Возвращает свой публичный ключ в raw-формате (65 байт).
  Future<Uint8List> ensureKeys() async {
    if (_myPubRaw != null) return _myPubRaw!;
    final priv = await _secure.read(key: _kPrivD);
    final pub = await _secure.read(key: _kPubRaw);
    if (priv != null && pub != null) {
      _privD = _decodeBigInt(base64Decode(priv));
      _myPubRaw = Uint8List.fromList(base64Decode(pub));
      _myPub = _rawToPub(_myPubRaw!);
      return _myPubRaw!;
    }
    return _generateAndStore();
  }

  Future<Uint8List> _generateAndStore() async {
    final pair = _generateKeyPair();
    final priv = pair.privateKey as ECPrivateKey;
    final pub = pair.publicKey as ECPublicKey;
    final dBytes = _encodeBigInt(priv.d!, 32);
    final pubRaw = _pubToRaw(pub);
    await _secure.write(key: _kPrivD, value: base64Encode(dBytes));
    await _secure.write(key: _kPubRaw, value: base64Encode(pubRaw));
    _privD = priv.d;
    _myPub = pub;
    _myPubRaw = pubRaw;
    return pubRaw;
  }

  AsymmetricKeyPair<PublicKey, PrivateKey> _generateKeyPair() {
    final gen = ECKeyGenerator();
    final rnd = FortunaRandom();
    final seedSrc = Random.secure();
    final seed = Uint8List.fromList(List<int>.generate(32, (_) => seedSrc.nextInt(256)));
    rnd.seed(KeyParameter(seed));
    gen.init(ParametersWithRandom(ECKeyGeneratorParameters(_curve), rnd));
    return gen.generateKeyPair();
  }

  Future<Uint8List> myPublicKeyRaw() async {
    if (_myPubRaw != null) return _myPubRaw!;
    return ensureKeys();
  }

  Future<void> wipe() async {
    _privD = null;
    _myPub = null;
    _myPubRaw = null;
    await _secure.delete(key: _kPrivD);
    await _secure.delete(key: _kPubRaw);
  }

  // ════════════════════════════════════════════════════════════════════
  // SERVER-режим хранения приватника: приватник, зашифрованный паролем,
  // лежит на сервере (users.encrypted_private_key). Формат БАЙТ-В-БАЙТ
  // совместим с веб-GhostChat (WebCrypto subtle):
  //   PKCS8(P-256 priv) → AES-GCM( PBKDF2(pwd, salt16, 260000, SHA-256), iv12 )
  //   encrypted_private_key = base64( iv(12) || ct||tag ),  key_salt = base64(salt16)
  // Проверено кросс-тестом против WebCrypto: tool/key_interop_check.{dart,js}.
  // ════════════════════════════════════════════════════════════════════

  // Фикс-шаблон PKCS8 для P-256 до 32-байтного D (OID ecPublicKey + prime256v1,
  // далее [1] BIT STRING с pub65). Длины фиксированы → можно вставлять D и pub.
  static final List<int> _pkcs8Head = [
    0x30, 0x81, 0x87, 0x02, 0x01, 0x00, //
    0x30, 0x13, 0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01, //
    0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07, //
    0x04, 0x6D, 0x30, 0x6B, 0x02, 0x01, 0x01, 0x04, 0x20, //
  ];
  static final List<int> _pkcs8PubTag = [0xA1, 0x44, 0x03, 0x42, 0x00];

  Uint8List _dToPkcs8(Uint8List d32, Uint8List pubRaw65) {
    final b = BytesBuilder()
      ..add(_pkcs8Head)
      ..add(d32)
      ..add(_pkcs8PubTag)
      ..add(pubRaw65);
    return b.toBytes();
  }

  // Минимальный TLV-парсер: [tag, contentStart, contentLen, next].
  List<int> _tlv(Uint8List b, int pos) {
    final tag = b[pos];
    var len = b[pos + 1];
    var hdr = 2;
    if (len & 0x80 != 0) {
      final n = len & 0x7F;
      len = 0;
      for (var i = 0; i < n; i++) {
        len = (len << 8) | b[pos + 2 + i];
      }
      hdr = 2 + n;
    }
    return [tag, pos + hdr, len, pos + hdr + len];
  }

  // Извлечь сырой 32-байтный D из ЛЮБОГО валидного PKCS8 EC-приватника
  // (в т.ч. из экспорта WebCrypto, где есть опциональный public key).
  Uint8List _pkcs8ToD(Uint8List pkcs8) {
    final outer = _tlv(pkcs8, 0); // SEQUENCE
    var p = outer[1];
    final ver = _tlv(pkcs8, p); p = ver[3]; // INTEGER version
    final alg = _tlv(pkcs8, p); p = alg[3]; // SEQUENCE alg
    final pk = _tlv(pkcs8, p); // OCTET STRING privateKey
    final inner = _tlv(pkcs8, pk[1]); // SEQUENCE ECPrivateKey
    var q = inner[1];
    final iv = _tlv(pkcs8, q); q = iv[3]; // INTEGER 1
    final dOct = _tlv(pkcs8, q); // OCTET STRING D
    var d = pkcs8.sublist(dOct[1], dOct[1] + dOct[2]);
    if (d.length > 32) d = d.sublist(d.length - 32);
    if (d.length < 32) {
      final padded = Uint8List(32);
      padded.setRange(32 - d.length, 32, d);
      d = padded;
    }
    return Uint8List.fromList(d);
  }

  // PBKDF2(password, salt, 260000, SHA-256) → 32-байтный AES-ключ (как веб).
  Uint8List _deriveMasterKey(String password, Uint8List salt) {
    final kd = PBKDF2KeyDerivator(HMac(SHA256Digest(), 64))
      ..init(Pbkdf2Parameters(salt, 260000, 32));
    return kd.process(Uint8List.fromList(utf8.encode(password)));
  }

  Uint8List _pubRawFromD(BigInt d) => _pubToRaw(ECPublicKey((_curve.G * d)!, _curve));

  /// SERVER-режим: экспортировать локальный приватник зашифрованным паролем,
  /// в формате веба. Возвращает {encrypted_private_key, key_salt} (base64) для
  /// POST /keys/upload.
  Future<Map<String, String>> exportEncryptedPrivForServer(String password) async {
    await ensureKeys();
    final d32 = _encodeBigInt(_privD!, 32);
    final pkcs8 = _dToPkcs8(d32, _myPubRaw!);
    final salt = _randomBytes(16);
    final master = _deriveMasterKey(password, salt);
    final iv = _randomBytes(12);
    final gcm = GCMBlockCipher(AESEngine())
      ..init(true, AEADParameters(KeyParameter(master), 128, iv, Uint8List(0)));
    final ct = gcm.process(pkcs8);
    final enc = (BytesBuilder()..add(iv)..add(ct)).toBytes();
    return {
      'encrypted_private_key': base64Encode(enc),
      'key_salt': base64Encode(salt),
    };
  }

  /// SERVER-режим: восстановить приватник, скачанный с сервера (расшифровать
  /// паролем), и сохранить локально. Возвращает свой pub raw (65 байт). Бросает
  /// при неверном пароле / битом блобе. После вызова identity устройства =
  /// серверная (совпадает с серверным x25519_pub).
  Future<Uint8List> importServerPriv(String encB64, String saltB64, String password) async {
    final enc = base64Decode(encB64);
    if (enc.length < 12 + 16) throw Exception('encrypted_private_key слишком короткий');
    final iv = Uint8List.fromList(enc.sublist(0, 12));
    final ct = Uint8List.fromList(enc.sublist(12));
    final master = _deriveMasterKey(password, Uint8List.fromList(base64Decode(saltB64)));
    final gcm = GCMBlockCipher(AESEngine())
      ..init(false, AEADParameters(KeyParameter(master), 128, iv, Uint8List(0)));
    final pkcs8 = gcm.process(ct); // бросит InvalidCipherText при неверном пароле
    final d = _decodeBigInt(_pkcs8ToD(pkcs8));
    final pubRaw = _pubRawFromD(d);
    _privD = d;
    _myPubRaw = pubRaw;
    _myPub = _rawToPub(pubRaw);
    await _secure.write(key: _kPrivD, value: base64Encode(_encodeBigInt(d, 32)));
    await _secure.write(key: _kPubRaw, value: base64Encode(pubRaw));
    return pubRaw;
  }

  /// Зашифровать payload для конкретного peer-а (raw 65-byte pubkey).
  /// Возвращает base64(iv(12) || ct || tag(16)).
  Future<String> encryptFor({
    required Uint8List theirPubRaw,
    required String plaintext,
  }) async {
    final aesKey = await _deriveAesKey(theirPubRaw);
    final iv = _randomBytes(12);
    final cipher = GCMBlockCipher(AESEngine());
    cipher.init(true, AEADParameters(KeyParameter(aesKey), 128, iv, Uint8List(0)));
    final plainBytes = utf8.encode(plaintext);
    final out = cipher.process(Uint8List.fromList(plainBytes));
    // out уже содержит ciphertext + tag (16 bytes в конце для 128 bit auth)
    final envelope = BytesBuilder()
      ..add(iv)
      ..add(out);
    return base64Encode(envelope.toBytes());
  }

  /// Расшифровать envelope от конкретного peer-а.
  Future<String> decryptFrom({
    required Uint8List theirPubRaw,
    required String envelopeB64,
  }) async {
    final aesKey = await _deriveAesKey(theirPubRaw);
    final bytes = base64Decode(envelopeB64);
    if (bytes.length < 12 + 16) throw Exception('envelope too short');
    final iv = Uint8List.fromList(bytes.sublist(0, 12));
    final ct = Uint8List.fromList(bytes.sublist(12));
    final cipher = GCMBlockCipher(AESEngine());
    cipher.init(false, AEADParameters(KeyParameter(aesKey), 128, iv, Uint8List(0)));
    final plain = cipher.process(ct);
    return utf8.decode(plain);
  }

  /// Зашифровать sealed envelope для receiverStaticPub.
  /// Формат envelope (binary): [ephPub(65)] || [iv(12)] || [AES-GCM(shared, iv, payload)]
  /// Shared = ECDH(eph_priv, receiver_static_pub) — БЕЗ HKDF (parity с веб).
  /// payload автоматически дополняется from_username + ts.
  Future<String> encryptSealed({
    required Uint8List receiverPubRaw,
    required Map<String, dynamic> payload,
    required String fromUsername,
  }) async {
    final pair = _generateKeyPair();
    final ephPriv = (pair.privateKey as ECPrivateKey).d!;
    final ephPub = pair.publicKey as ECPublicKey;
    final ephPubRaw = _pubToRaw(ephPub);
    final agreement = ECDHBasicAgreement()..init(ECPrivateKey(ephPriv, _curve));
    final shared = agreement.calculateAgreement(_rawToPub(receiverPubRaw));
    final aesKey = _encodeBigInt(shared, 32);
    final iv = _randomBytes(12);
    final fullPayload = <String, dynamic>{
      ...payload,
      'from_username': fromUsername,
      'ts': DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000,
    };
    final pt = utf8.encode(jsonEncode(fullPayload));
    final cipher = GCMBlockCipher(AESEngine())
      ..init(true, AEADParameters(KeyParameter(aesKey), 128, iv, Uint8List(0)));
    final ct = cipher.process(Uint8List.fromList(pt));
    final out = Uint8List(65 + 12 + ct.length);
    out.setRange(0, 65, ephPubRaw);
    out.setRange(65, 77, iv);
    out.setRange(77, 77 + ct.length, ct);
    return base64Encode(out);
  }

  /// Расшифровать sealed envelope. Возвращает {from_username, type, text, sid, ...}.
  Future<Map<String, dynamic>> decryptSealed(String envelopeB64) async {
    if (_privD == null) await ensureKeys();
    final bytes = base64Decode(envelopeB64);
    if (bytes.length < 65 + 12 + 16) {
      throw Exception('sealed envelope too short (${bytes.length})');
    }
    final ephPubRaw = Uint8List.fromList(bytes.sublist(0, 65));
    final iv = Uint8List.fromList(bytes.sublist(65, 77));
    final ct = Uint8List.fromList(bytes.sublist(77));
    final agreement = ECDHBasicAgreement()..init(ECPrivateKey(_privD, _curve));
    final shared = agreement.calculateAgreement(_rawToPub(ephPubRaw));
    final aesKey = _encodeBigInt(shared, 32);
    final cipher = GCMBlockCipher(AESEngine())
      ..init(false, AEADParameters(KeyParameter(aesKey), 128, iv, Uint8List(0)));
    final pt = cipher.process(ct);
    final json = utf8.decode(pt);
    return Map<String, dynamic>.from(jsonDecode(json) as Map);
  }

  /// ECDH → HKDF-SHA256 → 32-байт AES ключ.
  /// salt = zeros(32), info = 'ghostchat-msg-v1' — parity с веб-фронтом.
  Future<Uint8List> _deriveAesKey(Uint8List theirPubRaw) async {
    if (_privD == null) await ensureKeys();
    final theirPub = _rawToPub(theirPubRaw);
    // ECDH shared secret = scalar(d) * Point(theirPub).x → 32 байта
    final agreement = ECDHBasicAgreement()
      ..init(ECPrivateKey(_privD, _curve));
    final shared = agreement.calculateAgreement(theirPub);
    final sharedBytes = _encodeBigInt(shared, 32);
    // HKDF-SHA256
    final hkdf = HKDFKeyDerivator(SHA256Digest());
    hkdf.init(HkdfParameters(sharedBytes, 32, Uint8List(32), utf8.encode('ghostchat-msg-v1')));
    final out = Uint8List(32);
    hkdf.deriveKey(null, 0, out, 0);
    return out;
  }

  // ─── Helpers: raw <-> EC ─────────────────────────────────────────────
  Uint8List _pubToRaw(ECPublicKey pub) {
    final q = pub.Q!;
    final x = _encodeBigInt(q.x!.toBigInteger()!, 32);
    final y = _encodeBigInt(q.y!.toBigInteger()!, 32);
    final out = Uint8List(65)..[0] = 0x04;
    out.setRange(1, 33, x);
    out.setRange(33, 65, y);
    return out;
  }

  ECPublicKey _rawToPub(Uint8List raw) {
    final body = (raw.length == 65 && raw[0] == 0x04) ? raw.sublist(1) : raw;
    if (body.length != 64) {
      throw Exception('expected 64-byte X||Y, got ${body.length}');
    }
    final x = _decodeBigInt(body.sublist(0, 32));
    final y = _decodeBigInt(body.sublist(32, 64));
    final q = _curve.curve.createPoint(x, y);
    return ECPublicKey(q, _curve);
  }

  // ─── BigInt <-> bytes (big-endian, fixed length) ─────────────────────
  Uint8List _encodeBigInt(BigInt n, int length) {
    final out = Uint8List(length);
    var v = n;
    for (var i = length - 1; i >= 0 && v > BigInt.zero; i--) {
      out[i] = (v & BigInt.from(0xFF)).toInt();
      v = v >> 8;
    }
    return out;
  }

  BigInt _decodeBigInt(List<int> bytes) {
    var n = BigInt.zero;
    for (final b in bytes) {
      n = (n << 8) | BigInt.from(b & 0xFF);
    }
    return n;
  }

  Uint8List _randomBytes(int n) {
    final r = Random.secure();
    return Uint8List.fromList(List<int>.generate(n, (_) => r.nextInt(256)));
  }
}
