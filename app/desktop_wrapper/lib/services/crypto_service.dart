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
  static const _secure = FlutterSecureStorage(
    aOptions: AndroidOptions(),
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
