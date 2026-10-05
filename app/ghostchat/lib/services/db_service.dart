// Локальное хранилище Ghost. SQLite (sqflite / sqflite_common_ffi для desktop).
//
// Аналог IndexedDB v4 веб-фронта:
//   messages — все DM + групповые сообщения юзера
//   dialogs  — превью чатов (последнее сообщение + unread)
//   peerkeys — TOFU pinning публичных ключей собеседников
//   filecache — зашифрованные blob'ы файлов/голосовых
//
// Pet schemas совместимы с веб-фронтом (одинаковые имена полей, ISO/unix-int created_at).
//
// Использование:
//   await DbService.instance.init();
//   await DbService.instance.upsertMessage(m);
//   final msgs = await DbService.instance.getMessages(peer: '@alice');

import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import '../core/local/app_logger.dart';
import 'message_record_merge.dart';
import '../core/models/bot_reply_markup.dart';

/// Приводит смешанные форматы времени из локальных таблиц к одной шкале.
/// Старые записи могут содержать ISO-строку, Unix-секунды или Unix-миллисекунды;
/// сравнивать их как TEXT нельзя — тогда диалоги визуально «сортируются по имени».
DateTime dialogTimestamp(dynamic value) {
  final epoch = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
  if (value == null) return epoch;
  if (value is DateTime) return value.toUtc();
  if (value is num) {
    final raw = value.toInt();
    final millis = raw.abs() < 100000000000 ? raw * 1000 : raw;
    return DateTime.fromMillisecondsSinceEpoch(millis, isUtc: true);
  }
  final text = value.toString().trim();
  if (text.isEmpty) return epoch;
  final numeric = int.tryParse(text);
  if (numeric != null) {
    final millis = numeric.abs() < 100000000000 ? numeric * 1000 : numeric;
    return DateTime.fromMillisecondsSinceEpoch(millis, isUtc: true);
  }
  final parsed = DateTime.tryParse(text);
  if (parsed == null) return epoch;
  // Серверные даты часто приходят без суффикса зоны, но это UTC. Не даём
  // DateTime.parse принять такую строку за локальную дату устройства.
  if (parsed.isUtc || RegExp(r'(?:[zZ]|[+-]\d{2}:?\d{2})$').hasMatch(text)) {
    return parsed.toUtc();
  }
  return DateTime.utc(
    parsed.year,
    parsed.month,
    parsed.day,
    parsed.hour,
    parsed.minute,
    parsed.second,
    parsed.millisecond,
    parsed.microsecond,
  );
}

class StoredMessage {
  /// Серверный ID сообщения (sid в IDB), уникален per-peer.
  final int sid;

  /// 'username' для DM или 'g:42' для группы.
  final String peer;
  final bool fromMe;
  final String text;

  /// ISO-строка или unix-int (timestamp seconds).
  final dynamic createdAt;
  final int? replyTo;
  final String? replyPreview;
  final String? forwardedFrom;

  /// {file_id, file_name, mime, size, key (b64), iv (b64), voice?, duration?}
  final Map<String, dynamic>? filePayload;

  /// {emoji: [username, ...]}
  final Map<String, List<String>>? reactions;
  final BotReplyMarkup? replyMarkup;
  final bool edited;
  final bool deleted;
  final bool delivered;
  final bool read;
  final bool decryptFailed;

  /// Для optimistic — true пока POST /send в полёте.
  final bool pending;

  /// 'tmp-...' пока ждём server id, потом = sid.
  final String? tempSid;

  StoredMessage({
    required this.sid,
    required this.peer,
    required this.fromMe,
    this.text = '',
    required this.createdAt,
    this.replyTo,
    this.replyPreview,
    this.forwardedFrom,
    this.filePayload,
    this.reactions,
    this.replyMarkup,
    this.edited = false,
    this.deleted = false,
    this.delivered = false,
    this.read = false,
    this.decryptFailed = false,
    this.pending = false,
    this.tempSid,
  });

  Map<String, dynamic> toMap() => {
    'sid': sid,
    'peer': peer,
    'from_me': fromMe ? 1 : 0,
    'text': text,
    'created_at': createdAt is int ? createdAt : createdAt?.toString(),
    'reply_to': replyTo,
    'reply_preview': replyPreview,
    'forwarded_from': forwardedFrom,
    'file_payload': filePayload != null ? jsonEncode(filePayload) : null,
    'reactions': reactions != null ? jsonEncode(reactions) : null,
    'bot_reply_markup': replyMarkup != null
        ? jsonEncode(replyMarkup!.toJson())
        : null,
    'edited': edited ? 1 : 0,
    'deleted': deleted ? 1 : 0,
    'delivered': delivered ? 1 : 0,
    'read': read ? 1 : 0,
    'decrypt_failed': decryptFailed ? 1 : 0,
    'pending': pending ? 1 : 0,
    'temp_sid': tempSid,
  };

  static StoredMessage fromMap(Map<String, dynamic> m) => StoredMessage(
    sid: m['sid'] as int,
    peer: m['peer'] as String,
    fromMe: (m['from_me'] as int) == 1,
    text: (m['text'] as String?) ?? '',
    createdAt: m['created_at'],
    replyTo: m['reply_to'] as int?,
    replyPreview: m['reply_preview'] as String?,
    forwardedFrom: m['forwarded_from'] as String?,
    filePayload: m['file_payload'] != null
        ? jsonDecode(m['file_payload'] as String) as Map<String, dynamic>
        : null,
    reactions: m['reactions'] != null
        ? (jsonDecode(m['reactions'] as String) as Map).map(
            (k, v) => MapEntry(k as String, List<String>.from(v as List)),
          )
        : null,
    replyMarkup: BotReplyMarkup.tryParse(m['bot_reply_markup']),
    edited: (m['edited'] as int) == 1,
    deleted: (m['deleted'] as int) == 1,
    delivered: (m['delivered'] as int) == 1,
    read: (m['read'] as int) == 1,
    decryptFailed: (m['decrypt_failed'] as int? ?? 0) == 1,
    pending: (m['pending'] as int) == 1,
    tempSid: m['temp_sid'] as String?,
  );
}

class StoredDialog {
  final String username; // или 'g:42' для группы
  final String displayName;
  final String lastText;
  final dynamic lastAt; // ISO|unix-int|null
  final bool lastFromMe;
  final int unread;
  // Derived from the latest local message; these values are not persisted in
  // the dialogs table, so existing databases need no schema migration.
  final bool lastMessagePending;
  final bool lastMessageDelivered;
  final bool lastMessageRead;

  StoredDialog({
    required this.username,
    required this.displayName,
    this.lastText = '',
    this.lastAt,
    this.lastFromMe = false,
    this.unread = 0,
    this.lastMessagePending = false,
    this.lastMessageDelivered = false,
    this.lastMessageRead = false,
  });

  Map<String, dynamic> toMap() => {
    'username': username,
    'display_name': displayName,
    'last_text': lastText,
    'last_at': lastAt is int ? lastAt : lastAt?.toString(),
    'last_from_me': lastFromMe ? 1 : 0,
    'unread': unread,
  };

  static StoredDialog fromMap(Map<String, dynamic> m) => StoredDialog(
    username: m['username'] as String,
    displayName: (m['display_name'] as String?) ?? m['username'] as String,
    lastText: (m['last_text'] as String?) ?? '',
    lastAt: m['last_at'],
    lastFromMe: (m['last_from_me'] as int? ?? 0) == 1,
    unread: m['unread'] as int? ?? 0,
  );
}

/// Durable text send. `payload` is the local draft; `requestPayload` is the
/// exact prepared request when available, so an uncertain retry can replay it.
class OutboxEntry {
  final String id;
  final String kind;
  final String target;
  final Map<String, dynamic> payload;
  final Map<String, dynamic>? requestPayload;
  final int attempts;
  final int nextAttemptAt;
  final String? lastError;

  const OutboxEntry({
    required this.id,
    required this.kind,
    required this.target,
    required this.payload,
    required this.requestPayload,
    required this.attempts,
    required this.nextAttemptAt,
    required this.lastError,
  });

  factory OutboxEntry.fromMap(Map<String, Object?> row) => OutboxEntry(
    id: row['id'] as String,
    kind: row['kind'] as String,
    target: row['target'] as String,
    payload: jsonDecode(row['payload'] as String) as Map<String, dynamic>,
    requestPayload: row['request_payload'] == null
        ? null
        : jsonDecode(row['request_payload'] as String) as Map<String, dynamic>,
    attempts: row['attempts'] as int? ?? 0,
    nextAttemptAt: row['next_attempt_at'] as int? ?? 0,
    lastError: row['last_error'] as String?,
  );
}

class DbService {
  DbService._();
  static final DbService instance = DbService._();

  // Android CursorWindow не гарантирует чтение крупных BLOB-строк из
  // SQLite. Большие encrypted-файлы и весь plaintext держим на диске.
  static const int _maxEncryptedCacheBytes = 512 * 1024;

  Database? _db;
  String? _currentUser;
  String? _dbPath;

  /// Открыть БД для текущего юзера (или migrate если username сменился).
  Future<void> init(String username) async {
    if (_db != null && _currentUser == username) return;
    await _db?.close();
    _db = null;
    _currentUser = username;
    // NB: на desktop (Windows/Linux/macOS) sqflite нужен FFI (sqflite_common_ffi)
    // — отключено пока, build падал на скачивании native sqlite3. Вернём в M9.
    final dir = await getApplicationSupportDirectory();
    final path = p.join(dir.path, 'ghost_$username.db');
    _dbPath = path;
    appLog.info('db', 'open account database for @$username');
    if (kDebugMode) print('[DB] open $path');
    _db = await openDatabase(
      path,
      onCreate: (db, v) async {
        await db.execute('''
          CREATE TABLE messages (
            sid           INTEGER NOT NULL,
            peer          TEXT NOT NULL,
            from_me       INTEGER NOT NULL DEFAULT 0,
            text          TEXT NOT NULL DEFAULT '',
            created_at    TEXT,
            reply_to      INTEGER,
            reply_preview TEXT,
            forwarded_from TEXT,
            file_payload  TEXT,
            reactions     TEXT,
            edited        INTEGER NOT NULL DEFAULT 0,
            deleted       INTEGER NOT NULL DEFAULT 0,
            delivered     INTEGER NOT NULL DEFAULT 0,
            read          INTEGER NOT NULL DEFAULT 0,
            decrypt_failed INTEGER NOT NULL DEFAULT 0,
            bot_reply_markup TEXT,
            pending       INTEGER NOT NULL DEFAULT 0,
            temp_sid      TEXT,
            PRIMARY KEY (sid, peer)
          )
        ''');
        await db.execute('CREATE INDEX idx_msg_peer ON messages(peer, sid)');
        await db.execute('CREATE INDEX idx_msg_temp ON messages(temp_sid)');

        await db.execute('''
          CREATE TABLE dialogs (
            username      TEXT PRIMARY KEY,
            display_name  TEXT NOT NULL,
            last_text     TEXT NOT NULL DEFAULT '',
            last_at       TEXT,
            last_from_me  INTEGER NOT NULL DEFAULT 0,
            unread        INTEGER NOT NULL DEFAULT 0
          )
        ''');
        await db.execute('CREATE INDEX idx_dlg_last ON dialogs(last_at DESC)');

        await db.execute('''
          CREATE TABLE peerkeys (
            username    TEXT PRIMARY KEY,
            pub         TEXT NOT NULL,
            first_seen  TEXT NOT NULL,
            accepted    INTEGER NOT NULL DEFAULT 0
          )
        ''');
        await db.execute('''
          CREATE TABLE peeridentitykeys (
            username TEXT PRIMARY KEY,
            identity_pub TEXT NOT NULL,
            first_seen TEXT NOT NULL
          )
        ''');

        await db.execute('''
          CREATE TABLE filecache (
            file_id    TEXT PRIMARY KEY,
            bytes      BLOB NOT NULL,
            mime       TEXT,
            cached_at  INTEGER NOT NULL
          )
        ''');
        await db.execute(
          'CREATE INDEX idx_file_cached ON filecache(cached_at)',
        );
        await db.execute('''
          CREATE TABLE plaincache (
            file_id    TEXT PRIMARY KEY,
            path       TEXT NOT NULL,
            size       INTEGER NOT NULL,
            mime       TEXT,
            cached_at  INTEGER NOT NULL
          )
        ''');
        await db.execute(
          'CREATE INDEX IF NOT EXISTS idx_plain_file_cached ON plaincache(cached_at)',
        );
        await db.execute('''
          CREATE TABLE room_messages (
            room_key TEXT NOT NULL,
            message_id INTEGER NOT NULL,
            sender_username TEXT NOT NULL DEFAULT '',
            sender_display_name TEXT NOT NULL DEFAULT '',
            sender_avatar_url TEXT,
            text TEXT NOT NULL DEFAULT '',
            attachment_json TEXT,
            forwarded_from TEXT,
            created_at INTEGER NOT NULL,
            from_me INTEGER NOT NULL DEFAULT 0,
            delivered_count INTEGER NOT NULL DEFAULT 0,
            read_count INTEGER NOT NULL DEFAULT 0,
            delivered_ack_sent INTEGER NOT NULL DEFAULT 1,
            pending INTEGER NOT NULL DEFAULT 0,
            send_failed INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY (room_key, message_id)
          )
        ''');
        await db.execute(
          'CREATE INDEX idx_room_messages_room ON room_messages(room_key, message_id)',
        );
        await _createOutboxTable(db);
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 3) {
          final columns = await db.rawQuery('PRAGMA table_info(plaincache)');
          final hasBytes = columns.any((row) => row['name'] == 'bytes');
          final hasTable = columns.isNotEmpty;
          final legacyTable = await db.rawQuery(
            "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'plaincache_v2'",
          );

          if (!hasTable) {
            await db.execute('''
              CREATE TABLE IF NOT EXISTS plaincache (
                file_id    TEXT PRIMARY KEY,
                path       TEXT NOT NULL,
                size       INTEGER NOT NULL,
                mime       TEXT,
                cached_at  INTEGER NOT NULL
              )
            ''');
          } else if (hasBytes) {
            // Версия 2 ошибочно держала plaintext в SQLite BLOB. На Android
            // CursorWindow ограничивает крупные строки, поэтому медиа такого
            // размера могло не прочитаться. Переносим кэш на файловую систему;
            // таблица ниже хранит только путь и метаданные.
            if (legacyTable.isNotEmpty) {
              await db.execute('DROP TABLE plaincache_v2');
            }
            await db.execute('ALTER TABLE plaincache RENAME TO plaincache_v2');
            await db.execute('''
              CREATE TABLE plaincache (
                file_id    TEXT PRIMARY KEY,
                path       TEXT NOT NULL,
                size       INTEGER NOT NULL,
                mime       TEXT,
                cached_at  INTEGER NOT NULL
              )
            ''');
            await db.execute('DROP TABLE plaincache_v2');
          } else if (legacyTable.isNotEmpty) {
            // Предыдущая попытка миграции могла оставить старую таблицу
            // после переименования и упасть на повторном CREATE INDEX.
            await db.execute('DROP TABLE plaincache_v2');
          }
          await db.execute('''
            CREATE INDEX IF NOT EXISTS idx_plain_file_cached
            ON plaincache(cached_at)
          ''');
        }
        if (oldVersion < 4) {
          final columns = await db.rawQuery('PRAGMA table_info(messages)');
          final hasDecryptFailed = columns.any(
            (row) => row['name'] == 'decrypt_failed',
          );
          if (!hasDecryptFailed) {
            await db.execute(
              'ALTER TABLE messages ADD COLUMN decrypt_failed INTEGER NOT NULL DEFAULT 0',
            );
          }
        }
        if (oldVersion < 5) {
          await db.execute('''
            CREATE TABLE IF NOT EXISTS room_messages (
              room_key TEXT NOT NULL,
              message_id INTEGER NOT NULL,
              sender_username TEXT NOT NULL DEFAULT '',
              sender_display_name TEXT NOT NULL DEFAULT '',
              sender_avatar_url TEXT,
              text TEXT NOT NULL DEFAULT '',
              forwarded_from TEXT,
              created_at INTEGER NOT NULL,
              from_me INTEGER NOT NULL DEFAULT 0,
              delivered_count INTEGER NOT NULL DEFAULT 0,
              read_count INTEGER NOT NULL DEFAULT 0,
              delivered_ack_sent INTEGER NOT NULL DEFAULT 1,
              PRIMARY KEY (room_key, message_id)
            )
          ''');
          await db.execute(
            'CREATE INDEX IF NOT EXISTS idx_room_messages_room ON room_messages(room_key, message_id)',
          );
        }
        if (oldVersion < 6) {
          final columns = await db.rawQuery('PRAGMA table_info(room_messages)');
          if (columns.isNotEmpty &&
              !columns.any((row) => row['name'] == 'delivered_ack_sent')) {
            await db.execute(
              'ALTER TABLE room_messages ADD COLUMN delivered_ack_sent INTEGER NOT NULL DEFAULT 1',
            );
          }
        }
        if (oldVersion < 7) {
          await db.execute('''
            CREATE TABLE IF NOT EXISTS peeridentitykeys (
              username TEXT PRIMARY KEY,
              identity_pub TEXT NOT NULL,
              first_seen TEXT NOT NULL
            )
          ''');
        }
        if (oldVersion < 8) await _createOutboxTable(db);
        if (oldVersion < 9) {
          final columns = await db.rawQuery('PRAGMA table_info(room_messages)');
          if (!columns.any((row) => row['name'] == 'pending')) {
            await db.execute(
              'ALTER TABLE room_messages ADD COLUMN pending INTEGER NOT NULL DEFAULT 0',
            );
          }
          if (!columns.any((row) => row['name'] == 'send_failed')) {
            await db.execute(
              'ALTER TABLE room_messages ADD COLUMN send_failed INTEGER NOT NULL DEFAULT 0',
            );
          }
        }
        if (oldVersion < 10) {
          final columns = await db.rawQuery('PRAGMA table_info(messages)');
          if (!columns.any((row) => row['name'] == 'bot_reply_markup')) {
            await db.execute(
              'ALTER TABLE messages ADD COLUMN bot_reply_markup TEXT',
            );
          }
        }
        if (oldVersion < 11) {
          final columns = await db.rawQuery('PRAGMA table_info(room_messages)');
          if (!columns.any((row) => row['name'] == 'attachment_json')) {
            await db.execute(
              'ALTER TABLE room_messages ADD COLUMN attachment_json TEXT',
            );
          }
        }
      },
      version: 11,
    );
  }

  static Future<void> _createOutboxTable(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS send_outbox (
        id TEXT PRIMARY KEY,
        kind TEXT NOT NULL,
        target TEXT NOT NULL,
        payload TEXT NOT NULL,
        request_payload TEXT,
        attempts INTEGER NOT NULL DEFAULT 0,
        next_attempt_at INTEGER NOT NULL DEFAULT 0,
        last_error TEXT,
        created_at INTEGER NOT NULL
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_send_outbox_due '
      'ON send_outbox(next_attempt_at, created_at)',
    );
  }

  Future<void> close() async {
    await _db?.close();
    _db = null;
    _currentUser = null;
    appLog.info('db', 'account database closed');
  }

  Database get _safeDb {
    final db = _db;
    if (db == null) throw StateError('DbService.init() not called');
    return db;
  }

  String? get currentUsername => _currentUser;

  /// Снять консистентный snapshot SQLite для внешнего зашифрованного backup.
  /// WAL сначала checkpoint-ится, поэтому копия не зависит от наличия
  /// отдельного -wal файла после удаления приложения.
  Future<Uint8List> exportDatabaseSnapshot() async {
    final path = _dbPath;
    if (_db == null || path == null || _currentUser == null) {
      throw StateError('DbService.init() must be called before backup');
    }
    try {
      final checkpoint = await _safeDb.rawQuery(
        'PRAGMA wal_checkpoint(TRUNCATE)',
      );
      final busy = checkpoint.isEmpty
          ? 0
          : int.tryParse(checkpoint.first.values.first?.toString() ?? '') ?? 0;
      if (busy != 0) {
        throw StateError('Database is busy; backup was not created');
      }
    } catch (e) {
      appLog.error('storage', 'database WAL checkpoint failed: $e');
      rethrow;
    }
    final file = File(path);
    if (!await file.exists()) throw StateError('Local database is missing');
    final bytes = await file.readAsBytes();
    _validateDatabaseSnapshot(bytes);
    return bytes;
  }

  /// Безопасно заменить текущую SQLite-БД проверенным snapshot-ом.
  /// Проверка integrity_check проходит до закрытия боевой БД. После закрытия
  /// основной файл и sidecar-файлы перемещаются, а новый snapshot ставится
  /// rename-операцией. При неудаче старая копия возвращается автоматически.
  Future<void> restoreDatabaseSnapshot(Uint8List bytes) async {
    final path = _dbPath;
    final username = _currentUser;
    if (_db == null || path == null || username == null) {
      throw StateError('DbService.init() must be called before restore');
    }
    _validateDatabaseSnapshot(bytes);

    final directory = File(path).parent;
    final stamp = DateTime.now().microsecondsSinceEpoch.toString();
    final temp = File(p.join(directory.path, '.ghost_restore_$stamp.db'));
    final old = File(p.join(directory.path, '.ghost_before_restore_$stamp.db'));
    final sidecarSuffixes = const ['-wal', '-shm', '-journal'];
    final oldSidecars = <String, File>{};
    var databaseClosed = false;

    try {
      await temp.writeAsBytes(bytes, flush: true);
      final checkDb = await openDatabase(temp.path, readOnly: true);
      try {
        final integrity = await checkDb.rawQuery('PRAGMA integrity_check');
        final result = integrity.isEmpty
            ? null
            : integrity.first.values.first?.toString().toLowerCase();
        if (result != 'ok') {
          throw FormatException('SQLite integrity check failed');
        }
        final tables = await checkDb.rawQuery(
          "SELECT name FROM sqlite_master WHERE type = 'table'",
        );
        final names = tables
            .map((row) => row['name']?.toString())
            .whereType<String>()
            .toSet();
        const requiredTables = {
          'messages',
          'dialogs',
          'peerkeys',
          'filecache',
          'plaincache',
        };
        if (!requiredTables.every(names.contains)) {
          throw FormatException('Unsupported GhostChat database schema');
        }
      } finally {
        await checkDb.close();
      }

      await close();
      databaseClosed = true;
      final current = File(path);
      if (await current.exists()) await current.rename(old.path);
      for (final suffix in sidecarSuffixes) {
        final sidecar = File('$path$suffix');
        if (await sidecar.exists()) {
          final moved = File('${old.path}$suffix');
          await sidecar.rename(moved.path);
          oldSidecars[suffix] = moved;
        }
      }

      await temp.rename(path);
      await init(username);
    } catch (e) {
      if (databaseClosed || _db != null || _currentUser != null) {
        await close();
      }
      final current = File(path);
      if (await current.exists()) await current.delete();
      if (await old.exists()) await old.rename(path);
      for (final entry in oldSidecars.entries) {
        final restored = File('$path${entry.key}');
        if (await restored.exists()) await restored.delete();
        if (await entry.value.exists()) await entry.value.rename(restored.path);
      }
      if (databaseClosed) {
        try {
          await init(username);
        } catch (restoreError) {
          appLog.error(
            'storage',
            'database rollback reopen failed: $restoreError',
          );
        }
      }
      if (await temp.exists()) await temp.delete();
      rethrow;
    }

    try {
      if (await old.exists()) await old.delete();
    } catch (e) {
      appLog.warn('storage', 'old database backup cleanup failed: $e');
    }
    for (final sidecar in oldSidecars.values) {
      try {
        if (await sidecar.exists()) await sidecar.delete();
      } catch (e) {
        appLog.warn('storage', 'old database sidecar cleanup failed: $e');
      }
    }
  }

  static const _sqliteHeader = 'SQLite format 3\u0000';
  static const _maxDatabaseSnapshotBytes = 256 * 1024 * 1024;

  static void _validateDatabaseSnapshot(Uint8List bytes) {
    if (bytes.length < 100 || bytes.length > _maxDatabaseSnapshotBytes) {
      throw FormatException('Unsupported database snapshot size');
    }
    final header = utf8.decode(bytes.sublist(0, 16), allowMalformed: true);
    if (header != _sqliteHeader) {
      throw FormatException('Not a SQLite database snapshot');
    }
  }

  // ─── Messages ────────────────────────────────────────────────────────
  /// Upsert по (sid, peer). Если есть optimistic с temp_sid и приходит echo
  /// с реальным sid — caller должен сначала вызвать promoteOptimistic.
  Future<void> upsertMessage(StoredMessage m) async {
    await _safeDb.transaction((txn) async {
      final existing = await txn.query(
        'messages',
        columns: const ['read', 'delivered'],
        where: 'sid = ? AND peer = ?',
        whereArgs: [m.sid, m.peer],
        limit: 1,
      );
      final row = mergePersistedReceiptFlags(
        incoming: Map<String, Object?>.from(m.toMap()),
        existing: existing.isEmpty ? null : existing.first,
      );
      await txn.insert(
        'messages',
        row,
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    });
  }

  /// Загрузить последние `limit` сообщений для peer (показ: старые → новые).
  Future<List<StoredMessage>> getMessages(
    String peer, {
    int limit = 1000,
  }) async {
    // ORDER BY: chat_dm и chat_dm_sealed имеют независимые auto-increment id —
    // сортировка по sid смешивает порядок. Сортируем по unified TIMESTAMP:
    //   - legacy: created_at = ISO-строка "2026-..."  → strftime('%s', s)
    //   - sealed: created_at = unix-int "1700000000" → CAST(s AS INTEGER)
    // Эвристика: если строка начинается с цифры и без '-' в первых 4 символах —
    // unix-int, иначе ISO.
    //
    // ВАЖНО: LIMIT берёт ПОСЛЕДНИЕ N (подзапрос DESC+LIMIT), иначе при >N
    // сообщений в чате обрезались бы НОВЫЕ (баг «вижу историю только до …»).
    // Внешний запрос пересортировывает обратно ASC для показа снизу-вверх.
    const tsExpr = '''
        CASE
          WHEN created_at IS NULL THEN 4102444800           -- pending → конец (2100)
          WHEN created_at GLOB '[0-9]*' AND length(created_at) <= 11
            THEN CAST(created_at AS INTEGER)                -- unix-int (10 цифр)
          ELSE strftime('%s', created_at)                   -- ISO
        END''';
    final rows = await _safeDb.rawQuery(
      '''
      SELECT * FROM (
        SELECT * FROM messages WHERE peer = ?
        ORDER BY $tsExpr DESC, sid DESC
        LIMIT ?
      )
      ORDER BY $tsExpr ASC, sid ASC
    ''',
      [peer, limit],
    );
    return rows.map(StoredMessage.fromMap).toList();
  }

  /// Stores decrypted room messages in the account-specific database. Room
  /// IDs are namespaced by room type so a channel and group can share an ID.
  Future<void> upsertRoomMessages(
    String roomKey,
    List<Map<String, dynamic>> messages,
  ) async {
    if (messages.isEmpty) return;
    await _safeDb.transaction((txn) async {
      for (final message in messages) {
        await txn.insert('room_messages', {
          ...message,
          'room_key': roomKey,
          'from_me': message['from_me'] == true || message['from_me'] == 1
              ? 1
              : 0,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
    });
  }

  /// Atomically stores a DM bubble and its retryable send draft. A process
  /// death immediately after the tap therefore cannot lose the user's text.
  Future<void> enqueueDmText({
    required String id,
    required String peer,
    required Map<String, dynamic> payload,
    required StoredMessage optimisticMessage,
  }) async {
    await _safeDb.transaction((txn) async {
      await txn.insert(
        'messages',
        optimisticMessage.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      await txn.insert('send_outbox', {
        'id': id,
        'kind': 'dm_text',
        'target': peer,
        'payload': jsonEncode(payload),
        'created_at': DateTime.now().millisecondsSinceEpoch,
      }, conflictAlgorithm: ConflictAlgorithm.abort);
    });
  }

  /// Atomically stores a room bubble and its durable send draft.
  Future<void> enqueueRoomText({
    required String id,
    required String roomKey,
    required String target,
    required Map<String, dynamic> payload,
    required Map<String, dynamic> optimisticMessage,
  }) async {
    await _safeDb.transaction((txn) async {
      await txn.insert('room_messages', {
        ...optimisticMessage,
        'room_key': roomKey,
        'from_me': 1,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      await txn.insert('send_outbox', {
        'id': id,
        'kind': 'room_text',
        'target': target,
        'payload': jsonEncode(payload),
        'created_at': DateTime.now().millisecondsSinceEpoch,
      }, conflictAlgorithm: ConflictAlgorithm.abort);
    });
  }

  Future<List<OutboxEntry>> dueOutboxEntries({
    int nowMillis = 0,
    int limit = 20,
    String? kind,
  }) async {
    final now = nowMillis == 0
        ? DateTime.now().millisecondsSinceEpoch
        : nowMillis;
    final rows = await _safeDb.query(
      'send_outbox',
      where: kind == null
          ? 'next_attempt_at <= ?'
          : 'next_attempt_at <= ? AND kind = ?',
      whereArgs: kind == null ? [now] : [now, kind],
      orderBy: 'created_at ASC',
      limit: limit,
    );
    return rows.map(OutboxEntry.fromMap).toList(growable: false);
  }

  Future<void> saveOutboxRequest(String id, Map<String, dynamic> request) =>
      _safeDb
          .update(
            'send_outbox',
            {'request_payload': jsonEncode(request)},
            where: 'id = ?',
            whereArgs: [id],
          )
          .then((_) {});

  Future<void> clearOutboxRequest(String id) async {
    await _safeDb.update(
      'send_outbox',
      {'request_payload': null},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> scheduleOutboxRetry({
    required String id,
    required int attempts,
    required int nextAttemptAt,
    required String error,
  }) async {
    await _safeDb.update(
      'send_outbox',
      {
        'attempts': attempts,
        'next_attempt_at': nextAttemptAt,
        'last_error': error.length > 500 ? error.substring(0, 500) : error,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> deleteOutboxEntry(String id) async {
    await _safeDb.delete('send_outbox', where: 'id = ?', whereArgs: [id]);
  }

  Future<void> promoteRoomOptimistic({
    required String roomKey,
    required int temporaryId,
    required int messageId,
    required int createdAt,
  }) async {
    await _safeDb.transaction((txn) async {
      final alreadyReceived = await txn.query(
        'room_messages',
        columns: ['message_id'],
        where: 'room_key = ? AND message_id = ?',
        whereArgs: [roomKey, messageId],
        limit: 1,
      );
      if (alreadyReceived.isNotEmpty) {
        await txn.delete(
          'room_messages',
          where: 'room_key = ? AND message_id = ?',
          whereArgs: [roomKey, temporaryId],
        );
        return;
      }
      await txn.update(
        'room_messages',
        {
          'message_id': messageId,
          'created_at': createdAt,
          'pending': 0,
          'send_failed': 0,
        },
        where: 'room_key = ? AND message_id = ?',
        whereArgs: [roomKey, temporaryId],
      );
    });
  }

  Future<void> markRoomSendFailed(String roomKey, int messageId) async {
    await _safeDb.update(
      'room_messages',
      {'pending': 0, 'send_failed': 1},
      where: 'room_key = ? AND message_id = ?',
      whereArgs: [roomKey, messageId],
    );
  }

  Future<List<Map<String, Object?>>> getRoomMessages(String roomKey) async {
    final rows = await _safeDb.query(
      'room_messages',
      where: 'room_key = ?',
      whereArgs: [roomKey],
      orderBy: 'created_at ASC, message_id ASC',
    );
    return rows;
  }

  Future<int> lastRoomMessageId(String roomKey) async {
    final rows = await _safeDb.rawQuery(
      'SELECT COALESCE(MAX(CASE WHEN message_id > 0 THEN message_id ELSE 0 END), 0) AS last_id FROM room_messages WHERE room_key = ?',
      [roomKey],
    );
    final value = rows.isEmpty ? null : rows.first['last_id'];
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }

  Future<List<int>> pendingRoomDeliveryReceiptIds(String roomKey) async {
    final rows = await _safeDb.query(
      'room_messages',
      columns: ['message_id'],
      where: 'room_key = ? AND from_me = 0 AND delivered_ack_sent = 0',
      whereArgs: [roomKey],
      orderBy: 'message_id ASC',
    );
    return rows
        .map((row) => row['message_id'])
        .whereType<num>()
        .map((value) => value.toInt())
        .toList(growable: false);
  }

  Future<void> markRoomDeliveryReceiptsSent(
    String roomKey,
    List<int> messageIds,
  ) async {
    if (messageIds.isEmpty) return;
    await _safeDb.transaction((txn) async {
      for (final id in messageIds) {
        await txn.update(
          'room_messages',
          {'delivered_ack_sent': 1},
          where: 'room_key = ? AND message_id = ? AND from_me = 0',
          whereArgs: [roomKey, id],
        );
      }
    });
  }

  /// Найти optimistic-сообщение с tmp-sid и тем же контентом, перепривязать
  /// к реальному sid (когда HTTP /send вернул ответ или WS echo пришёл).
  Future<bool> promoteOptimistic({
    required String peer,
    required String tempSid,
    required int realSid,
    required dynamic createdAt,
  }) async {
    // На (peer, realSid) уже может лежать ФИНАЛЬНАЯ запись — WS-echo с реальным
    // sid пришёл раньше, чем мы успели promote. Тогда UPDATE optimistic→realSid
    // упал бы на UNIQUE constraint PRIMARY KEY (sid, peer) и оставил дубль.
    // Проверяем заранее: если финальная есть — удаляем НАШ optimistic (не апдейтим).
    final existing = await _safeDb.rawQuery(
      'SELECT 1 FROM messages WHERE peer = ? AND sid = ? '
      'AND (temp_sid IS NULL OR temp_sid != ?) LIMIT 1',
      [peer, realSid, tempSid],
    );
    if (existing.isNotEmpty) {
      await _safeDb.delete(
        'messages',
        where: 'peer = ? AND temp_sid = ?',
        whereArgs: [peer, tempSid],
      );
      return true;
    }
    try {
      final updated = await _safeDb.update(
        'messages',
        {
          'sid': realSid,
          'created_at': createdAt is int ? createdAt : createdAt?.toString(),
          'pending': 0,
          'temp_sid': null,
        },
        where: 'peer = ? AND temp_sid = ?',
        whereArgs: [peer, tempSid],
      );
      return updated > 0;
    } catch (_) {
      // Гонка: финальная запись появилась между проверкой и UPDATE → вместо
      // падения на UNIQUE просто удаляем optimistic-дубль.
      await _safeDb.delete(
        'messages',
        where: 'peer = ? AND temp_sid = ?',
        whereArgs: [peer, tempSid],
      );
      return true;
    }
  }

  /// Находит локальный pending-текст, для которого realtime echo пришёл
  /// раньше HTTP-ответа. Без этого гонка показывала временный и настоящий
  /// пузырь одновременно до следующего обновления истории.
  Future<String?> findPendingTextTempSid(String peer, String text) async {
    final rows = await _safeDb.query(
      'messages',
      columns: ['temp_sid'],
      where: 'peer = ? AND from_me = 1 AND pending = 1 AND text = ?',
      whereArgs: [peer, text],
      orderBy: 'sid DESC',
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return rows.first['temp_sid'] as String?;
  }

  Future<void> updateMessageFlags(
    String peer,
    int sid,
    Map<String, dynamic> patch,
  ) async {
    if (patch.isEmpty) return;
    await _safeDb.update(
      'messages',
      patch,
      where: 'sid = ? AND peer = ?',
      whereArgs: [sid, peer],
    );
  }

  Future<void> deleteMessagesByPeer(String peer) async {
    await _safeDb.delete('messages', where: 'peer = ?', whereArgs: [peer]);
  }

  /// Поиск по тексту во всех сообщениях. Возвращает совпадения с peer-ом
  /// (чтобы при тапе можно было открыть нужный чат).
  Future<List<StoredMessage>> searchMessages(
    String query, {
    int limit = 50,
  }) async {
    if (query.trim().isEmpty) return [];
    final rows = await _safeDb.query(
      'messages',
      where: 'deleted = 0 AND text LIKE ?',
      whereArgs: ['%${query.trim()}%'],
      orderBy: 'sid DESC',
      limit: limit,
    );
    return rows.map(StoredMessage.fromMap).toList();
  }

  /// Поиск диалогов локально по username / display_name.
  Future<List<StoredDialog>> searchDialogs(
    String query, {
    int limit = 20,
  }) async {
    if (query.trim().isEmpty) return [];
    final q = '%${query.trim().toLowerCase()}%';
    final rows = await _safeDb.query(
      'dialogs',
      where: 'LOWER(username) LIKE ? OR LOWER(display_name) LIKE ?',
      whereArgs: [q, q],
      limit: limit,
    );
    return rows.map(StoredDialog.fromMap).toList();
  }

  /// Проверить дубль по sid (для дедупа echo). Возвращает true если уже есть.
  Future<bool> messageExists(String peer, int sid) async {
    final r = await _safeDb.query(
      'messages',
      columns: ['sid'],
      where: 'sid = ? AND peer = ?',
      whereArgs: [sid, peer],
      limit: 1,
    );
    return r.isNotEmpty;
  }

  Future<StoredMessage?> getMessage(String peer, int sid) async {
    final rows = await _safeDb.query(
      'messages',
      where: 'sid = ? AND peer = ?',
      whereArgs: [sid, peer],
      limit: 1,
    );
    return rows.isEmpty ? null : StoredMessage.fromMap(rows.first);
  }

  // ─── Dialogs ─────────────────────────────────────────────────────────
  Future<void> upsertDialog(StoredDialog d) async {
    await _safeDb.insert(
      'dialogs',
      d.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<StoredDialog>> getDialogs() async {
    // last_at — TEXT ради совместимости со старыми БД, поэтому SQL-сортировка
    // ломается на смеси ISO-строк и числовых Unix-времён. Сортируем после
    // нормализации в Dart.
    final rows = await _safeDb.query('dialogs');
    final latestRows = await _safeDb.rawQuery(
      'SELECT peer, sid, created_at, from_me, pending, delivered, "read" '
      'FROM messages '
      'WHERE deleted = 0 AND created_at IS NOT NULL',
    );
    final latestMessageAt = <String, DateTime>{};
    final latestMessageByPeer = <String, Map<String, Object?>>{};
    for (final row in latestRows) {
      final peer = row['peer'] as String?;
      if (peer == null) continue;
      final at = dialogTimestamp(row['created_at']);
      if (at.millisecondsSinceEpoch <= 0) continue;
      final previous = latestMessageAt[peer];
      final previousSid = latestMessageByPeer[peer]?['sid'] as int? ?? 0;
      final sid = row['sid'] as int? ?? 0;
      if (previous == null ||
          at.isAfter(previous) ||
          (at.isAtSameMomentAs(previous) && sid > previousSid)) {
        latestMessageAt[peer] = at;
        latestMessageByPeer[peer] = row;
      }
    }

    // Кэш dialogs мог быть записан до появления сообщения, с null-временем
    // или со старым форматом. Для существующих локальных сообщений источник
    // истины — их created_at; так порядок не зависит от порядка строк в БД.
    final dialogs = rows.map(StoredDialog.fromMap).map((dialog) {
      final messageAt = latestMessageAt[dialog.username];
      if (messageAt == null) return dialog;
      final latestMessage = latestMessageByPeer[dialog.username]!;
      return StoredDialog(
        username: dialog.username,
        displayName: dialog.displayName,
        lastText: dialog.lastText,
        lastAt: messageAt.toUtc().toIso8601String(),
        lastFromMe: latestMessage['from_me'] == 1,
        unread: dialog.unread,
        lastMessagePending: latestMessage['pending'] == 1,
        lastMessageDelivered: latestMessage['delivered'] == 1,
        lastMessageRead: latestMessage['read'] == 1,
      );
    }).toList();
    dialogs.sort(
      (a, b) => dialogTimestamp(b.lastAt).compareTo(dialogTimestamp(a.lastAt)),
    );
    return dialogs;
  }

  Future<StoredDialog?> getDialog(String username) async {
    final r = await _safeDb.query(
      'dialogs',
      where: 'username = ?',
      whereArgs: [username],
      limit: 1,
    );
    return r.isEmpty ? null : StoredDialog.fromMap(r.first);
  }

  Future<void> deleteDialog(String username) async {
    await _safeDb.delete(
      'dialogs',
      where: 'username = ?',
      whereArgs: [username],
    );
  }

  Future<void> resetUnread(String username) async {
    await _safeDb.update(
      'dialogs',
      {'unread': 0},
      where: 'username = ?',
      whereArgs: [username],
    );
  }

  /// Реальное число непрочитанных входящих для пира — источник правды для
  /// badge (вместо дрейфующего счётчика-инкремента).
  Future<int> unreadCount(String username) async {
    final r = await _safeDb.query(
      'messages',
      columns: ['sid'],
      where: 'peer = ? AND from_me = 0 AND read = 0 AND deleted = 0',
      whereArgs: [username],
    );
    return r.length;
  }

  /// Пометить ВСЕ входящие пира прочитанными одним UPDATE — гарантирует, что
  /// бейдж (unreadCount по тем же условиям) обнулится при открытии чата, даже
  /// если часть строк не отрисовывается (контрол-фреймы/дубликаты/релеи).
  Future<int> markAllRead(String username) async {
    return _safeDb.update(
      'messages',
      {'read': 1},
      where: 'peer = ? AND from_me = 0 AND read = 0',
      whereArgs: [username],
    );
  }

  /// Re-open a dialog as unread locally. This is the inverse of markAllRead
  /// used by the chat-list selection menu; the server is not changed because
  /// this is a local inbox presentation flag.
  Future<int> markAllUnread(String username) async {
    return _safeDb.update(
      'messages',
      {'read': 0},
      where: 'peer = ? AND from_me = 0 AND deleted = 0',
      whereArgs: [username],
    );
  }

  /// sid первого непрочитанного входящего (в порядке времени) — граница для
  /// линии «Новое». null если непрочитанных нет. Звать ДО markChatRead.
  Future<int?> firstUnreadSid(String username) async {
    final r = await _safeDb.query(
      'messages',
      columns: ['sid'],
      where: 'peer = ? AND from_me = 0 AND read = 0 AND deleted = 0',
      whereArgs: [username],
      orderBy: 'created_at ASC',
      limit: 1,
    );
    return r.isEmpty ? null : r.first['sid'] as int;
  }

  // ─── PeerKeys (TOFU) ─────────────────────────────────────────────────
  Future<String?> getPinnedPub(String username) async {
    final r = await _safeDb.query(
      'peerkeys',
      columns: ['pub'],
      where: 'username = ? AND accepted = 1',
      whereArgs: [username],
      limit: 1,
    );
    return r.isEmpty ? null : r.first['pub'] as String;
  }

  Future<void> pinPub(
    String username,
    String pubB64, {
    bool accepted = true,
  }) async {
    await _safeDb.insert('peerkeys', {
      'username': username,
      'pub': pubB64,
      'first_seen': DateTime.now().toIso8601String(),
      'accepted': accepted ? 1 : 0,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<String?> getPinnedV2Identity(String username) async {
    final normalized = username.trim().toLowerCase();
    final rows = await _safeDb.query(
      'peeridentitykeys',
      columns: ['identity_pub'],
      where: 'username = ?',
      whereArgs: [normalized],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first['identity_pub'] as String?;
  }

  /// First-seen identity pin; never replaces an existing key. The returned
  /// value is the value that won the SQLite transaction, including races.
  Future<String?> pinV2IdentityIfAbsent(
    String username,
    String identityPub,
  ) async {
    final normalized = username.trim().toLowerCase();
    if (normalized.isEmpty || identityPub.isEmpty) return null;
    return _safeDb.transaction((txn) async {
      await txn.insert('peeridentitykeys', {
        'username': normalized,
        'identity_pub': identityPub,
        'first_seen': DateTime.now().toUtc().toIso8601String(),
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
      final rows = await txn.query(
        'peeridentitykeys',
        columns: ['identity_pub'],
        where: 'username = ?',
        whereArgs: [normalized],
        limit: 1,
      );
      return rows.isEmpty ? null : rows.first['identity_pub'] as String?;
    });
  }

  // ─── FileCache ───────────────────────────────────────────────────────
  Future<Uint8List?> getCachedFile(String fileId) async {
    try {
      final r = await _safeDb.query(
        'filecache',
        columns: ['bytes'],
        where: 'file_id = ?',
        whereArgs: [fileId],
        limit: 1,
      );
      if (r.isEmpty) return null;
      final value = r.first['bytes'];
      return value is Uint8List ? value : null;
    } catch (e) {
      // Старый кэш мог содержать BLOB больше CursorWindow. Удаляем только
      // эту запись: серверный файл будет скачан заново и уже не запишется
      // обратно в SQLite, если он крупный.
      appLog.warn('storage', 'drop unreadable encrypted cache $fileId: $e');
      await deleteCachedFile(fileId);
      return null;
    }
  }

  Future<void> cacheFile(String fileId, List<int> bytes, String? mime) async {
    if (bytes.length > _maxEncryptedCacheBytes) {
      await deleteCachedFile(fileId);
      return;
    }
    await _safeDb.insert('filecache', {
      'file_id': fileId,
      'bytes': Uint8List.fromList(bytes),
      'mime': mime,
      'cached_at': DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> deleteCachedFile(String fileId) async {
    await _safeDb.delete(
      'filecache',
      where: 'file_id = ?',
      whereArgs: [fileId],
    );
  }

  /// Расшифрованный кэш медиа. Храним plaintext отдельно: после первого
  /// успешного открытия изображение/аудио/файл не скачивается и не
  /// расшифровывается заново после перезапуска приложения.
  Future<Uint8List?> getCachedPlainFile(String fileId) async {
    final r = await _safeDb.query(
      'plaincache',
      columns: ['path', 'size'],
      where: 'file_id = ?',
      whereArgs: [fileId],
      limit: 1,
    );
    if (r.isEmpty) return null;
    final path = r.first['path'] as String?;
    final expectedSize = r.first['size'] as int?;
    if (path == null || expectedSize == null) return null;
    try {
      final file = File(path);
      if (!await file.exists()) {
        await deleteCachedPlainFile(fileId);
        return null;
      }
      final bytes = await file.readAsBytes();
      if (bytes.length != expectedSize) {
        await deleteCachedPlainFile(fileId);
        return null;
      }
      return bytes;
    } catch (e) {
      appLog.warn('storage', 'plain cache read failed $fileId: $e');
      await deleteCachedPlainFile(fileId);
      return null;
    }
  }

  Future<void> cachePlainFile(
    String fileId,
    List<int> bytes,
    String? mime,
  ) async {
    final dir = await _plainCacheDirectory();
    final target = File(p.join(dir.path, '$fileId.bin'));
    final temp = File(
      p.join(dir.path, '.$fileId.${DateTime.now().microsecondsSinceEpoch}.tmp'),
    );
    String? previousPath;
    final previous = await _safeDb.query(
      'plaincache',
      columns: ['path'],
      where: 'file_id = ?',
      whereArgs: [fileId],
      limit: 1,
    );
    if (previous.isNotEmpty) previousPath = previous.first['path'] as String?;
    try {
      await temp.writeAsBytes(bytes, flush: true);
      if (await target.exists()) await target.delete();
      await temp.rename(target.path);
      await _safeDb.insert('plaincache', {
        'file_id': fileId,
        'path': target.path,
        'size': bytes.length,
        'mime': mime,
        'cached_at': DateTime.now().millisecondsSinceEpoch,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      if (previousPath != null && previousPath != target.path) {
        final old = File(previousPath);
        if (await old.exists()) await old.delete();
      }
    } catch (_) {
      if (await temp.exists()) await temp.delete();
      rethrow;
    }
  }

  Future<void> deleteCachedPlainFile(String fileId) async {
    String? path;
    final rows = await _safeDb.query(
      'plaincache',
      columns: ['path'],
      where: 'file_id = ?',
      whereArgs: [fileId],
      limit: 1,
    );
    if (rows.isNotEmpty) path = rows.first['path'] as String?;
    await _safeDb.delete(
      'plaincache',
      where: 'file_id = ?',
      whereArgs: [fileId],
    );
    if (path != null) {
      try {
        final file = File(path);
        if (await file.exists()) await file.delete();
      } catch (e) {
        appLog.warn('storage', 'plain cache delete failed $fileId: $e');
      }
    }
  }

  Future<Directory> _plainCacheDirectory() async {
    final root = await getApplicationSupportDirectory();
    final account = (_currentUser ?? 'unknown').replaceAll(
      RegExp(r'[^A-Za-z0-9._-]'),
      '_',
    );
    final dir = Directory(p.join(root.path, 'ghost_plaincache', account));
    await dir.create(recursive: true);
    return dir;
  }

  /// Удаляет локальный кэш зашифрованных вложений серверных чатов.
  /// Сами сообщения и их file_payload остаются: при необходимости файл можно
  /// скачать заново с сервера. VACUUM нужен, иначе SQLite оставит занятые
  /// страницы внутри файла и экран хранилища покажет старый размер БД.
  Future<int> clearFileCache({String? preserveCategory}) async {
    String encryptedWhere = '1 = 1';
    String plainWhere = '1 = 1';
    final encryptedArgs = <Object?>[];
    final plainArgs = <Object?>[];
    switch (preserveCategory) {
      case 'photo':
        encryptedWhere = 'mime IS NULL OR mime NOT LIKE ?';
        plainWhere = 'mime IS NULL OR mime NOT LIKE ?';
        encryptedArgs.add('image/%');
        plainArgs.add('image/%');
      case 'video':
        encryptedWhere = 'mime IS NULL OR mime NOT LIKE ?';
        plainWhere = 'mime IS NULL OR mime NOT LIKE ?';
        encryptedArgs.add('video/%');
        plainArgs.add('video/%');
      case 'voice':
        encryptedWhere = 'mime IS NULL OR mime NOT LIKE ?';
        plainWhere = 'mime IS NULL OR mime NOT LIKE ?';
        encryptedArgs.add('audio/%');
        plainArgs.add('audio/%');
      case 'files':
        // Delete every media row, leaving MIME types that belong to Files.
        encryptedWhere = 'mime LIKE ? OR mime LIKE ? OR mime LIKE ?';
        plainWhere = 'mime LIKE ? OR mime LIKE ? OR mime LIKE ?';
        encryptedArgs.addAll(['image/%', 'video/%', 'audio/%']);
        plainArgs.addAll(['image/%', 'video/%', 'audio/%']);
      case 'db_overhead':
        // This category is database overhead, not a cache row.
        encryptedWhere = '0 = 1';
        plainWhere = '0 = 1';
    }
    final rows = await _safeDb.rawQuery(
      'SELECT COUNT(*) AS count FROM filecache WHERE $encryptedWhere',
      encryptedArgs,
    );
    final plainRows = await _safeDb.rawQuery(
      'SELECT path FROM plaincache WHERE $plainWhere',
      plainArgs,
    );
    final encryptedCount = (rows.first['count'] as int?) ?? 0;
    final plainPaths = plainRows
        .map((row) => row['path'] as String?)
        .whereType<String>()
        .toList();
    final plainCount = plainPaths.length;
    final count = encryptedCount + plainCount;
    if (encryptedCount > 0) {
      await _safeDb.delete(
        'filecache',
        where: encryptedWhere,
        whereArgs: encryptedArgs,
      );
    }
    if (plainCount > 0) {
      await _safeDb.delete(
        'plaincache',
        where: plainWhere,
        whereArgs: plainArgs,
      );
      for (final path in plainPaths) {
        try {
          final file = File(path);
          if (await file.exists()) await file.delete();
        } catch (e) {
          appLog.warn('storage', 'plain cache cleanup failed: $e');
        }
      }
    }
    try {
      await _safeDb.execute('VACUUM');
    } catch (_) {
      // VACUUM может быть временно занят параллельной записью; DELETE уже
      // выполнен, а размер файла пересчитается при следующем открытии БД.
    }
    appLog.info('storage', 'encrypted file cache cleared: $count files');
    return count;
  }

  /// Clears only cached files referenced by the selected conversations. The
  /// message rows and their encrypted file metadata remain intact, so a
  /// server-backed attachment can be downloaded again later.
  Future<int> clearFileCacheForPeers(
    Iterable<String> peers, {
    Set<String>? categories,
  }) async {
    final peerList = peers
        .where((peer) => peer.trim().isNotEmpty)
        .toSet()
        .toList();
    if (peerList.isEmpty || categories == null || categories.isEmpty) return 0;
    final placeholders = List.filled(peerList.length, '?').join(',');
    final rows = await _safeDb.rawQuery(
      'SELECT file_payload FROM messages WHERE peer IN ($placeholders) AND file_payload IS NOT NULL',
      peerList,
    );
    final fileIds = <String>{};
    for (final row in rows) {
      try {
        final payload = jsonDecode(row['file_payload'] as String);
        if (payload is Map && payload['file_id'] != null) {
          fileIds.add(payload['file_id'].toString());
        }
      } catch (_) {
        // A malformed attachment descriptor must not stop other cache cleanup.
      }
    }
    var removed = 0;
    for (final fileId in fileIds) {
      final cached = await _safeDb.query(
        'filecache',
        columns: ['mime'],
        where: 'file_id = ?',
        whereArgs: [fileId],
        limit: 1,
      );
      if (cached.isNotEmpty &&
          _cacheMimeMatches(cached.first['mime'] as String?, categories)) {
        await deleteCachedFile(fileId);
        removed++;
      }
      final plain = await _safeDb.query(
        'plaincache',
        columns: ['mime'],
        where: 'file_id = ?',
        whereArgs: [fileId],
        limit: 1,
      );
      if (plain.isNotEmpty &&
          _cacheMimeMatches(plain.first['mime'] as String?, categories)) {
        await deleteCachedPlainFile(fileId);
        removed++;
      }
    }
    return removed;
  }

  Future<int> clearFileCacheByCategories(Set<String> categories) async {
    if (categories.isEmpty) return 0;
    final rows = await _safeDb.rawQuery('SELECT file_id, mime FROM filecache');
    final plainRows = await _safeDb.rawQuery(
      'SELECT file_id, mime FROM plaincache',
    );
    var removed = 0;
    for (final row in rows) {
      if (!_cacheMimeMatches(row['mime'] as String?, categories)) continue;
      await deleteCachedFile(row['file_id'].toString());
      removed++;
    }
    for (final row in plainRows) {
      if (!_cacheMimeMatches(row['mime'] as String?, categories)) continue;
      await deleteCachedPlainFile(row['file_id'].toString());
      removed++;
    }
    return removed;
  }

  bool _cacheMimeMatches(String? mime, Set<String> categories) {
    final value = mime ?? '';
    if (value.startsWith('image/')) return categories.contains('photo');
    if (value.startsWith('video/')) return categories.contains('video');
    if (value.startsWith('audio/')) return categories.contains('voice');
    return categories.contains('files');
  }

  /// Разбивка занятого места по категориям для экрана "Хранилище" — реальные
  /// байты из filecache (сгруппированы по mime-префиксу), плюс отдельно
  /// "накладные расходы" самого файла БД (текст сообщений, индексы, схема) —
  /// размер файла на диске минус то, что уже посчитано как filecache-байты,
  /// чтобы не задваивать.
  Future<Map<String, int>> storageByCategory() async {
    final rows = await _safeDb.rawQuery(
      'SELECT mime, SUM(LENGTH(bytes)) AS total FROM filecache GROUP BY mime',
    );
    final plainRows = await _safeDb.rawQuery(
      'SELECT mime, SUM(size) AS total FROM plaincache GROUP BY mime',
    );
    var photo = 0, video = 0, voice = 0, files = 0;
    var databaseCacheTotal = 0;
    for (final r in rows) {
      final mime = r['mime'] as String? ?? '';
      final total = (r['total'] as int?) ?? 0;
      databaseCacheTotal += total;
      if (mime.startsWith('image/')) {
        photo += total;
      } else if (mime.startsWith('video/')) {
        video += total;
      } else if (mime.startsWith('audio/')) {
        voice += total;
      } else {
        files += total;
      }
    }
    for (final r in plainRows) {
      final mime = r['mime'] as String? ?? '';
      final total = (r['total'] as int?) ?? 0;
      if (mime.startsWith('image/')) {
        photo += total;
      } else if (mime.startsWith('video/')) {
        video += total;
      } else if (mime.startsWith('audio/')) {
        voice += total;
      } else {
        files += total;
      }
    }
    var dbFileSize = 0;
    final path = _dbPath;
    if (path != null) {
      try {
        dbFileSize = await File(path).length();
      } catch (_) {
        // Файл ещё не создан/недоступен — просто 0, не критично для UI.
      }
    }
    final overhead = (dbFileSize - databaseCacheTotal).clamp(0, dbFileSize);
    return {
      'photo': photo,
      'video': video,
      'voice': voice,
      'files': files,
      'db_overhead': overhead,
    };
  }
}
