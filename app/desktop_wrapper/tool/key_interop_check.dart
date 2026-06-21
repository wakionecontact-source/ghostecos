// Автономная проверка крипто-совместимости server-режима с веб-GhostChat.
// Чистый Dart + pointycastle (без Flutter/SecureStorage), чтобы гонять через
// `dart run tool/key_interop_check.dart` и кросс-сверять с Node WebCrypto.
//
// Спека веба (server-режим):
//   master = PBKDF2(password, salt16, iterations=260000, SHA-256) → 32 байта (AES-256)
//   encrypted_private_key = base64( iv(12) || AES-GCM(master, iv, PKCS8(priv)) )
//   key_salt = base64(salt16)
//   priv/pub — P-256 (secp256r1), pub raw = 65 байт (0x04||X||Y)
//
// Режимы запуска:
//   (нет арг)            — сгенерить пару, само-round-trip PKCS8, выдать JSON-фикстуру
//   parse <pkcs8_b64>    — распарсить чужой (WebCrypto) PKCS8 → вывести d(hex), pub(b64)
//   decrypt <enc> <salt> <password> — расшифровать чужой блоб → d(hex), pub(b64)

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:pointycastle/export.dart';

final ECDomainParameters _curve = ECDomainParameters('secp256r1');

// ── PKCS8 (P-256) фикс-шаблон до 32-байтного D ──
// SEQUENCE{ INT 0; SEQ{ OID ecPublicKey; OID prime256v1 }; OCTETSTRING{ ECPrivateKey } }
final List<int> _pkcs8Head = [
  0x30, 0x81, 0x87, 0x02, 0x01, 0x00, //
  0x30, 0x13, 0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01, //
  0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07, //
  0x04, 0x6D, 0x30, 0x6B, 0x02, 0x01, 0x01, //
  0x04, 0x20, // OCTET STRING(32) D далее
];
// [1] EXPLICIT BIT STRING(0x00 || pub65) — публичный ключ внутри ECPrivateKey
final List<int> _pkcs8PubTag = [0xA1, 0x44, 0x03, 0x42, 0x00];

Uint8List _dToPkcs8(Uint8List d32, Uint8List pubRaw65) {
  final b = BytesBuilder()
    ..add(_pkcs8Head)
    ..add(d32)
    ..add(_pkcs8PubTag)
    ..add(pubRaw65);
  return b.toBytes();
}

// Минимальный TLV-парсер: возвращает [tag, contentStart, contentLen, next].
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

// Извлечь сырой 32-байтный D из ЛЮБОГО валидного PKCS8 EC-приватника.
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
  // Нормализуем к 32 байтам (может прийти 33 с ведущим 0 или короче).
  if (d.length > 32) d = d.sublist(d.length - 32);
  if (d.length < 32) {
    final padded = Uint8List(32);
    padded.setRange(32 - d.length, 32, d);
    d = padded;
  }
  return Uint8List.fromList(d);
}

Uint8List _deriveMasterKey(String password, Uint8List salt) {
  final kd = PBKDF2KeyDerivator(HMac(SHA256Digest(), 64))
    ..init(Pbkdf2Parameters(salt, 260000, 32));
  return kd.process(Uint8List.fromList(utf8.encode(password)));
}

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

Uint8List _pubToRaw(ECPoint q) {
  final x = _encodeBigInt(q.x!.toBigInteger()!, 32);
  final y = _encodeBigInt(q.y!.toBigInteger()!, 32);
  final out = Uint8List(65)..[0] = 0x04;
  out.setRange(1, 33, x);
  out.setRange(33, 65, y);
  return out;
}

Uint8List _pubRawFromD(BigInt d) => _pubToRaw((_curve.G * d)!);

Uint8List _randomBytes(int n) {
  final r = Random.secure();
  return Uint8List.fromList(List<int>.generate(n, (_) => r.nextInt(256)));
}

AsymmetricKeyPair _genPair() {
  final gen = ECKeyGenerator();
  final rnd = FortunaRandom();
  final seed = _randomBytes(32);
  rnd.seed(KeyParameter(seed));
  gen.init(ParametersWithRandom(ECKeyGeneratorParameters(_curve), rnd));
  return gen.generateKeyPair();
}

String _encryptPriv(Uint8List pkcs8, String password, {Uint8List? saltIn, Uint8List? ivIn}) {
  final salt = saltIn ?? _randomBytes(16);
  final iv = ivIn ?? _randomBytes(12);
  final master = _deriveMasterKey(password, salt);
  final gcm = GCMBlockCipher(AESEngine())
    ..init(true, AEADParameters(KeyParameter(master), 128, iv, Uint8List(0)));
  final ct = gcm.process(pkcs8);
  final enc = BytesBuilder()..add(iv)..add(ct);
  return jsonEncode({'enc': base64Encode(enc.toBytes()), 'salt': base64Encode(salt)});
}

Uint8List _decryptPriv(String encB64, String saltB64, String password) {
  final enc = base64Decode(encB64);
  final salt = base64Decode(saltB64);
  final iv = Uint8List.fromList(enc.sublist(0, 12));
  final ct = Uint8List.fromList(enc.sublist(12));
  final master = _deriveMasterKey(password, Uint8List.fromList(salt));
  final gcm = GCMBlockCipher(AESEngine())
    ..init(false, AEADParameters(KeyParameter(master), 128, iv, Uint8List(0)));
  return gcm.process(ct);
}

String _hex(Uint8List b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

void main(List<String> args) {
  if (args.isNotEmpty && args[0] == 'parse') {
    final pkcs8 = base64Decode(args[1]);
    final d = _pkcs8ToD(Uint8List.fromList(pkcs8));
    print(jsonEncode({'d': _hex(d), 'pub': base64Encode(_pubRawFromD(_decodeBigInt(d)))}));
    return;
  }
  if (args.isNotEmpty && args[0] == 'decrypt') {
    final pkcs8 = _decryptPriv(args[1], args[2], args[3]);
    final d = _pkcs8ToD(pkcs8);
    print(jsonEncode({'d': _hex(d), 'pub': base64Encode(_pubRawFromD(_decodeBigInt(d)))}));
    return;
  }

  // Дефолт: сгенерить пару, проверить само-round-trip, выдать фикстуру.
  final pair = _genPair();
  final priv = pair.privateKey as ECPrivateKey;
  final pub = pair.publicKey as ECPublicKey;
  final d = _encodeBigInt(priv.d!, 32);
  final pubRaw = _pubToRaw(pub.Q!);
  final pkcs8 = _dToPkcs8(d, pubRaw);

  // Само-round-trip: PKCS8 → D → должно совпасть.
  final dBack = _pkcs8ToD(pkcs8);
  final ok = _hex(d) == _hex(dBack);

  // pub из D должен совпасть с pub из пары (проверка _pubRawFromD).
  final pubFromD = _pubRawFromD(priv.d!);
  final pubOk = base64Encode(pubRaw) == base64Encode(pubFromD);

  const pwd = 'TestPass123!';
  // Фиксируем salt/iv, чтобы Node мог детерминированно сверить (по желанию).
  final fixedSalt = Uint8List.fromList(List<int>.filled(16, 7));
  final fixedIv = Uint8List.fromList(List<int>.filled(12, 9));
  final blob = jsonDecode(_encryptPriv(pkcs8, pwd, saltIn: fixedSalt, ivIn: fixedIv));

  print(jsonEncode({
    'self_roundtrip_ok': ok,
    'pub_from_d_ok': pubOk,
    'd': _hex(d),
    'pub': base64Encode(pubRaw),
    'pkcs8': base64Encode(pkcs8),
    'password': pwd,
    'enc': blob['enc'],
    'salt': blob['salt'],
  }));
}
