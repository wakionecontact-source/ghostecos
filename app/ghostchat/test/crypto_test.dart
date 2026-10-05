// Тест что pointycastle-крипта работает encrypt-then-decrypt roundtrip
// + verify что raw 65-byte ↔ ECPublicKey конвертация симметрична.
//
// Запуск: `flutter test test/crypto_test.dart`
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/export.dart';
import 'package:ghost/services/crypto_service.dart';

// Импортируем internal helpers через прямой mini-копию здесь чтобы не
// тащить весь crypto_service (он зависит от FlutterSecureStorage).
final ECDomainParameters _curve = ECDomainParameters('secp256r1');

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
  final x = _decodeBigInt(body.sublist(0, 32));
  final y = _decodeBigInt(body.sublist(32, 64));
  final q = _curve.curve.createPoint(x, y);
  return ECPublicKey(q, _curve);
}

AsymmetricKeyPair<PublicKey, PrivateKey> _gen() {
  final gen = ECKeyGenerator();
  final rnd = FortunaRandom();
  final seed = Uint8List.fromList(List<int>.generate(32, (i) => i + 1));
  rnd.seed(KeyParameter(seed));
  gen.init(ParametersWithRandom(ECKeyGeneratorParameters(_curve), rnd));
  return gen.generateKeyPair();
}

Uint8List _deriveKey(BigInt privD, Uint8List theirPubRaw) {
  final agree = ECDHBasicAgreement()..init(ECPrivateKey(privD, _curve));
  final shared = agree.calculateAgreement(_rawToPub(theirPubRaw));
  final sharedBytes = _encodeBigInt(shared, 32);
  final hkdf = HKDFKeyDerivator(SHA256Digest());
  hkdf.init(
    HkdfParameters(
      sharedBytes,
      32,
      Uint8List(32),
      utf8.encode('ghostchat-msg-v1'),
    ),
  );
  final out = Uint8List(32);
  hkdf.deriveKey(null, 0, out, 0);
  return out;
}

String _encrypt(Uint8List aesKey, Uint8List iv, String text) {
  final cipher = GCMBlockCipher(AESEngine())
    ..init(true, AEADParameters(KeyParameter(aesKey), 128, iv, Uint8List(0)));
  final out = cipher.process(Uint8List.fromList(utf8.encode(text)));
  final env = BytesBuilder()
    ..add(iv)
    ..add(out);
  return base64Encode(env.toBytes());
}

String _decrypt(Uint8List aesKey, String envelopeB64) {
  final bytes = base64Decode(envelopeB64);
  final iv = Uint8List.fromList(bytes.sublist(0, 12));
  final ct = Uint8List.fromList(bytes.sublist(12));
  final cipher = GCMBlockCipher(AESEngine())
    ..init(false, AEADParameters(KeyParameter(aesKey), 128, iv, Uint8List(0)));
  return utf8.decode(cipher.process(ct));
}

void main() {
  late Map<String, String> secureStore;
  final crypto = CryptoService.instance;

  setUp(() async {
    secureStore = <String, String>{};
    FlutterSecureStorage.setMockInitialValues(secureStore);
    await crypto.wipe(account: 'alice', deleteStored: true);
  });

  test('ECDH P-256 roundtrip', () {
    final alice = _gen();
    final bob = _gen();
    final alicePub = _pubToRaw(alice.publicKey as ECPublicKey);
    final bobPub = _pubToRaw(bob.publicKey as ECPublicKey);
    final aliceD = (alice.privateKey as ECPrivateKey).d!;
    final bobD = (bob.privateKey as ECPrivateKey).d!;

    final aliceKey = _deriveKey(aliceD, bobPub);
    final bobKey = _deriveKey(bobD, alicePub);
    expect(
      aliceKey,
      equals(bobKey),
      reason: 'ECDH shared key should be the same on both sides',
    );
  });

  test('AES-GCM encrypt → decrypt roundtrip', () {
    final alice = _gen();
    final bob = _gen();
    final aliceD = (alice.privateKey as ECPrivateKey).d!;
    final bobD = (bob.privateKey as ECPrivateKey).d!;
    final alicePub = _pubToRaw(alice.publicKey as ECPublicKey);
    final bobPub = _pubToRaw(bob.publicKey as ECPublicKey);

    final aliceKey = _deriveKey(aliceD, bobPub);
    final bobKey = _deriveKey(bobD, alicePub);

    // Стабильный IV для теста (в проде — random)
    final iv = Uint8List.fromList(List.generate(12, (i) => i));
    final envelope = _encrypt(aliceKey, iv, 'Привет, Боб!');
    final plain = _decrypt(bobKey, envelope);
    expect(plain, equals('Привет, Боб!'));
  });

  test('pubkey raw <-> ECPublicKey round-trip', () {
    final pair = _gen();
    final raw = _pubToRaw(pair.publicKey as ECPublicKey);
    expect(raw.length, equals(65));
    expect(raw[0], equals(0x04));
    final pub2 = _rawToPub(raw);
    final raw2 = _pubToRaw(pub2);
    expect(raw, equals(raw2));
  });

  test('envelope формат стабилен: iv(12) + ct + tag(16)', () {
    final pair = _gen();
    final d = (pair.privateKey as ECPrivateKey).d!;
    final pub = _pubToRaw(pair.publicKey as ECPublicKey);
    final key = _deriveKey(d, pub); // self-encrypt for size check
    final iv = Uint8List(12);
    final env = base64Decode(_encrypt(key, iv, 'x'));
    expect(
      env.length,
      equals(12 + 1 + 16),
      reason: 'iv(12) + ct(1 байт plaintext "x") + GCM tag(16)',
    );
  });

  test('server key container: Argon2id + AES-GCM roundtrip', () async {
    final pub = await crypto.myPublicKeyRaw(account: 'alice');
    final blob = await crypto.exportEncryptedPrivForServer(
      'correct horse battery staple',
      account: 'alice',
    );

    expect(blob['key_kdf'], CryptoService.serverKeyKdfArgon2id);
    expect(blob['key_format'], CryptoService.serverKeyFormatV2);
    expect(base64Decode(blob['key_salt']!).length, 16);

    await crypto.wipe(account: 'alice');
    final recovered = await crypto.importServerPriv(
      blob['encrypted_private_key']!,
      blob['key_salt']!,
      'correct horse battery staple',
      account: 'alice',
      keyKdf: blob['key_kdf'],
      keyFormat: blob['key_format'],
    );
    expect(recovered, equals(pub));
  });

  test('metadata-free Argon2id container remains recoverable', () async {
    final pub = await crypto.myPublicKeyRaw(account: 'alice');
    final blob = await crypto.exportEncryptedPrivForServer(
      'metadata-free-pass',
      account: 'alice',
    );

    await crypto.wipe(account: 'alice');
    final recovered = await crypto.importServerPriv(
      blob['encrypted_private_key']!,
      blob['key_salt']!,
      'metadata-free-pass',
      account: 'alice',
    );
    expect(recovered, equals(pub));
  });

  test(
    'server key container rejects wrong password, tampering, and AAD swap',
    () async {
      await crypto.myPublicKeyRaw(account: 'alice');
      final blob = await crypto.exportEncryptedPrivForServer(
        'only-the-right-password',
        account: 'alice',
      );

      Future<void> expectFailure(Future<void> action) async {
        await expectLater(action, throwsA(anything));
      }

      await expectFailure(
        crypto.importServerPriv(
          blob['encrypted_private_key']!,
          blob['key_salt']!,
          'wrong-password',
          account: 'alice',
          keyKdf: blob['key_kdf'],
          keyFormat: blob['key_format'],
        ),
      );

      final encoded = base64Decode(blob['encrypted_private_key']!);
      encoded[encoded.length - 1] ^= 0x01;
      await expectFailure(
        crypto.importServerPriv(
          base64Encode(encoded),
          blob['key_salt']!,
          'only-the-right-password',
          account: 'alice',
          keyKdf: blob['key_kdf'],
          keyFormat: blob['key_format'],
        ),
      );

      await expectFailure(
        crypto.importServerPriv(
          blob['encrypted_private_key']!,
          blob['key_salt']!,
          'only-the-right-password',
          account: 'mallory',
          keyKdf: blob['key_kdf'],
          keyFormat: blob['key_format'],
        ),
      );
    },
  );

  test(
    'server key parser rejects malformed input before expensive KDF',
    () async {
      for (var i = 0; i < 10000; i++) {
        final malformed = base64Encode(Uint8List.fromList(<int>[i & 0xff]));
        await expectLater(
          crypto.importServerPriv(
            malformed,
            base64Encode(Uint8List(16)),
            'password',
            account: 'alice',
            keyKdf: CryptoService.serverKeyKdfArgon2id,
            keyFormat: CryptoService.serverKeyFormatV2,
          ),
          throwsA(anything),
        );
      }
    },
  );

  test(
    'legacy PBKDF2 container remains importable only without new metadata',
    () async {
      final pair = _gen();
      final d = _encodeBigInt((pair.privateKey as ECPrivateKey).d!, 32);
      final pub = _pubToRaw(pair.publicKey as ECPublicKey);
      final pkcs8 = _legacyPkcs8(d, pub);
      final salt = Uint8List.fromList(List<int>.generate(16, (i) => i + 10));
      final kd = PBKDF2KeyDerivator(HMac(SHA256Digest(), 64))
        ..init(Pbkdf2Parameters(salt, 260000, 32));
      final master = kd.process(Uint8List.fromList(utf8.encode('legacy-pass')));
      final iv = Uint8List.fromList(List<int>.generate(12, (i) => 31 - i));
      final cipher = GCMBlockCipher(AESEngine())
        ..init(
          true,
          AEADParameters(KeyParameter(master), 128, iv, Uint8List(0)),
        );
      final encrypted = BytesBuilder()
        ..add(iv)
        ..add(cipher.process(pkcs8));

      final recovered = await crypto.importServerPriv(
        base64Encode(encrypted.toBytes()),
        base64Encode(salt),
        'legacy-pass',
        account: 'alice',
      );
      expect(recovered, equals(pub));
    },
  );
}

Uint8List _legacyPkcs8(Uint8List d32, Uint8List pubRaw65) {
  return (BytesBuilder()
        ..add(<int>[
          0x30,
          0x81,
          0x87,
          0x02,
          0x01,
          0x00,
          0x30,
          0x13,
          0x06,
          0x07,
          0x2A,
          0x86,
          0x48,
          0xCE,
          0x3D,
          0x02,
          0x01,
          0x06,
          0x08,
          0x2A,
          0x86,
          0x48,
          0xCE,
          0x3D,
          0x03,
          0x01,
          0x07,
          0x04,
          0x6D,
          0x30,
          0x6B,
          0x02,
          0x01,
          0x01,
          0x04,
          0x20,
        ])
        ..add(d32)
        ..add(<int>[0xA1, 0x44, 0x03, 0x42, 0x00])
        ..add(pubRaw65))
      .toBytes();
}
