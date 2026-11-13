/// Проверка подписи манифеста GhostGallery.
///
/// Сервер подписывает канонический JSON (sorted keys, compact separators)
/// схемой RSASSA-PSS SHA-256, salt = 32 байта. Здесь — проверка по публичному
/// ключу из `assets/keys/gallery_pub.pem` и контроль SHA-256 файла.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:asn1lib/asn1lib.dart';
import 'package:pointycastle/digests/sha256.dart';

class GallerySignature {
  GallerySignature._();

  static const int _hashLength = 32;
  static const int _saltLength = 32;

  /// Каноническая форма манифеста: те же байты, что подписал Python
  /// (`json.dumps(..., sort_keys=True, separators=(",", ":"), ensure_ascii=False)`).
  static Uint8List canonicalManifest(Map<String, dynamic> manifest) {
    final sorted = <String, dynamic>{
      for (final key in manifest.keys.toList()..sort()) key: manifest[key],
    };
    return Uint8List.fromList(utf8.encode(jsonEncode(sorted)));
  }

  static bool verifyManifest({
    required Map<String, dynamic> manifest,
    required String signatureBase64,
    required String publicKeyPem,
  }) {
    try {
      final key = _parsePublicKey(publicKeyPem);
      final signature = base64Decode(signatureBase64);
      final message = canonicalManifest(manifest);
      return _verifyPss(key, message, signature);
    } catch (_) {
      return false;
    }
  }

  static String sha256Hex(List<int> bytes) {
    final data = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
    return _toHex(_sha256(data));
  }

  static bool _verifyPss(
    _RsaPublicKey key,
    Uint8List message,
    Uint8List signature,
  ) {
    final modulus = key.modulus;
    if (modulus <= BigInt.zero) return false;
    final k = (modulus.bitLength + 7) >> 3;
    if (signature.length > k) return false;

    final s = _bytesToBigInt(signature);
    if (s >= modulus) return false;

    final em = _bigIntToBytes(s.modPow(key.exponent, modulus), k);
    return _emsaPssVerify(message, em, modulus.bitLength - 1);
  }

  static bool _emsaPssVerify(Uint8List message, Uint8List em, int emBits) {
    final emLen = em.length;
    final hLen = _hashLength;
    final sLen = _saltLength;
    if (emLen < hLen + sLen + 2) return false;
    if (em[emLen - 1] != 0xbc) return false;

    final dbLen = emLen - hLen - 1;
    final maskedDb = Uint8List.fromList(em.sublist(0, dbLen));
    final h = Uint8List.fromList(em.sublist(dbLen, dbLen + hLen));

    final topBits = 8 * emLen - emBits;
    if (topBits < 0 || topBits > 7) return false;
    if (topBits > 0 && (maskedDb[0] >> (8 - topBits)) != 0) return false;

    final dbMask = _mgf1(h, dbLen);
    final db = Uint8List(dbLen);
    for (var i = 0; i < dbLen; i++) {
      db[i] = maskedDb[i] ^ dbMask[i];
    }
    if (topBits > 0) {
      db[0] &= 0xff >> topBits;
    }

    final psLen = emLen - hLen - sLen - 2;
    for (var i = 0; i < psLen; i++) {
      if (db[i] != 0) return false;
    }
    if (db[psLen] != 0x01) return false;

    final salt = Uint8List.fromList(db.sublist(psLen + 1));
    final mHash = _sha256(message);
    final mPrime = Uint8List(8 + hLen + sLen);
    mPrime.setRange(8, 8 + hLen, mHash);
    mPrime.setRange(8 + hLen, 8 + hLen + sLen, salt);
    final hPrime = _sha256(mPrime);

    return _constantTimeEquals(h, hPrime);
  }

  static Uint8List _mgf1(Uint8List seed, int length) {
    final out = Uint8List(length);
    var offset = 0;
    var counter = 0;
    while (offset < length) {
      final block = Uint8List(seed.length + 4)
        ..setRange(0, seed.length, seed);
      block[seed.length] = (counter >> 24) & 0xff;
      block[seed.length + 1] = (counter >> 16) & 0xff;
      block[seed.length + 2] = (counter >> 8) & 0xff;
      block[seed.length + 3] = counter & 0xff;
      final digest = _sha256(block);
      final take = (length - offset).clamp(0, digest.length);
      out.setRange(offset, offset + take, digest.sublist(0, take));
      offset += take;
      counter++;
    }
    return out;
  }

  static Uint8List _sha256(Uint8List data) {
    final digest = SHA256Digest();
    final out = Uint8List(digest.digestSize);
    digest.update(data, 0, data.length);
    digest.doFinal(out, 0);
    return out;
  }

  static _RsaPublicKey _parsePublicKey(String pem) {
    final body = pem
        .replaceAll(RegExp(r'-----BEGIN [^-]+-----'), '')
        .replaceAll(RegExp(r'-----END [^-]+-----'), '')
        .replaceAll(RegExp(r'\s+'), '');
    if (body.isEmpty) throw const FormatException('Пустой публичный ключ');

    final outer = ASN1Parser(base64Decode(body)).nextObject();
    if (outer is! ASN1Sequence) {
      throw const FormatException('Ожидался ASN.1 SEQUENCE');
    }

    ASN1Sequence rsa = outer;
    if (outer.elements.length == 2 && outer.elements[1] is ASN1BitString) {
      final inner = ASN1Parser(
        Uint8List.fromList(
          (outer.elements[1] as ASN1BitString).stringValue,
        ),
      ).nextObject();
      if (inner is! ASN1Sequence) {
        throw const FormatException('Ожидался RSA PUBLIC KEY');
      }
      rsa = inner;
    }

    if (rsa.elements.length < 2) {
      throw const FormatException('RSA-ключ без модуля/экспоненты');
    }
    final modulus = rsa.elements[0];
    final exponent = rsa.elements[1];
    if (modulus is! ASN1Integer || exponent is! ASN1Integer) {
      throw const FormatException('Некорректный RSA-ключ');
    }
    return _RsaPublicKey(
      modulus.valueAsBigInteger,
      exponent.valueAsBigInteger,
    );
  }

  static BigInt _bytesToBigInt(Uint8List bytes) {
    var result = BigInt.zero;
    for (final byte in bytes) {
      result = (result << 8) | BigInt.from(byte);
    }
    return result;
  }

  static Uint8List _bigIntToBytes(BigInt value, int length) {
    final out = Uint8List(length);
    var rest = value;
    final mask = BigInt.from(0xff);
    for (var i = length - 1; i >= 0; i--) {
      out[i] = (rest & mask).toInt();
      rest >>= 8;
    }
    return out;
  }

  static bool _constantTimeEquals(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }

  static String _toHex(Uint8List bytes) {
    final buffer = StringBuffer();
    for (final byte in bytes) {
      buffer.write(byte.toRadixString(16).padLeft(2, '0'));
    }
    return buffer.toString();
  }
}

class _RsaPublicKey {
  const _RsaPublicKey(this.modulus, this.exponent);

  final BigInt modulus;
  final BigInt exponent;
}
