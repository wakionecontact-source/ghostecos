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
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart' as cryptography;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:pointycastle/export.dart';
import '../core/local/app_logger.dart';

class ServerKeyMismatchException implements Exception {
  const ServerKeyMismatchException();
}

class CryptoService {
  CryptoService._();
  static final CryptoService instance = CryptoService._();

  // v4: account-scoped names. The previous v3 names were global, so after
  // logout/login the second account could encrypt as the first one.
  static const _kPrivD =
      'gs_e2e_priv_d_v4'; // приват D-coordinate (32 bytes b64)
  static const _kPubRaw = 'gs_e2e_pub_raw_v4'; // 65 bytes uncompressed (b64)
  static const _legacyPrivD = 'gs_e2e_priv_d_v3';
  static const _legacyPubRaw = 'gs_e2e_pub_raw_v3';

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
  String? _loadedAccount;

  String _normalizeAccount(String account) => account.trim().toLowerCase();

  String _scopedKey(String key, String account) {
    final encoded = base64Url
        .encode(utf8.encode(_normalizeAccount(account)))
        .replaceAll('=', '');
    return '${key}_$encoded';
  }

  String _requireAccount(String? account) {
    final requested = account?.trim();
    final normalized = _normalizeAccount(
      requested?.isNotEmpty == true ? requested! : (_loadedAccount ?? ''),
    );
    if (normalized.isEmpty) {
      throw StateError('CryptoService account is not set');
    }
    return normalized;
  }

  /// Загрузить ключи из SecureStorage или сгенерировать новые.
  /// Возвращает свой публичный ключ в raw-формате (65 байт).
  Future<Uint8List> ensureKeys({String? account}) async {
    final normalized = _requireAccount(account);
    if (_loadedAccount == normalized && _myPubRaw != null) return _myPubRaw!;
    _privD = null;
    _myPub = null;
    _myPubRaw = null;
    final priv = await _secure.read(key: _scopedKey(_kPrivD, normalized));
    final pub = await _secure.read(key: _scopedKey(_kPubRaw, normalized));
    if (priv != null && priv.isNotEmpty) {
      final privateBytes = _decodeBase64Exact(priv, 32, 'private key');
      final privateD = _decodeBigInt(privateBytes);
      _validatePrivateScalar(privateD);
      final derivedPub = _pubRawFromD(privateD);
      Uint8List? storedPub;
      if (pub != null && pub.isNotEmpty) {
        try {
          storedPub = _decodeBase64Exact(pub, 65, 'public key');
          if (storedPub[0] != 4) storedPub = null;
        } catch (_) {
          storedPub = null;
        }
      }
      // The private scalar is the source of truth. A stale/corrupt stored
      // public value must never make the app believe that the pair is valid:
      // decryptFrom/decryptSealed use the private scalar.
      if (storedPub == null || !_sameBytes(derivedPub, storedPub)) {
        appLog.warn(
          'crypto',
          'stored E2E public key was missing/invalid or did not match private key; repaired locally',
        );
        await _secure.write(
          key: _scopedKey(_kPubRaw, normalized),
          value: base64Encode(derivedPub),
        );
      }
      _privD = privateD;
      _myPubRaw = derivedPub;
      _myPub = _rawToPub(_myPubRaw!);
      _loadedAccount = normalized;
      appLog.debug('crypto', 'E2E key loaded from secure storage');
      return _myPubRaw!;
    }
    // A public-only orphan cannot decrypt anything. Do not treat it as a
    // private key and do not silently keep it after generating a new pair.
    if (pub != null && pub.isNotEmpty) {
      await _secure.delete(key: _scopedKey(_kPubRaw, normalized));
      appLog.warn(
        'crypto',
        'orphaned E2E public key removed before generation',
      );
    }
    appLog.info('crypto', 'E2E key pair missing, generating locally');
    return _generateAndStore(normalized);
  }

  Future<Uint8List> _generateAndStore(String account) async {
    final pair = _generateKeyPair();
    final priv = pair.privateKey as ECPrivateKey;
    final pub = pair.publicKey as ECPublicKey;
    final dBytes = _encodeBigInt(priv.d!, 32);
    final pubRaw = _pubToRaw(pub);
    await _secure.write(
      key: _scopedKey(_kPrivD, account),
      value: base64Encode(dBytes),
    );
    await _secure.write(
      key: _scopedKey(_kPubRaw, account),
      value: base64Encode(pubRaw),
    );
    _privD = priv.d;
    _myPub = pub;
    _myPubRaw = pubRaw;
    _loadedAccount = account;
    return pubRaw;
  }

  static AsymmetricKeyPair<PublicKey, PrivateKey> _generateKeyPair() {
    final gen = ECKeyGenerator();
    final rnd = FortunaRandom();
    final seedSrc = Random.secure();
    final seed = Uint8List.fromList(
      List<int>.generate(32, (_) => seedSrc.nextInt(256)),
    );
    rnd.seed(KeyParameter(seed));
    gen.init(ParametersWithRandom(ECKeyGeneratorParameters(_curve), rnd));
    return gen.generateKeyPair();
  }

  Future<Uint8List> myPublicKeyRaw({String? account}) async {
    if (account == null && _myPubRaw != null) return _myPubRaw!;
    return ensureKeys(account: account);
  }

  /// Read-only check used by the in-chat key watcher. Unlike ensureKeys(),
  /// this never generates a new pair when secure storage is empty. The public
  /// value is derived from the private scalar, because that is the key that
  /// actually decrypts old messages.
  Future<Uint8List?> privateKeyPublicRaw({String? account}) async {
    final normalized = _requireAccount(account);
    if (_loadedAccount == normalized && _privD != null) {
      return _pubRawFromD(_privD!);
    }
    final priv = await _secure.read(key: _scopedKey(_kPrivD, normalized));
    if (priv == null || priv.isEmpty) return null;
    try {
      final d = _decodeBigInt(_decodeBase64Exact(priv, 32, 'private key'));
      _validatePrivateScalar(d);
      return _pubRawFromD(d);
    } catch (e) {
      appLog.warn('crypto', 'stored E2E private key could not be checked: $e');
      return null;
    }
  }

  /// Recover the old global v3 key only when its public part exactly matches
  /// the key registered for this account. Ownership is never inferred from
  /// which account happened to log in first after an update.
  Future<bool> adoptLegacyKeysIfMatching({
    required String account,
    required String expectedPubB64,
  }) async {
    final normalized = _requireAccount(account);
    final legacyPriv = await _secure.read(key: _legacyPrivD);
    final legacyPub = await _secure.read(key: _legacyPubRaw);
    if (legacyPriv == null ||
        legacyPub == null ||
        legacyPub != expectedPubB64) {
      return false;
    }
    final dBytes = Uint8List.fromList(base64Decode(legacyPriv));
    final pubRaw = Uint8List.fromList(base64Decode(legacyPub));
    if (dBytes.length != 32 || pubRaw.length != 65 || pubRaw[0] != 4) {
      return false;
    }
    _privD = _decodeBigInt(dBytes);
    _myPubRaw = pubRaw;
    _myPub = _rawToPub(pubRaw);
    _loadedAccount = normalized;
    await _secure.write(
      key: _scopedKey(_kPrivD, normalized),
      value: legacyPriv,
    );
    await _secure.write(
      key: _scopedKey(_kPubRaw, normalized),
      value: legacyPub,
    );
    appLog.info('crypto', 'legacy v1 key adopted for matching account');
    return true;
  }

  /// Сбросить ключи из памяти при logout. Сохранённый account-scoped ключ не
  /// удаляем: при возврате в тот же аккаунт он нужен для старой переписки.
  /// [deleteStored] используется только явной операцией перегенерации ключей.
  Future<void> wipe({String? account, bool deleteStored = false}) async {
    final storedAccount = account ?? _loadedAccount;
    _privD = null;
    _myPub = null;
    _myPubRaw = null;
    _loadedAccount = null;
    if (deleteStored && storedAccount != null) {
      final normalized = _requireAccount(storedAccount);
      await _secure.delete(key: _scopedKey(_kPrivD, normalized));
      await _secure.delete(key: _scopedKey(_kPubRaw, normalized));
    }
    appLog.info('crypto', 'session E2E keys wiped');
  }

  /// Проверка наличия приватного ключа без генерации и без изменения storage.
  Future<bool> hasStoredPrivateKey({required String account}) async {
    final normalized = _requireAccount(account);
    final raw = await _secure.read(key: _scopedKey(_kPrivD, normalized));
    if (raw == null || raw.isEmpty) return false;
    try {
      final d = _decodeBigInt(_decodeBase64Exact(raw, 32, 'private key'));
      _validatePrivateScalar(d);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Удалить account-scoped ключ только по явному решению пользователя.
  Future<void> deleteStoredKeys({required String account}) async {
    final normalized = _requireAccount(account);
    if (_loadedAccount == normalized) {
      _privD = null;
      _myPub = null;
      _myPubRaw = null;
      _loadedAccount = null;
    }
    await _secure.delete(key: _scopedKey(_kPrivD, normalized));
    await _secure.delete(key: _scopedKey(_kPubRaw, normalized));
  }

  // ════════════════════════════════════════════════════════════════════
  // SERVER-режим хранения приватника: приватник, зашифрованный паролем,
  // лежит на сервере (users.encrypted_private_key). Новые контейнеры:
  //   Argon2id(password, salt16, m=65536 KiB, t=3, p=1) → AES-GCM
  //   encrypted_private_key = base64(iv(12) || ciphertext || tag)
  //   key_kdf = argon2id-v1-m65536-t3-p1
  //   key_format = p256-pkcs8-aesgcm-v2
  // Старый контейнер PBKDF2 принимается только по явному/legacy metadata.
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
    final ver = _tlv(pkcs8, p);
    p = ver[3]; // INTEGER version
    final alg = _tlv(pkcs8, p);
    p = alg[3]; // SEQUENCE alg
    final pk = _tlv(pkcs8, p); // OCTET STRING privateKey
    final inner = _tlv(pkcs8, pk[1]); // SEQUENCE ECPrivateKey
    var q = inner[1];
    final iv = _tlv(pkcs8, q);
    q = iv[3]; // INTEGER 1
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

  static const serverKeyKdfArgon2id = 'argon2id-v1-m65536-t3-p1';
  static const serverKeyKdfPbkdf2 = 'pbkdf2-sha256-v1-i260000';
  static const serverKeyFormatV2 = 'p256-pkcs8-aesgcm-v2';
  static const _argonMemory = 65536; // 64 MiB in 1 KiB blocks
  static const _argonIterations = 3;
  static const _argonParallelism = 1;

  // PBKDF2(password, salt, 260000, SHA-256) → 32-байтный AES-ключ legacy.
  // 260к итераций — тяжёлая CPU-работа (сотни мс), в отдельном изоляте, чтобы
  // не морозить UI-поток/анимации на экране ввода пароля (KeyGate).
  Future<Uint8List> _deriveMasterKey(String password, Uint8List salt) {
    return Isolate.run(() {
      final kd = PBKDF2KeyDerivator(HMac(SHA256Digest(), 64))
        ..init(Pbkdf2Parameters(salt, 260000, 32));
      return kd.process(Uint8List.fromList(utf8.encode(password)));
    });
  }

  Future<Uint8List> _deriveArgon2idKey(String password, Uint8List salt) async {
    final algorithm = cryptography.Argon2id(
      parallelism: _argonParallelism,
      memory: _argonMemory,
      iterations: _argonIterations,
      hashLength: 32,
    );
    final key = await algorithm.deriveKey(
      secretKey: cryptography.SecretKey(utf8.encode(password)),
      nonce: salt,
    );
    return Uint8List.fromList(await key.extractBytes());
  }

  Uint8List _serverKeyAad(String account) => Uint8List.fromList(
    utf8.encode('ghostchat/e2e-key/${_normalizeAccount(account)}/v2'),
  );

  Uint8List _pubRawFromD(BigInt d) =>
      _pubToRaw(ECPublicKey((_curve.G * d)!, _curve));

  /// SERVER-режим: экспортировать локальный приватник зашифрованным паролем,
  /// в новом Argon2id-формате. Возвращает metadata для POST /keys/upload.
  Future<Map<String, String>> exportEncryptedPrivForServer(
    String password, {
    String? account,
  }) async {
    final normalized = _requireAccount(account);
    await ensureKeys(account: normalized);
    final d32 = _encodeBigInt(_privD!, 32);
    final pkcs8 = _dToPkcs8(d32, _myPubRaw!);
    final salt = _randomBytes(16);
    if (password.isEmpty) throw ArgumentError('password must not be empty');
    final master = await _deriveArgon2idKey(password, salt);
    final iv = _randomBytes(12);
    final gcm = GCMBlockCipher(AESEngine())
      ..init(
        true,
        AEADParameters(
          KeyParameter(master),
          128,
          iv,
          _serverKeyAad(normalized),
        ),
      );
    final ct = gcm.process(pkcs8);
    final enc =
        (BytesBuilder()
              ..add(iv)
              ..add(ct))
            .toBytes();
    return {
      'encrypted_private_key': base64Encode(enc),
      'key_salt': base64Encode(salt),
      'key_kdf': serverKeyKdfArgon2id,
      'key_format': serverKeyFormatV2,
    };
  }

  /// SERVER-режим: восстановить приватник, скачанный с сервера (расшифровать
  /// паролем), и сохранить локально. Возвращает свой pub raw (65 байт). Бросает
  /// при неверном пароле / битом блобе. После вызова identity устройства =
  /// серверная (совпадает с серверным x25519_pub).
  Future<Uint8List> importServerPriv(
    String encB64,
    String saltB64,
    String password, {
    String? account,
    String? keyKdf,
    String? keyFormat,
    String? expectedPublicKeyB64,
  }) async {
    final normalized = _requireAccount(account);
    if (password.isEmpty) throw ArgumentError('password must not be empty');
    final enc = _decodeBase64Min(encB64, 12 + 16, 'encrypted_private_key');
    final salt = _decodeBase64Exact(saltB64, 16, 'key_salt');
    if (enc.length < 12 + 16)
      throw Exception('encrypted_private_key слишком короткий');
    final iv = Uint8List.fromList(enc.sublist(0, 12));
    final ct = Uint8List.fromList(enc.sublist(12));
    final metadataFree = keyKdf == null && keyFormat == null;
    final explicitArgon =
        keyKdf == serverKeyKdfArgon2id && keyFormat == serverKeyFormatV2;
    final explicitLegacy = keyKdf == serverKeyKdfPbkdf2 && keyFormat == null;
    if (!metadataFree && !explicitArgon && !explicitLegacy) {
      throw Exception('неподдерживаемый формат серверного ключа');
    }

    Future<Uint8List> decryptContainer({required bool argon}) async {
      final master = argon
          ? await _deriveArgon2idKey(password, salt)
          : await _deriveMasterKey(password, salt);
      final gcm = GCMBlockCipher(AESEngine())
        ..init(
          false,
          AEADParameters(
            KeyParameter(master),
            128,
            iv,
            argon ? _serverKeyAad(normalized) : Uint8List(0),
          ),
        );
      return gcm.process(ct); // бросит InvalidCipherText при неверном пароле
    }

    late final Uint8List pkcs8;
    if (explicitArgon) {
      pkcs8 = await decryptContainer(argon: true);
    } else if (metadataFree) {
      // Production до v1.1.25 сохранял blob/salt, но терял metadata. Новые
      // контейнеры этого клиента были Argon2id, поэтому сначала пробуем их;
      // затем оставляем совместимость со старыми web/PBKDF2-копиями.
      try {
        pkcs8 = await decryptContainer(argon: true);
      } catch (_) {
        pkcs8 = await decryptContainer(argon: false);
      }
    } else {
      pkcs8 = await decryptContainer(argon: false);
    }
    final d = _decodeBigInt(_pkcs8ToD(pkcs8));
    _validatePrivateScalar(d);
    final pubRaw = _pubRawFromD(d);
    if (expectedPublicKeyB64 != null &&
        base64Encode(pubRaw) != expectedPublicKeyB64) {
      // Verify the account binding before mutating either memory or secure
      // storage. A stale/corrupt server blob must not replace a good local key.
      throw const ServerKeyMismatchException();
    }
    _privD = d;
    _myPubRaw = pubRaw;
    _myPub = _rawToPub(pubRaw);
    await _secure.write(
      key: _scopedKey(_kPrivD, normalized),
      value: base64Encode(_encodeBigInt(d, 32)),
    );
    await _secure.write(
      key: _scopedKey(_kPubRaw, normalized),
      value: base64Encode(pubRaw),
    );
    _loadedAccount = normalized;
    return pubRaw;
  }

  /// Зашифровать payload для конкретного peer-а (raw 65-byte pubkey).
  /// Возвращает base64(iv(12) || ct || tag(16)).
  // Тяжёлая часть (P-256 ECDH — скалярное умножение в pure-Dart pointycastle,
  // десятки мс на мобиле — + AES-GCM) уходит в фоновый изолят через Isolate.run
  // (тот же приём, что и _deriveMasterKey выше), чтобы не блокировать UI-поток
  // на каждом отправленном/принятом сообщении серверного чата. _privD передаём
  // в изолят как 32-байтный big-endian D — статические entry-функции ниже
  // самодостаточны (свой _curve на изолят), instance-состояние не захватывается.
  Future<String> encryptFor({
    required Uint8List theirPubRaw,
    required String plaintext,
  }) async {
    if (_privD == null) await ensureKeys();
    final privD = _encodeBigInt(_privD!, 32);
    return Isolate.run(() => _encryptForStatic(privD, theirPubRaw, plaintext));
  }

  static String _encryptForStatic(
    Uint8List privD32,
    Uint8List theirPubRaw,
    String plaintext,
  ) {
    final aesKey = _deriveAesKeyStatic(privD32, theirPubRaw);
    final iv = _randomBytes(12);
    final cipher = GCMBlockCipher(AESEngine());
    cipher.init(
      true,
      AEADParameters(KeyParameter(aesKey), 128, iv, Uint8List(0)),
    );
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
    if (_privD == null) await ensureKeys();
    final privD = _encodeBigInt(_privD!, 32);
    return Isolate.run(
      () => _decryptFromStatic(privD, theirPubRaw, envelopeB64),
    );
  }

  static String _decryptFromStatic(
    Uint8List privD32,
    Uint8List theirPubRaw,
    String envelopeB64,
  ) {
    final aesKey = _deriveAesKeyStatic(privD32, theirPubRaw);
    final bytes = base64Decode(envelopeB64);
    if (bytes.length < 12 + 16) throw Exception('envelope too short');
    final iv = Uint8List.fromList(bytes.sublist(0, 12));
    final ct = Uint8List.fromList(bytes.sublist(12));
    final cipher = GCMBlockCipher(AESEngine());
    cipher.init(
      false,
      AEADParameters(KeyParameter(aesKey), 128, iv, Uint8List(0)),
    );
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
    // Сборка payload дёшева — на UI-потоке; тяжёлое (эфемерная keygen + ECDH +
    // AES-GCM) уходит в изолят.
    final fullPayload = <String, dynamic>{
      ...payload,
      'from_username': fromUsername,
      'ts': DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000,
    };
    final ptJson = jsonEncode(fullPayload);
    return Isolate.run(() => _encryptSealedStatic(receiverPubRaw, ptJson));
  }

  static String _encryptSealedStatic(Uint8List receiverPubRaw, String ptJson) {
    final pair = _generateKeyPair();
    final ephPriv = (pair.privateKey as ECPrivateKey).d!;
    final ephPub = pair.publicKey as ECPublicKey;
    final ephPubRaw = _pubToRaw(ephPub);
    final agreement = ECDHBasicAgreement()..init(ECPrivateKey(ephPriv, _curve));
    final shared = agreement.calculateAgreement(_rawToPub(receiverPubRaw));
    final aesKey = _encodeBigInt(shared, 32);
    final iv = _randomBytes(12);
    final pt = utf8.encode(ptJson);
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
    final privD = _encodeBigInt(_privD!, 32);
    return Isolate.run(() => _decryptSealedStatic(privD, envelopeB64));
  }

  static Map<String, dynamic> _decryptSealedStatic(
    Uint8List privD32,
    String envelopeB64,
  ) {
    final bytes = base64Decode(envelopeB64);
    if (bytes.length < 65 + 12 + 16) {
      throw Exception('sealed envelope too short (${bytes.length})');
    }
    final ephPubRaw = Uint8List.fromList(bytes.sublist(0, 65));
    final iv = Uint8List.fromList(bytes.sublist(65, 77));
    final ct = Uint8List.fromList(bytes.sublist(77));
    final agreement = ECDHBasicAgreement()
      ..init(ECPrivateKey(_decodeBigInt(privD32), _curve));
    final shared = agreement.calculateAgreement(_rawToPub(ephPubRaw));
    final aesKey = _encodeBigInt(shared, 32);
    final cipher = GCMBlockCipher(
      AESEngine(),
    )..init(false, AEADParameters(KeyParameter(aesKey), 128, iv, Uint8List(0)));
    final pt = cipher.process(ct);
    final json = utf8.decode(pt);
    return Map<String, dynamic>.from(jsonDecode(json) as Map);
  }

  /// ECDH → HKDF-SHA256 → 32-байт AES ключ (статическая, isolate-safe версия).
  /// salt = zeros(32), info = 'ghostchat-msg-v1' — parity с веб-фронтом.
  static Uint8List _deriveAesKeyStatic(
    Uint8List privD32,
    Uint8List theirPubRaw,
  ) {
    final theirPub = _rawToPub(theirPubRaw);
    // ECDH shared secret = scalar(d) * Point(theirPub).x → 32 байта
    final agreement = ECDHBasicAgreement()
      ..init(ECPrivateKey(_decodeBigInt(privD32), _curve));
    final shared = agreement.calculateAgreement(theirPub);
    final sharedBytes = _encodeBigInt(shared, 32);
    // HKDF-SHA256
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

  // ─── Helpers: raw <-> EC ─────────────────────────────────────────────
  static Uint8List _pubToRaw(ECPublicKey pub) {
    final q = pub.Q!;
    final x = _encodeBigInt(q.x!.toBigInteger()!, 32);
    final y = _encodeBigInt(q.y!.toBigInteger()!, 32);
    final out = Uint8List(65)..[0] = 0x04;
    out.setRange(1, 33, x);
    out.setRange(33, 65, y);
    return out;
  }

  static bool _sameBytes(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static ECPublicKey _rawToPub(Uint8List raw) {
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
  static Uint8List _encodeBigInt(BigInt n, int length) {
    final out = Uint8List(length);
    var v = n;
    for (var i = length - 1; i >= 0 && v > BigInt.zero; i--) {
      out[i] = (v & BigInt.from(0xFF)).toInt();
      v = v >> 8;
    }
    return out;
  }

  static BigInt _decodeBigInt(List<int> bytes) {
    var n = BigInt.zero;
    for (final b in bytes) {
      n = (n << 8) | BigInt.from(b & 0xFF);
    }
    return n;
  }

  static void _validatePrivateScalar(BigInt d) {
    if (d <= BigInt.zero || d >= _curve.n) {
      throw FormatException('invalid P-256 private scalar');
    }
  }

  static Uint8List _decodeBase64Exact(String value, int length, String field) {
    final bytes = base64Decode(value);
    if (bytes.length != length) {
      throw FormatException('$field must contain exactly $length bytes');
    }
    return Uint8List.fromList(bytes);
  }

  static Uint8List _decodeBase64Min(String value, int minLength, String field) {
    final bytes = base64Decode(value);
    if (bytes.length < minLength) {
      throw FormatException('$field is too short');
    }
    return Uint8List.fromList(bytes);
  }

  static Uint8List _randomBytes(int n) {
    final r = Random.secure();
    return Uint8List.fromList(List<int>.generate(n, (_) => r.nextInt(256)));
  }
}
