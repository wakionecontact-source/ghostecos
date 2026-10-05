// Переносимый backup локальной SQLite-БД.
//
// Файл намеренно сохраняется через системный file picker, а не во внутренний
// каталог приложения: после удаления APK он остаётся у пользователя. Содержимое
// — бинарный контейнер с Argon2id + AES-256-GCM; пароль нигде не сохраняется.

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' as cryptography;
import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
import 'package:pointycastle/export.dart';

import '../core/local/app_logger.dart';
import 'db_service.dart';

class DatabaseBackupService {
  DatabaseBackupService._();
  static final DatabaseBackupService instance = DatabaseBackupService._();

  static const _channel = MethodChannel('ghostchat/db_backup');
  static const _magic = 'ghostchat-db-backup';
  static const _formatVersion = 1;
  static const _argonMemory = 65536; // 64 MiB in 1 KiB blocks.
  static const _argonIterations = 3;
  static const _argonParallelism = 1;
  static const _saltLength = 16;
  static const _nonceLength = 12;
  static const _tagLength = 16;
  static const _maxSnapshotBytes = 256 * 1024 * 1024;
  static const _maxContainerBytes = _maxSnapshotBytes + 64;

  Uint8List get _magicBytes => Uint8List.fromList(utf8.encode(_magic));

  /// Pure encryption path used by the file export and unit tests.
  /// The account name is authenticated as AAD, but is not written in plaintext
  /// to the backup file.
  Future<Uint8List> encryptSnapshot(
    Uint8List snapshot, {
    required String account,
    required String password,
  }) async {
    final normalizedAccount = _requireAccount(account);
    _validatePassword(password);
    _validateSqliteSnapshot(snapshot);

    final salt = _randomBytes(_saltLength);
    final nonce = _randomBytes(_nonceLength);
    Uint8List? key;
    try {
      key = await _deriveKey(password, salt);
      final cipher = GCMBlockCipher(AESEngine())
        ..init(
          true,
          AEADParameters(
            KeyParameter(key),
            _tagLength * 8,
            nonce,
            _aad(normalizedAccount),
          ),
        );
      final ciphertext = Uint8List.fromList(cipher.process(snapshot));
      final output = BytesBuilder(copy: false)
        ..add(_magicBytes)
        ..addByte(_formatVersion)
        ..add(salt)
        ..add(nonce)
        ..add(ciphertext);
      final container = output.toBytes();
      if (container.length > _maxContainerBytes) {
        throw StateError('Database backup is too large');
      }
      return container;
    } finally {
      _wipe(key);
      _wipe(salt);
      _wipe(nonce);
    }
  }

  /// Pure decryption path used by the file import and unit tests.
  Future<Uint8List> decryptSnapshot(
    Uint8List container, {
    required String account,
    required String password,
  }) async {
    final normalizedAccount = _requireAccount(account);
    _validatePassword(password);
    final parsed = _parseContainer(container);
    Uint8List? key;
    try {
      key = await _deriveKey(password, parsed.salt);
      final cipher = GCMBlockCipher(AESEngine())
        ..init(
          false,
          AEADParameters(
            KeyParameter(key),
            _tagLength * 8,
            parsed.nonce,
            _aad(normalizedAccount),
          ),
        );
      Uint8List snapshot;
      try {
        snapshot = Uint8List.fromList(cipher.process(parsed.ciphertext));
      } catch (_) {
        // Do not reveal whether the password, account binding, or bytes were
        // wrong. AES-GCM authentication deliberately gives one generic error.
        throw FormatException('Invalid or unauthenticated database backup');
      }
      _validateSqliteSnapshot(snapshot);
      return snapshot;
    } finally {
      _wipe(key);
      _wipe(parsed.salt);
      _wipe(parsed.nonce);
      _wipe(parsed.ciphertext);
    }
  }

  /// Создать зашифрованный backup и передать его системному file picker.
  /// null означает, что пользователь отменил выбор места сохранения.
  Future<String?> exportToFile({
    required String account,
    required String password,
  }) async {
    final normalizedAccount = _requireAccount(account);
    _ensureActiveAccount(normalizedAccount);
    final snapshot = await DbService.instance.exportDatabaseSnapshot();
    Uint8List? container;

    try {
      container = await encryptSnapshot(
        snapshot,
        account: normalizedAccount,
        password: password,
      );
      final fileName = _suggestedFileName();
      if (Platform.isAndroid) {
        final saved = await _channel.invokeMethod<String>(
          'saveBackup',
          <String, dynamic>{'fileName': fileName, 'bytes': container},
        );
        if (saved != null) {
          appLog.info('storage', 'database backup exported');
        }
        return saved;
      }

      final location = await getSaveLocation(
        suggestedName: fileName,
        confirmButtonText: 'Сохранить',
        acceptedTypeGroups: const [
          XTypeGroup(
            label: 'GhostChat backup',
            extensions: ['gcdb'],
            mimeTypes: ['application/octet-stream'],
          ),
        ],
      );
      if (location == null) return null;
      await XFile.fromData(
        container,
        name: fileName,
        mimeType: 'application/octet-stream',
      ).saveTo(location.path);
      appLog.info('storage', 'database backup exported');
      return location.path;
    } finally {
      _wipe(snapshot);
      _wipe(container);
    }
  }

  /// Выбрать backup, расшифровать и атомарно заменить активную SQLite-БД.
  /// false означает отмену file picker.
  Future<bool> restoreFromFile({
    required String account,
    required String password,
  }) async {
    final normalizedAccount = _requireAccount(account);
    _ensureActiveAccount(normalizedAccount);

    Uint8List? container;
    try {
      if (Platform.isAndroid) {
        final raw = await _channel.invokeMethod<dynamic>('openBackup');
        if (raw == null) return false;
        if (raw is Uint8List) {
          container = raw;
        } else if (raw is List) {
          container = Uint8List.fromList(List<int>.from(raw));
        } else {
          throw FormatException('Invalid backup file data');
        }
      } else {
        final file = await openFile(
          acceptedTypeGroups: const [
            XTypeGroup(
              label: 'GhostChat backup',
              extensions: ['gcdb'],
              mimeTypes: ['application/octet-stream'],
            ),
          ],
        );
        if (file == null) return false;
        final length = await file.length();
        if (length > _maxContainerBytes) {
          throw FormatException('Database backup is too large');
        }
        container = await file.readAsBytes();
      }

      if (container.length > _maxContainerBytes) {
        throw FormatException('Database backup is too large');
      }
      final snapshot = await decryptSnapshot(
        container,
        account: normalizedAccount,
        password: password,
      );
      try {
        await DbService.instance.restoreDatabaseSnapshot(snapshot);
      } finally {
        _wipe(snapshot);
      }
      appLog.info('storage', 'database backup restored');
      return true;
    } finally {
      _wipe(container);
    }
  }

  String _requireAccount(String account) {
    final normalized = account.trim().toLowerCase();
    if (normalized.isEmpty || normalized.length > 256) {
      throw ArgumentError('Invalid account');
    }
    return normalized;
  }

  void _ensureActiveAccount(String account) {
    final active = DbService.instance.currentUsername?.trim().toLowerCase();
    if (active == null || active != account) {
      throw StateError('Active account database is not ready');
    }
  }

  void _validatePassword(String password) {
    if (password.isEmpty || password.length > 512) {
      throw ArgumentError('Invalid backup password');
    }
  }

  Uint8List _aad(String account) =>
      Uint8List.fromList(utf8.encode('ghostchat/db-backup/v1/$account'));

  Future<Uint8List> _deriveKey(String password, Uint8List salt) async {
    final algorithm = cryptography.Argon2id(
      parallelism: _argonParallelism,
      memory: _argonMemory,
      iterations: _argonIterations,
      hashLength: 32,
    );
    final secret = await algorithm.deriveKey(
      secretKey: cryptography.SecretKey(utf8.encode(password)),
      nonce: salt,
    );
    return Uint8List.fromList(await secret.extractBytes());
  }

  _ParsedContainer _parseContainer(Uint8List container) {
    if (container.length > _maxContainerBytes) {
      throw FormatException('Database backup is too large');
    }
    final magicBytes = _magicBytes;
    final headerLength = magicBytes.length + 1;
    final minimumLength =
        headerLength + _saltLength + _nonceLength + _tagLength;
    if (container.length < minimumLength) {
      throw FormatException('Database backup is truncated');
    }
    if (!_sameBytes(container, 0, magicBytes)) {
      throw FormatException('Unsupported database backup format');
    }
    if (container[magicBytes.length] != _formatVersion) {
      throw FormatException('Unsupported database backup version');
    }
    final saltStart = headerLength;
    final nonceStart = saltStart + _saltLength;
    final ciphertextStart = nonceStart + _nonceLength;
    return _ParsedContainer(
      salt: Uint8List.fromList(container.sublist(saltStart, nonceStart)),
      nonce: Uint8List.fromList(container.sublist(nonceStart, ciphertextStart)),
      ciphertext: Uint8List.fromList(container.sublist(ciphertextStart)),
    );
  }

  void _validateSqliteSnapshot(Uint8List bytes) {
    if (bytes.length < 100 || bytes.length > _maxSnapshotBytes) {
      throw FormatException('Unsupported database snapshot size');
    }
    final header = utf8.decode(bytes.sublist(0, 16), allowMalformed: true);
    if (header != 'SQLite format 3\u0000') {
      throw FormatException('Not a SQLite database snapshot');
    }
  }

  bool _sameBytes(Uint8List source, int offset, Uint8List expected) {
    if (offset < 0 || offset + expected.length > source.length) return false;
    for (var i = 0; i < expected.length; i++) {
      if (source[offset + i] != expected[i]) return false;
    }
    return true;
  }

  Uint8List _randomBytes(int length) {
    final random = Random.secure();
    return Uint8List.fromList(
      List<int>.generate(length, (_) => random.nextInt(256)),
    );
  }

  void _wipe(Uint8List? bytes) {
    if (bytes != null) bytes.fillRange(0, bytes.length, 0);
  }

  String _suggestedFileName() {
    final now = DateTime.now();
    String two(int value) => value.toString().padLeft(2, '0');
    return 'ghostchat_database_${now.year}${two(now.month)}${two(now.day)}'
        '_${two(now.hour)}${two(now.minute)}${two(now.second)}.gcdb';
  }
}

class _ParsedContainer {
  final Uint8List salt;
  final Uint8List nonce;
  final Uint8List ciphertext;

  const _ParsedContainer({
    required this.salt,
    required this.nonce,
    required this.ciphertext,
  });
}
