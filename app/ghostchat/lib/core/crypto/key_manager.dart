/// Менеджер криптографических идентичностей устройства.
///
/// На регистрации генерируем две пары ключей:
///   • X25519  — обмен ключами (ECDH) для шифрования сообщений
///   • Ed25519 — цифровые подписи (аутентичность)
/// Приватные части (seed, 32 байта) хранятся ТОЛЬКО в SecureStore.
/// Публичные части (base64) уходят на сервер при /api/register.
library;

import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:uuid/uuid.dart';

import '../storage/secure_store.dart';

/// Публичные ключи идентичности (для отправки на сервер).
class IdentityPublicKeys {
  final String x25519PubB64;
  final String ed25519PubB64;
  const IdentityPublicKeys(this.x25519PubB64, this.ed25519PubB64);
}

class KeyManager {
  KeyManager._();
  static final KeyManager I = KeyManager._();

  static final _x25519 = X25519();
  static final _ed25519 = Ed25519();
  final _store = SecureStore.I;

  // ── Device ID ─────────────────────────────────────────────────────────────
  /// Возвращает постоянный device_id, создавая его при первом запуске.
  Future<String> ensureDeviceId() async {
    final existing = await _store.deviceId;
    if (existing != null && existing.isNotEmpty) return existing;
    final id = const Uuid().v4();
    await _store.setDeviceId(id);
    return id;
  }

  // ── Наличие идентичности ─────────────────────────────────────────────────────
  Future<bool> hasIdentity() async {
    final x = await _store.x25519Seed;
    final e = await _store.ed25519Seed;
    return (x != null && x.isNotEmpty) && (e != null && e.isNotEmpty);
  }

  /// Генерирует и сохраняет пары ключей. Возвращает публичные ключи (base64).
  /// Если идентичность уже есть — возвращает существующие публичные ключи.
  Future<IdentityPublicKeys> ensureIdentity() async {
    if (await hasIdentity()) {
      return IdentityPublicKeys(
        await x25519PublicB64(),
        await ed25519PublicB64(),
      );
    }

    // X25519
    final xKp = await _x25519.newKeyPair();
    final xSeed = await xKp.extractPrivateKeyBytes();
    final xPub = (await xKp.extractPublicKey()).bytes;

    // Ed25519
    final eKp = await _ed25519.newKeyPair();
    final eSeed = await eKp.extractPrivateKeyBytes();
    final ePub = (await eKp.extractPublicKey()).bytes;

    await _store.setX25519Seed(base64Encode(xSeed));
    await _store.setEd25519Seed(base64Encode(eSeed));

    return IdentityPublicKeys(base64Encode(xPub), base64Encode(ePub));
  }

  // ── Загрузка пар ключей для крипто-операций ──────────────────────────────────
  Future<SimpleKeyPair> x25519KeyPair() async {
    final seedB64 = await _store.x25519Seed;
    if (seedB64 == null) throw StateError('Нет X25519 ключа');
    return _x25519.newKeyPairFromSeed(base64Decode(seedB64));
  }

  Future<SimpleKeyPair> ed25519KeyPair() async {
    final seedB64 = await _store.ed25519Seed;
    if (seedB64 == null) throw StateError('Нет Ed25519 ключа');
    return _ed25519.newKeyPairFromSeed(base64Decode(seedB64));
  }

  Future<String> x25519PublicB64() async {
    final pub = await (await x25519KeyPair()).extractPublicKey();
    return base64Encode(pub.bytes);
  }

  Future<String> ed25519PublicB64() async {
    final pub = await (await ed25519KeyPair()).extractPublicKey();
    return base64Encode(pub.bytes);
  }

  // ── Подпись (Ed25519) ─────────────────────────────────────────────────────
  Future<String> sign(List<int> data) async {
    final kp = await ed25519KeyPair();
    final sig = await _ed25519.sign(data, keyPair: kp);
    return base64Encode(sig.bytes);
  }

  Future<bool> verify(
    List<int> data,
    String signatureB64,
    String ed25519PubB64,
  ) async {
    final pub = SimplePublicKey(
      base64Decode(ed25519PubB64),
      type: KeyPairType.ed25519,
    );
    final sig = Signature(base64Decode(signatureB64), publicKey: pub);
    return _ed25519.verify(data, signature: sig);
  }
}
