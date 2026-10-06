// GhostChat Keys v2 — клиентская крипта (Dart). Зеркало server/chat/keys_v2.js
// и ~/.claude_chat/claude_chat_v2.py. Кросс-протестировано: Ed25519 (RFC 8032)
// совпадает с python/nacl, X25519+HKDF+AES-GCM интероп подтверждён (python
// расшифровал Dart-envelope).
//
//   Identity : Ed25519 из BIP-39 seed (PBKDF2-SHA512 → HKDF → seed32).
//   Device   : X25519 (на каждое устройство свой).
//   Сообщение: эфемерная X25519-пара → ECDH(eph_priv, peer_dev_pub) →
//              HKDF-SHA256(salt=0, info='ghostchat-v2-msg') → AES-256-GCM.
//              envelope = eph_pub(32) || iv(12) || ct || tag(16), base64.
//
// Ключи лежат в flutter_secure_storage. seed-фраза = бэкап для восстановления.

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart' show compute, listEquals;
import '../core/local/app_logger.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'ghost_asset_ota.dart';

// ── Тяжёлая крипта (X25519 ECDH + HKDF + AES-256-GCM) в отдельном изоляте ──
// encryptV2/decryptForMe раньше делали это прямо на UI-изоляте — на каждое
// отправленное/полученное сообщение это блокировало кадры (см. Choreographer
// "Skipped N frames" при отправке LAN-сообщения). compute() гоняет чистую
// функцию в отдельном изоляте, поэтому она не может держать состояние
// CryptoV2 (там свой X25519()/приватные ключи) — все нужные данные передаются
// через аргумент-класс ниже, шифрование/расшифровка полностью самодостаточны.

class _EncryptArgs {
  final Uint8List recipientDevicePub;
  final Uint8List pt;
  const _EncryptArgs(this.recipientDevicePub, this.pt);
}

Future<String> _encryptV2Isolate(_EncryptArgs args) async {
  final x = X25519();
  final eph = await x.newKeyPair();
  final ephPub = await eph.extractPublicKey();
  final sh = await x.sharedSecretKey(
    keyPair: eph,
    remotePublicKey: SimplePublicKey(
      args.recipientDevicePub,
      type: KeyPairType.x25519,
    ),
  );
  final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
  final derived = await hkdf.deriveKey(
    secretKey: SecretKey(await sh.extractBytes()),
    nonce: Uint8List(32),
    info: utf8.encode('ghostchat-v2-msg'),
  );
  final aes = SecretKey(await derived.extractBytes());
  final gcm = AesGcm.with256bits();
  final iv = gcm.newNonce();
  final box = await gcm.encrypt(args.pt, secretKey: aes, nonce: iv);
  final out = BytesBuilder()
    ..add(ephPub.bytes)
    ..add(iv)
    ..add(box.cipherText)
    ..add(box.mac.bytes);
  return base64.encode(out.toBytes());
}

class _DecryptArgs {
  final Uint8List devPriv;
  final String envelopeB64;
  const _DecryptArgs(this.devPriv, this.envelopeB64);
}

/// Возвращает null на не-крипто ошибках (envelope слишком короткий); реальные
/// crypto-ошибки (bad tag и т.п.) пробрасываются как исключение, чтобы вызывающая
/// сторона (CryptoV2.decryptForMe) сама решала, логировать через appLog — сам
/// логгер недоступен из фонового изолята.
Future<Uint8List?> _decryptForMeIsolate(_DecryptArgs args) async {
  final raw = base64.decode(args.envelopeB64);
  if (raw.length < 32 + 12 + 16) return null;
  final ephPub = raw.sublist(0, 32);
  final iv = raw.sublist(32, 44);
  final ctTag = raw.sublist(44);
  final ct = ctTag.sublist(0, ctTag.length - 16);
  final tag = ctTag.sublist(ctTag.length - 16);
  final x = X25519();
  final kp = await x.newKeyPairFromSeed(args.devPriv);
  final sh = await x.sharedSecretKey(
    keyPair: kp,
    remotePublicKey: SimplePublicKey(
      Uint8List.fromList(ephPub),
      type: KeyPairType.x25519,
    ),
  );
  final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
  final derived = await hkdf.deriveKey(
    secretKey: SecretKey(await sh.extractBytes()),
    nonce: Uint8List(32),
    info: utf8.encode('ghostchat-v2-msg'),
  );
  final aes = SecretKey(await derived.extractBytes());
  final gcm = AesGcm.with256bits();
  final clear = await gcm.decrypt(
    SecretBox(ct, nonce: iv, mac: Mac(tag)),
    secretKey: aes,
  );
  return Uint8List.fromList(clear);
}

class CryptoV2 {
  CryptoV2._();
  static final CryptoV2 instance = CryptoV2._();

  final _ed = Ed25519();
  final _x = X25519();
  final _ss = const FlutterSecureStorage();

  // v3 namespace deliberately ignores both the old global keys and the first
  // account-scoped migration from v1. That migration had no way to know which
  // account owned the old global identity and could therefore preserve the
  // wrong account identity.
  static const _kSeed = 'v2_identity_seed32_v3';
  static const _kIdPub = 'v2_identity_pub_v3';
  static const _kDevPriv = 'v2_device_priv_v3';
  static const _kDevPub = 'v2_device_pub_v3';
  static const _kMnemonic = 'v2_mnemonic_v3';
  // The pre-account-scoped names used by 1.1.24 and earlier. They are kept
  // only as a migration source; ownership is accepted only when the server's
  // identity_pub matches the old identity key byte-for-byte.
  static const _legacyKSeed = 'v2_identity_seed32';
  static const _legacyKIdPub = 'v2_identity_pub';
  static const _legacyKDevPriv = 'v2_device_priv';
  static const _legacyKDevPub = 'v2_device_pub';
  static const _legacyKMnemonic = 'v2_mnemonic';
  // Compatible with the web client's identity recovery container:
  // PBKDF2-HMAC-SHA256(260000) -> AES-256-GCM, blob = iv(12) || ciphertext || tag.
  static const identityServerKdf = 'pbkdf2-sha256-v1-i260000';

  List<String>? _wl;
  Uint8List? _seed32, _idPub, _devPriv, _devPub;
  String? _loadedAccount;

  bool get ready => _seed32 != null && _devPriv != null;
  Uint8List get identityPub => _idPub!;
  Uint8List get devicePub => _devPub!;
  String get identityPubB64 => base64.encode(_idPub!);
  String get devicePubB64 => base64.encode(_devPub!);
  Future<String?> get mnemonic {
    final account = _loadedAccount;
    if (account == null) return Future<String?>.value(null);
    return _ss.read(key: _scopedKey(_kMnemonic, account));
  }

  String _normalizeAccount(String account) => account.trim().toLowerCase();

  String _scopedKey(String key, String account) {
    final encoded = base64Url
        .encode(utf8.encode(_normalizeAccount(account)))
        .replaceAll('=', '');
    return '${key}_$encoded';
  }

  void _setMemory({
    required String account,
    required String seedB64,
    required String idPubB64,
    required String devPrivB64,
    required String devPubB64,
  }) {
    _seed32 = base64.decode(seedB64);
    _idPub = base64.decode(idPubB64);
    _devPriv = base64.decode(devPrivB64);
    _devPub = base64.decode(devPubB64);
    _loadedAccount = account;
  }

  Future<void> _writeScopedBundle({
    required String account,
    required String seedB64,
    required String idPubB64,
    required String devPrivB64,
    required String devPubB64,
    required String mnemonic,
  }) async {
    await _ss.write(key: _scopedKey(_kSeed, account), value: seedB64);
    await _ss.write(key: _scopedKey(_kIdPub, account), value: idPubB64);
    await _ss.write(key: _scopedKey(_kDevPriv, account), value: devPrivB64);
    await _ss.write(key: _scopedKey(_kDevPub, account), value: devPubB64);
    await _ss.write(key: _scopedKey(_kMnemonic, account), value: mnemonic);
  }

  /// Migrate the old global v2 identity/device bundle after the server has
  /// authenticated which identity belongs to this account. Without this
  /// check, a second account could inherit the first account's keys.
  Future<bool> adoptLegacyKeysIfMatching({
    required String account,
    required String expectedIdentityB64,
  }) async {
    final normalized = _normalizeAccount(account);
    final seedB64 = await _ss.read(key: _legacyKSeed);
    final idPubB64 = await _ss.read(key: _legacyKIdPub);
    final devPrivB64 = await _ss.read(key: _legacyKDevPriv);
    final devPubB64 = await _ss.read(key: _legacyKDevPub);
    final mnemonic = await _ss.read(key: _legacyKMnemonic);
    if ([
      seedB64,
      idPubB64,
      devPrivB64,
      devPubB64,
      mnemonic,
    ].any((value) => value == null || value.isEmpty)) {
      return false;
    }
    try {
      final identity = base64.decode(idPubB64!);
      final expected = base64.decode(expectedIdentityB64);
      final seed = base64.decode(seedB64!);
      final devPriv = base64.decode(devPrivB64!);
      final devPub = base64.decode(devPubB64!);
      if (identity.length != 32 ||
          expected.length != 32 ||
          seed.length != 32 ||
          devPriv.length != 32 ||
          devPub.length != 32 ||
          !listEquals(identity, expected)) {
        return false;
      }
      final identityOut = base64.encode(identity);
      final seedOut = base64.encode(seed);
      final devPrivOut = base64.encode(devPriv);
      final devPubOut = base64.encode(devPub);
      _setMemory(
        account: normalized,
        seedB64: seedOut,
        idPubB64: identityOut,
        devPrivB64: devPrivOut,
        devPubB64: devPubOut,
      );
      await _writeScopedBundle(
        account: normalized,
        seedB64: seedOut,
        idPubB64: identityOut,
        devPrivB64: devPrivOut,
        devPubB64: devPubOut,
        mnemonic: mnemonic!,
      );
      appLog.info('crypto', 'legacy v2 identity adopted for matching account');
      return true;
    } catch (e) {
      appLog.warn('crypto', 'legacy v2 identity migration skipped: $e');
      return false;
    }
  }

  // ── BIP-39 wordlist ─────────────────────────────────────────────
  Future<List<String>> _words() async {
    if (_wl != null) return _wl!;
    final bytes = await GhostAssetOta.instance.loadAssetData(
      'assets/bip39_en.txt',
    );
    final raw = String.fromCharCodes(
      bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
    );
    _wl = raw
        .split('\n')
        .map((w) => w.trim())
        .where((w) => w.isNotEmpty)
        .toList();
    if (_wl!.length != 2048) {
      throw StateError('BIP-39 wordlist: 2048 ожидалось, ${_wl!.length}');
    }
    return _wl!;
  }

  Future<String> generateMnemonic() async {
    final words = await _words();
    final entropy = _randomBytes(16);
    final hash = (await Sha256().hash(entropy)).bytes;
    final checksum = hash[0] >> 4;
    final bits =
        _bitsFromBytes(entropy) + checksum.toRadixString(2).padLeft(4, '0');
    final out = <String>[];
    for (var i = 0; i < 12; i++) {
      final idx = int.parse(bits.substring(i * 11, (i + 1) * 11), radix: 2);
      out.add(words[idx]);
    }
    return out.join(' ');
  }

  Future<bool> validateMnemonic(String mnemonic) async {
    final words = await _words();
    final parts = mnemonic.trim().toLowerCase().split(RegExp(r'\s+'));
    if (parts.length != 12) return false;
    var bits = '';
    for (final w in parts) {
      final idx = words.indexOf(w);
      if (idx < 0) return false;
      bits += idx.toRadixString(2).padLeft(11, '0');
    }
    final entropy = Uint8List(16);
    for (var i = 0; i < 16; i++) {
      entropy[i] = int.parse(bits.substring(i * 8, (i + 1) * 8), radix: 2);
    }
    final cs = int.parse(bits.substring(128, 132), radix: 2);
    final hash = (await Sha256().hash(entropy)).bytes;
    return (hash[0] >> 4) == cs;
  }

  // ── Identity / device derivation ────────────────────────────────
  Future<Uint8List> _mnemonicToSeed(String mnemonic) async {
    final p = Pbkdf2(macAlgorithm: Hmac.sha512(), iterations: 2048, bits: 512);
    final k = await p.deriveKey(
      secretKey: SecretKey(utf8.encode(mnemonic.trim().toLowerCase())),
      nonce: utf8.encode('mnemonicghostchat-v2'),
    );
    return Uint8List.fromList(await k.extractBytes());
  }

  Future<Uint8List> _hkdf(List<int> ikm, String info) async {
    final h = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
    final k = await h.deriveKey(
      secretKey: SecretKey(ikm),
      nonce: Uint8List(32),
      info: utf8.encode(info),
    );
    return Uint8List.fromList(await k.extractBytes());
  }

  Future<Uint8List> signWithIdentity(List<int> msg) async {
    final kp = await _ed.newKeyPairFromSeed(_seed32!);
    final sig = await _ed.sign(msg, keyPair: kp);
    return Uint8List.fromList(sig.bytes);
  }

  // ── Сообщения ───────────────────────────────────────────────────
  // Тяжёлая часть (ECDH+HKDF+AES-GCM) уходит в фоновый изолят через compute()
  // — не блокирует UI-поток на отправке/приёме (см. _encryptV2Isolate выше).
  Future<String> encryptV2(Uint8List recipientDevicePub, List<int> pt) {
    return compute(
      _encryptV2Isolate,
      _EncryptArgs(recipientDevicePub, Uint8List.fromList(pt)),
    );
  }

  Future<Uint8List?> decryptForMe(String envelopeB64) async {
    if (_devPriv == null) return null;
    try {
      return await compute(
        _decryptForMeIsolate,
        _DecryptArgs(_devPriv!, envelopeB64),
      );
    } catch (e) {
      appLog.warn('crypto', 'decrypt failed: $e');
      return null;
    }
  }

  /// Encrypt an attachment before it leaves the device. The returned key and
  /// IV are meant to travel only inside the room message envelope.
  Future<Map<String, dynamic>> encryptAttachment(Uint8List plain) async {
    final aes = AesGcm.with256bits();
    final key = _randomBytes(32);
    final iv = aes.newNonce();
    final box = await aes.encrypt(plain, secretKey: SecretKey(key), nonce: iv);
    return {
      'blob': Uint8List.fromList([...box.cipherText, ...box.mac.bytes]),
      'key': base64.encode(key),
      'iv': base64.encode(iv),
    };
  }

  Future<Uint8List> decryptAttachment({
    required Uint8List blob,
    required String key,
    required String iv,
  }) async {
    final raw = base64.decode(key);
    final nonce = base64.decode(iv);
    if (raw.length != 32 || nonce.length != 12 || blob.length < 16) {
      throw const FormatException('Invalid room attachment key');
    }
    final tagStart = blob.length - 16;
    final aes = AesGcm.with256bits();
    final clear = await aes.decrypt(
      SecretBox(
        blob.sublist(0, tagStart),
        nonce: nonce,
        mac: Mac(blob.sublist(tagStart)),
      ),
      secretKey: SecretKey(raw),
    );
    return Uint8List.fromList(clear);
  }

  Future<Uint8List> proofSignature() =>
      signWithIdentity(utf8.encode('ghostchat-v2-identity-claim'));
  Future<Uint8List> signedPrekeySig() => signWithIdentity(_devPub!);

  /// SECURITY: проверить, что signed_prekey_sig — подпись identity над
  /// device_pub. Защита от подмены device_pub злым сервером (MITM). Зеркало
  /// web `nacl.sign.detached.verify(device_pub, sig, identity_pub)`.
  Future<bool> verifySignedPrekey({
    required Uint8List identityPub,
    required Uint8List devicePub,
    required Uint8List signature,
  }) async {
    try {
      final sig = Signature(
        signature,
        publicKey: SimplePublicKey(identityPub, type: KeyPairType.ed25519),
      );
      return await _ed.verify(devicePub, signature: sig);
    } catch (e) {
      appLog.warn('crypto', 'signed_prekey signature verify threw: $e');
      return false;
    }
  }

  Future<SecretKey> _deriveIdentityServerKey(
    String password,
    List<int> salt,
  ) async {
    if (password.isEmpty) throw ArgumentError('password must not be empty');
    final kdf = Pbkdf2(
      macAlgorithm: Hmac.sha256(),
      iterations: 260000,
      bits: 256,
    );
    return kdf.deriveKey(
      secretKey: SecretKey(utf8.encode(password)),
      nonce: salt,
    );
  }

  /// Export the Ed25519 secret key in the same 64-byte NaCl format used by
  /// the web client. The server only stores this encrypted blob; it never
  /// receives the seed or the password.
  Future<Map<String, String>> exportEncryptedIdentityForServer(
    String password,
  ) async {
    if (password.isEmpty) throw ArgumentError('password must not be empty');
    final account = _loadedAccount;
    if (account == null || !ready) {
      throw StateError('CryptoV2 identity is not ready');
    }
    final secret = Uint8List.fromList(<int>[..._seed32!, ..._idPub!]);
    final salt = _randomBytes(16);
    final key = await _deriveIdentityServerKey(password, salt);
    final aes = AesGcm.with256bits();
    final iv = aes.newNonce();
    final box = await aes.encrypt(secret, secretKey: key, nonce: iv);
    final blob = Uint8List.fromList(<int>[
      ...iv,
      ...box.cipherText,
      ...box.mac.bytes,
    ]);
    return {
      'identity_priv_encrypted': base64.encode(blob),
      'identity_salt': base64.encode(salt),
      'identity_kdf': identityServerKdf,
    };
  }

  /// Restore the identity seed from the server copy while retaining the
  /// newly generated device key of this installation.
  Future<void> importEncryptedIdentityFromServer({
    required String encryptedB64,
    required String saltB64,
    required String password,
    required String account,
  }) async {
    final normalized = _normalizeAccount(account);
    if (normalized.isEmpty) throw StateError('CryptoV2 account is not set');
    if (password.isEmpty) throw ArgumentError('password must not be empty');
    if (_loadedAccount != normalized || !ready) {
      await ensureKeys(account: normalized);
    }

    final blob = base64.decode(encryptedB64);
    final salt = base64.decode(saltB64);
    if (blob.length < 12 + 16 || salt.length != 16) {
      throw const FormatException('Invalid encrypted v2 identity container');
    }
    final key = await _deriveIdentityServerKey(password, salt);
    final aes = AesGcm.with256bits();
    final iv = Uint8List.fromList(blob.sublist(0, 12));
    final tagStart = blob.length - 16;
    final clear = await aes.decrypt(
      SecretBox(
        blob.sublist(12, tagStart),
        nonce: iv,
        mac: Mac(blob.sublist(tagStart)),
      ),
      secretKey: key,
    );
    if (clear.length != 64) {
      throw const FormatException('Invalid v2 identity private key length');
    }

    final seed = Uint8List.fromList(clear.sublist(0, 32));
    final expectedPub = Uint8List.fromList(clear.sublist(32, 64));
    final pair = await _ed.newKeyPairFromSeed(seed);
    final derivedPub = Uint8List.fromList(
      (await pair.extractPublicKey()).bytes,
    );
    if (!listEquals(expectedPub, derivedPub)) {
      throw const FormatException('v2 identity public key does not match seed');
    }

    // Keep the local device private/public pair. It is intentionally unique
    // to this installation and will be signed by the restored identity.
    _seed32 = seed;
    _idPub = expectedPub;
    _loadedAccount = normalized;
    await _ss.write(
      key: _scopedKey(_kSeed, normalized),
      value: base64.encode(seed),
    );
    await _ss.write(
      key: _scopedKey(_kIdPub, normalized),
      value: base64.encode(expectedPub),
    );
    // A mnemonic generated before recovery no longer describes this seed.
    await _ss.delete(key: _scopedKey(_kMnemonic, normalized));
  }

  Future<bool> verifyIdentitySignature({
    required Uint8List identityPub,
    required Uint8List signature,
    required List<int> message,
  }) async {
    if (identityPub.length != 32 || signature.length != 64) return false;
    try {
      final signed = Signature(
        signature,
        publicKey: SimplePublicKey(identityPub, type: KeyPairType.ed25519),
      );
      return await _ed.verify(message, signature: signed);
    } catch (e) {
      appLog.warn('security', 'identity signature verify threw: $e');
      return false;
    }
  }

  // ── Жизненный цикл ключей ───────────────────────────────────────
  /// Загрузить v2-ключи текущего аккаунта; при первом запуске аккаунта —
  /// сгенерировать (mnemonic + identity + device) и сохранить. Публикация на
  /// сервер — отдельно (в репо). Ключи account-scoped: secure storage общий
  /// для приложения, поэтому глобальные имена смешивали аккаунты после
  /// logout/login.
  Future<void> ensureKeys({String? account}) async {
    final requested = account?.trim();
    final normalized = _normalizeAccount(
      requested?.isNotEmpty == true ? requested! : (_loadedAccount ?? ''),
    );
    if (normalized.isEmpty) {
      throw StateError('CryptoV2 account is not set');
    }
    if (_loadedAccount == normalized && ready) return;

    _seed32 = null;
    _idPub = null;
    _devPriv = null;
    _devPub = null;

    final seedB64 = await _ss.read(key: _scopedKey(_kSeed, normalized));
    final idPubB64 = await _ss.read(key: _scopedKey(_kIdPub, normalized));
    final devPrivB64 = await _ss.read(key: _scopedKey(_kDevPriv, normalized));
    final devPubB64 = await _ss.read(key: _scopedKey(_kDevPub, normalized));
    if (seedB64 != null &&
        idPubB64 != null &&
        devPrivB64 != null &&
        devPubB64 != null) {
      _setMemory(
        account: normalized,
        seedB64: seedB64,
        idPubB64: idPubB64,
        devPrivB64: devPrivB64,
        devPubB64: devPubB64,
      );
      return;
    }

    final mnemonic = await generateMnemonic();
    final seed64 = await _mnemonicToSeed(mnemonic);
    final seed32 = await _hkdf(seed64, 'ghostchat-v2-identity');
    final idKp = await _ed.newKeyPairFromSeed(seed32);
    final idPub = await idKp.extractPublicKey();
    final devKp = await _x.newKeyPair();
    final devPub = await devKp.extractPublicKey();
    final devPriv = await devKp.extractPrivateKeyBytes();
    _seed32 = seed32;
    _idPub = Uint8List.fromList(idPub.bytes);
    _devPriv = Uint8List.fromList(devPriv);
    _devPub = Uint8List.fromList(devPub.bytes);
    _loadedAccount = normalized;
    await _writeScopedBundle(
      account: normalized,
      seedB64: base64.encode(_seed32!),
      idPubB64: base64.encode(_idPub!),
      devPrivB64: base64.encode(_devPriv!),
      devPubB64: base64.encode(_devPub!),
      mnemonic: mnemonic,
    );
  }

  /// Удалить только account-scoped V2 bundle перед явной ротацией ключей.
  /// Старые V1-ключи и bundle других аккаунтов не затрагиваются.
  Future<void> regenerateKeys({required String account}) async {
    final normalized = _normalizeAccount(account);
    if (normalized.isEmpty) {
      throw StateError('CryptoV2 account is not set');
    }
    if (_loadedAccount == normalized) {
      _seed32 = null;
      _idPub = null;
      _devPriv = null;
      _devPub = null;
      _loadedAccount = null;
    }
    for (final key in [_kSeed, _kIdPub, _kDevPriv, _kDevPub, _kMnemonic]) {
      await _ss.delete(key: _scopedKey(key, normalized));
    }
  }

  // ── utils ──
  Uint8List _randomBytes(int n) {
    final r = Random.secure();
    return Uint8List.fromList(List.generate(n, (_) => r.nextInt(256)));
  }

  String _bitsFromBytes(Uint8List bytes) {
    final sb = StringBuffer();
    for (final b in bytes) {
      sb.write(b.toRadixString(2).padLeft(8, '0'));
    }
    return sb.toString();
  }
}
