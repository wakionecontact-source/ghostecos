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
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

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
  final bool edited;
  final bool deleted;
  final bool delivered;
  final bool read;
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
    this.edited = false,
    this.deleted = false,
    this.delivered = false,
    this.read = false,
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
        'edited': edited ? 1 : 0,
        'deleted': deleted ? 1 : 0,
        'delivered': delivered ? 1 : 0,
        'read': read ? 1 : 0,
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
                (k, v) => MapEntry(k as String, List<String>.from(v as List)))
            : null,
        edited: (m['edited'] as int) == 1,
        deleted: (m['deleted'] as int) == 1,
        delivered: (m['delivered'] as int) == 1,
        read: (m['read'] as int) == 1,
        pending: (m['pending'] as int) == 1,
        tempSid: m['temp_sid'] as String?,
      );
}

class StoredDialog {
  final String username;          // или 'g:42' для группы
  final String displayName;
  final String lastText;
  final dynamic lastAt;             // ISO|unix-int|null
  final bool lastFromMe;
  final int unread;

  StoredDialog({
    required this.username,
    required this.displayName,
    this.lastText = '',
    this.lastAt,
    this.lastFromMe = false,
    this.unread = 0,
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

class DbService {
  DbService._();
  static final DbService instance = DbService._();

  Database? _db;
  String? _currentUser;

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
    if (kDebugMode) print('[DB] open $path');
    _db = await openDatabase(
      path,
      version: 1,
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
          CREATE TABLE filecache (
            file_id    TEXT PRIMARY KEY,
            bytes      BLOB NOT NULL,
            mime       TEXT,
            cached_at  INTEGER NOT NULL
          )
        ''');
        await db.execute('CREATE INDEX idx_file_cached ON filecache(cached_at)');
      },
    );
  }

  Future<void> close() async {
    await _db?.close();
    _db = null;
    _currentUser = null;
  }

  Database get _safeDb {
    final db = _db;
    if (db == null) throw StateError('DbService.init() not called');
    return db;
  }

  // ─── Messages ────────────────────────────────────────────────────────
  /// Upsert по (sid, peer). Если есть optimistic с temp_sid и приходит echo
  /// с реальным sid — caller должен сначала вызвать promoteOptimistic.
  Future<void> upsertMessage(StoredMessage m) async {
    await _safeDb.insert(
      'messages',
      m.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Загрузить все сообщения для peer (сортировка по sid ASC — старые сначала).
  Future<List<StoredMessage>> getMessages(String peer, {int limit = 500}) async {
    // ORDER BY: chat_dm и chat_dm_sealed имеют независимые auto-increment id —
    // сортировка по sid смешивает порядок. Сортируем по unified TIMESTAMP:
    //   - legacy: created_at = ISO-строка "2026-..."  → strftime('%s', s)
    //   - sealed: created_at = unix-int "1700000000" → CAST(s AS INTEGER)
    // Эвристика: если строка начинается с цифры и без '-' в первых 4 символах —
    // unix-int, иначе ISO.
    final rows = await _safeDb.rawQuery('''
      SELECT * FROM messages WHERE peer = ?
      ORDER BY
        CASE
          WHEN created_at IS NULL THEN 4102444800           -- pending → конец (2100)
          WHEN created_at GLOB '[0-9]*' AND length(created_at) <= 11
            THEN CAST(created_at AS INTEGER)                -- unix-int (10 цифр)
          ELSE strftime('%s', created_at)                   -- ISO
        END ASC,
        sid ASC
      LIMIT ?
    ''', [peer, limit]);
    return rows.map(StoredMessage.fromMap).toList();
  }

  /// Найти optimistic-сообщение с tmp-sid и тем же контентом, перепривязать
  /// к реальному sid (когда HTTP /send вернул ответ или WS echo пришёл).
  Future<bool> promoteOptimistic({
    required String peer,
    required String tempSid,
    required int realSid,
    required dynamic createdAt,
  }) async {
    // Если на (peer, realSid) уже лежит запись (старая дубль с сервера до
    // того как мы успели promote) — удаляем её, иначе UPDATE упадёт на
    // UNIQUE constraint PRIMARY KEY (sid, peer).
    // Удаляем ЛЮБУЮ запись с этим sid КРОМЕ нашего optimistic-target —
    // покрывает кейс когда там finalized из WS-echo, ИЛИ другой optimistic
    // с тем же sid (бывает при гонке двух последовательных send'ов).
    await _safeDb.delete(
      'messages',
      where: 'peer = ? AND sid = ? AND (temp_sid IS NULL OR temp_sid != ?)',
      whereArgs: [peer, realSid, tempSid],
    );
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
  }

  Future<void> updateMessageFlags(String peer, int sid, Map<String, dynamic> patch) async {
    if (patch.isEmpty) return;
    await _safeDb.update('messages', patch, where: 'sid = ? AND peer = ?', whereArgs: [sid, peer]);
  }

  Future<void> deleteMessagesByPeer(String peer) async {
    await _safeDb.delete('messages', where: 'peer = ?', whereArgs: [peer]);
  }

  /// Поиск по тексту во всех сообщениях. Возвращает совпадения с peer-ом
  /// (чтобы при тапе можно было открыть нужный чат).
  Future<List<StoredMessage>> searchMessages(String query, {int limit = 50}) async {
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
  Future<List<StoredDialog>> searchDialogs(String query, {int limit = 20}) async {
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
    final r = await _safeDb.query('messages',
        columns: ['sid'], where: 'sid = ? AND peer = ?', whereArgs: [sid, peer], limit: 1);
    return r.isNotEmpty;
  }

  // ─── Dialogs ─────────────────────────────────────────────────────────
  Future<void> upsertDialog(StoredDialog d) async {
    await _safeDb.insert('dialogs', d.toMap(), conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<List<StoredDialog>> getDialogs() async {
    final rows = await _safeDb.query('dialogs', orderBy: 'last_at DESC');
    return rows.map(StoredDialog.fromMap).toList();
  }

  Future<StoredDialog?> getDialog(String username) async {
    final r = await _safeDb
        .query('dialogs', where: 'username = ?', whereArgs: [username], limit: 1);
    return r.isEmpty ? null : StoredDialog.fromMap(r.first);
  }

  Future<void> deleteDialog(String username) async {
    await _safeDb.delete('dialogs', where: 'username = ?', whereArgs: [username]);
  }

  Future<void> resetUnread(String username) async {
    await _safeDb.update('dialogs', {'unread': 0},
        where: 'username = ?', whereArgs: [username]);
  }

  // ─── PeerKeys (TOFU) ─────────────────────────────────────────────────
  Future<String?> getPinnedPub(String username) async {
    final r = await _safeDb.query('peerkeys',
        columns: ['pub'], where: 'username = ? AND accepted = 1', whereArgs: [username], limit: 1);
    return r.isEmpty ? null : r.first['pub'] as String;
  }

  Future<void> pinPub(String username, String pubB64, {bool accepted = true}) async {
    await _safeDb.insert(
      'peerkeys',
      {
        'username': username,
        'pub': pubB64,
        'first_seen': DateTime.now().toIso8601String(),
        'accepted': accepted ? 1 : 0,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  // ─── FileCache ───────────────────────────────────────────────────────
  Future<Uint8List?> getCachedFile(String fileId) async {
    final r = await _safeDb.query('filecache',
        columns: ['bytes'], where: 'file_id = ?', whereArgs: [fileId], limit: 1);
    if (r.isEmpty) return null;
    return r.first['bytes'] as Uint8List;
  }

  Future<void> cacheFile(String fileId, List<int> bytes, String? mime) async {
    await _safeDb.insert(
      'filecache',
      {
        'file_id': fileId,
        'bytes': Uint8List.fromList(bytes),
        'mime': mime,
        'cached_at': DateTime.now().millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> deleteCachedFile(String fileId) async {
    await _safeDb.delete('filecache', where: 'file_id = ?', whereArgs: [fileId]);
  }
}
