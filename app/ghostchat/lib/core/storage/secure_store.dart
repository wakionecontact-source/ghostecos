/// Безопасное хранилище секретов.
///
/// Приватные ключи (X25519/Ed25519 seed), JWT-токен и device_id хранятся
/// ТОЛЬКО здесь (Android Keystore через flutter_secure_storage), НИКОГДА в
/// SharedPreferences/файлах в открытом виде.
library;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class SecureStore {
  SecureStore._();
  static final SecureStore I = SecureStore._();

  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
  );

  // Ключи хранилища
  static const _kToken = 'gc_token';
  static const _kUsername = 'gc_username';
  static const _kDeviceId = 'gc_device_id';
  static const _kX25519Seed = 'gc_x25519_seed'; // base64, 32 байта
  static const _kEd25519Seed = 'gc_ed25519_seed'; // base64, 32 байта
  static const _kIsPremium = 'gc_is_premium';

  Future<String?> read(String key) => _storage.read(key: key);
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);
  Future<void> delete(String key) => _storage.delete(key: key);

  // ── Токен ───────────────────────────────────────────────────────────────────
  Future<String?> get token => _storage.read(key: _kToken);
  Future<void> setToken(String v) => _storage.write(key: _kToken, value: v);

  // ── Username ──────────────────────────────────────────────────────────────
  Future<String?> get username => _storage.read(key: _kUsername);
  Future<void> setUsername(String v) =>
      _storage.write(key: _kUsername, value: v);

  // ── Device ID ─────────────────────────────────────────────────────────────
  Future<String?> get deviceId => _storage.read(key: _kDeviceId);
  Future<void> setDeviceId(String v) =>
      _storage.write(key: _kDeviceId, value: v);

  // ── Крипто-ключи (seeds) ────────────────────────────────────────────────────
  Future<String?> get x25519Seed => _storage.read(key: _kX25519Seed);
  Future<void> setX25519Seed(String v) =>
      _storage.write(key: _kX25519Seed, value: v);

  Future<String?> get ed25519Seed => _storage.read(key: _kEd25519Seed);
  Future<void> setEd25519Seed(String v) =>
      _storage.write(key: _kEd25519Seed, value: v);

  // ── Premium флаг ─────────────────────────────────────────────────────────────
  Future<bool> get isPremium async =>
      (await _storage.read(key: _kIsPremium)) == '1';
  Future<void> setPremium(bool v) =>
      _storage.write(key: _kIsPremium, value: v ? '1' : '0');

  // ── Panic / logout: стираем ВСЁ ──────────────────────────────────────────────
  Future<void> wipeAll() => _storage.deleteAll();

  /// Logout: убираем токен, но ключи/устройство можно оставить (по желанию).
  Future<void> clearSession() async {
    await _storage.delete(key: _kToken);
  }
}
