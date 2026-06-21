// Тест что pointycastle-крипта работает encrypt-then-decrypt roundtrip
// + verify что raw 65-byte ↔ ECPublicKey конвертация симметрична.
//
// Запуск: `flutter test test/crypto_test.dart`
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/export.dart';

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
  hkdf.init(HkdfParameters(sharedBytes, 32, Uint8List(32), utf8.encode('ghostchat-msg-v1')));
  final out = Uint8List(32);
  hkdf.deriveKey(null, 0, out, 0);
  return out;
}

String _encrypt(Uint8List aesKey, Uint8List iv, String text) {
  final cipher = GCMBlockCipher(AESEngine())
    ..init(true, AEADParameters(KeyParameter(aesKey), 128, iv, Uint8List(0)));
  final out = cipher.process(Uint8List.fromList(utf8.encode(text)));
  final env = BytesBuilder()..add(iv)..add(out);
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
  test('ECDH P-256 roundtrip', () {
    final alice = _gen();
    final bob = _gen();
    final alicePub = _pubToRaw(alice.publicKey as ECPublicKey);
    final bobPub = _pubToRaw(bob.publicKey as ECPublicKey);
    final aliceD = (alice.privateKey as ECPrivateKey).d!;
    final bobD = (bob.privateKey as ECPrivateKey).d!;

    final aliceKey = _deriveKey(aliceD, bobPub);
    final bobKey = _deriveKey(bobD, alicePub);
    expect(aliceKey, equals(bobKey),
        reason: 'ECDH shared key should be the same on both sides');
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
    final key = _deriveKey(d, pub);  // self-encrypt for size check
    final iv = Uint8List(12);
    final env = base64Decode(_encrypt(key, iv, 'x'));
    expect(env.length, equals(12 + 1 + 16),
        reason: 'iv(12) + ct(1 байт plaintext "x") + GCM tag(16)');
  });
}
