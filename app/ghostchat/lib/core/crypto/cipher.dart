/// E2E-шифрование сообщений.
///
/// Схема:
///   1. ECDH (X25519): мой приватный + публичный собеседника → общий секрет.
///   2. HKDF-SHA256 → стабильный 256-битный ключ диалога.
///   3. AES-256-GCM: шифруем тело сообщения. Формат payload (base64):
///        nonce(12) | ciphertext | mac(16)   — через SecretBox.concatenation().
///
/// Сервер видит только зашифрованный `enc_body` и маршрутную информацию.
/// Содержимое расшифровать не может — приватные ключи только на устройствах.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'key_manager.dart';

class Cipher {
  Cipher._();
  static final Cipher I = Cipher._();

  static final _x25519 = X25519();
  static final _aes = AesGcm.with256bits();
  static final _hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);

  static const int _nonceLen = 12;
  static const int _macLen = 16;

  /// Выводит ключ диалога с собеседником (по его X25519 публичному ключу).
  Future<SecretKey> conversationKey(String peerX25519PubB64) async {
    final myKp = await KeyManager.I.x25519KeyPair();
    final peerPub = SimplePublicKey(
      base64Decode(peerX25519PubB64),
      type: KeyPairType.x25519,
    );
    final shared = await _x25519.sharedSecretKey(
      keyPair: myKp,
      remotePublicKey: peerPub,
    );
    // HKDF со статическим info-контекстом приложения.
    return _hkdf.deriveKey(
      secretKey: shared,
      nonce: const <int>[], // соль не обязательна для эфемерно-статической схемы
      info: utf8.encode('ghostchat-e2e-v1'),
    );
  }

  /// Шифрует строку. Возвращает base64(nonce|ciphertext|mac).
  Future<String> encrypt(String plaintext, SecretKey key) async {
    final nonce = _aes.newNonce(); // 12 случайных байт
    final box = await _aes.encrypt(
      utf8.encode(plaintext),
      secretKey: key,
      nonce: nonce,
    );
    return base64Encode(box.concatenation());
  }

  /// Расшифровывает base64(nonce|ciphertext|mac) обратно в строку.
  Future<String> decrypt(String payloadB64, SecretKey key) async {
    final bytes = base64Decode(payloadB64);
    final box = SecretBox.fromConcatenation(
      bytes,
      nonceLength: _nonceLen,
      macLength: _macLen,
    );
    final clear = await _aes.decrypt(box, secretKey: key);
    return utf8.decode(clear);
  }

  /// Утилита: случайные байты (например, для file enc-key).
  Future<Uint8List> randomBytes(int n) async {
    final algo = AesGcm.with256bits();
    final key = await algo.newSecretKey();
    final raw = await key.extractBytes();
    return Uint8List.fromList(raw.take(n).toList());
  }
}
