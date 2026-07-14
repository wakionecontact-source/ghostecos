// BookmarkStore — «Избранное» + пользовательские закладки. ПРИВЯЗАНО К
// АККАУНТУ (как DbService: bookmarks_<username>.db), а не к устройству —
// у каждого аккаунта своё "Избранное", как и должно быть. Для гостя — свой
// фиксированный файл (гость без сервера, но "Избранное" всё равно должно
// быть). Чисто локальное хранилище, ничего не шлётся в сеть.
//
// "Избранное" — специальная запись с id='default': всегда существует,
// нельзя удалить, нельзя переименовать. Остальные закладки создаются через
// карандаш в списке чатов и могут быть переименованы/удалены как угодно.
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';
import 'db_service.dart' show StoredDialog;

const bookmarkDialogPrefix = 'bm:';
const defaultBookmarkId = 'default';
const defaultBookmarkName = 'Избранное';
const _maxFileBytes = 25 * 1024 * 1024; // 25MB — локальный SQLite, не сервер

class BookmarkInfo {
  final String id;
  final String name;
  final bool isDefault;
  const BookmarkInfo({required this.id, required this.name, required this.isDefault});
}

class BookmarkMessage {
  final String id;
  final String bookmarkId;
  final String text;
  final String? fileName;
  final String? fileMime;
  final Uint8List? fileBytes;
  final int createdAt; // unix seconds
  final String? reaction; // как в ЛС/LAN — свой Twemoji-маркер на заметке

  BookmarkMessage({
    required this.id,
    required this.bookmarkId,
    this.text = '',
    this.fileName,
    this.fileMime,
    this.fileBytes,
    required this.createdAt,
    this.reaction,
  });

  bool get hasFile => fileName != null && fileBytes != null;

  static BookmarkMessage fromMap(Map<String, dynamic> m) => BookmarkMessage(
        id: m['id'] as String,
        bookmarkId: m['bookmark_id'] as String,
        text: m['text'] as String? ?? '',
        fileName: m['file_name'] as String?,
        fileMime: m['file_mime'] as String?,
        fileBytes: m['file_bytes'] as Uint8List?,
        createdAt: m['created_at'] as int,
        reaction: m['reaction'] as String?,
      );
}

class BookmarkStore {
  BookmarkStore._();
  static final BookmarkStore instance = BookmarkStore._();

  Database? _db;
  String? _scope;
  final ValueNotifier<List<StoredDialog>> dialogsNotifier = ValueNotifier(const []);

  static int _nowSec() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

  /// [scopeKey] — username аккаунта, или 'guest' для гостя. Отдельный файл
  /// на каждый scope, как `ghost_$username.db` у DbService.
  Future<void> init(String scopeKey) async {
    if (_db != null && _scope == scopeKey) return;
    await _db?.close();
    _db = null;
    _scope = scopeKey;
    final dir = await getApplicationSupportDirectory();
    final path = p.join(dir.path, 'bookmarks_$scopeKey.db');
    _db = await openDatabase(
      path,
      version: 2,
      onCreate: (db, v) async {
        await db.execute('''
          CREATE TABLE bookmarks (
            id          TEXT PRIMARY KEY,
            name        TEXT NOT NULL,
            is_default  INTEGER NOT NULL DEFAULT 0,
            last_text   TEXT NOT NULL DEFAULT '',
            last_at     INTEGER,
            unread      INTEGER NOT NULL DEFAULT 0
          )
        ''');
        await db.execute('''
          CREATE TABLE bookmark_messages (
            id           TEXT PRIMARY KEY,
            bookmark_id  TEXT NOT NULL,
            text         TEXT NOT NULL DEFAULT '',
            file_name    TEXT,
            file_mime    TEXT,
            file_bytes   BLOB,
            created_at   INTEGER NOT NULL,
            reaction     TEXT
          )
        ''');
        await db.execute(
            'CREATE INDEX idx_bm_msg ON bookmark_messages(bookmark_id, created_at)');
      },
      onUpgrade: (db, oldV, newV) async {
        if (oldV < 2) {
          await db.execute('ALTER TABLE bookmark_messages ADD COLUMN reaction TEXT');
        }
      },
    );
    await _ensureDefault();
    await _reloadDialogs();
  }

  Database get _safeDb {
    final d = _db;
    if (d == null) throw StateError('BookmarkStore не инициализирован');
    return d;
  }

  Future<void> _ensureDefault() async {
    final rows = await _safeDb.query('bookmarks',
        where: 'id = ?', whereArgs: [defaultBookmarkId], limit: 1);
    if (rows.isEmpty) {
      await _safeDb.insert('bookmarks', {
        'id': defaultBookmarkId,
        'name': defaultBookmarkName,
        'is_default': 1,
        'last_text': '',
        'last_at': _nowSec(),
        'unread': 0,
      });
    }
  }

  Future<void> _reloadDialogs() async {
    final rows = await _safeDb.query('bookmarks', orderBy: 'is_default DESC, last_at DESC');
    dialogsNotifier.value = rows
        .map((r) => StoredDialog(
              username: '$bookmarkDialogPrefix${r['id']}',
              displayName: r['name'] as String,
              lastText: r['last_text'] as String? ?? '',
              lastAt: r['last_at'],
              lastFromMe: true,
              unread: 0,
            ))
        .toList();
  }

  Future<List<BookmarkInfo>> getBookmarks() async {
    final rows = await _safeDb.query('bookmarks', orderBy: 'is_default DESC, name ASC');
    return rows
        .map((r) => BookmarkInfo(
              id: r['id'] as String,
              name: r['name'] as String,
              isDefault: (r['is_default'] as int? ?? 0) == 1,
            ))
        .toList();
  }

  Future<String?> getName(String bookmarkId) async {
    final rows = await _safeDb.query('bookmarks',
        columns: ['name'], where: 'id = ?', whereArgs: [bookmarkId], limit: 1);
    if (rows.isEmpty) return null;
    return rows.first['name'] as String?;
  }

  Future<String> createBookmark(String name) async {
    final id = const Uuid().v4();
    await _safeDb.insert('bookmarks', {
      'id': id,
      'name': name.trim().isEmpty ? 'Закладка' : name.trim(),
      'is_default': 0,
      'last_text': '',
      'last_at': _nowSec(),
      'unread': 0,
    });
    await _reloadDialogs();
    return id;
  }

  Future<bool> renameBookmark(String id, String name) async {
    if (id == defaultBookmarkId) return false; // "Избранное" — имя фиксировано
    if (name.trim().isEmpty) return false;
    await _safeDb.update('bookmarks', {'name': name.trim()},
        where: 'id = ?', whereArgs: [id]);
    await _reloadDialogs();
    return true;
  }

  Future<bool> deleteBookmark(String id) async {
    if (id == defaultBookmarkId) return false; // нельзя удалить "Избранное"
    await _safeDb.delete('bookmark_messages', where: 'bookmark_id = ?', whereArgs: [id]);
    await _safeDb.delete('bookmarks', where: 'id = ?', whereArgs: [id]);
    await _reloadDialogs();
    return true;
  }

  Future<List<BookmarkMessage>> getMessages(String bookmarkId) async {
    final rows = await _safeDb.query('bookmark_messages',
        where: 'bookmark_id = ?', whereArgs: [bookmarkId], orderBy: 'created_at ASC');
    return rows.map(BookmarkMessage.fromMap).toList();
  }

  /// null text ок если есть файл (сообщение = просто файл, без подписи).
  Future<void> addMessage({
    required String bookmarkId,
    String text = '',
    String? fileName,
    String? fileMime,
    Uint8List? fileBytes,
  }) async {
    if (fileBytes != null && fileBytes.length > _maxFileBytes) {
      throw StateError('Файл больше 25MB — локальное хранилище не резиновое');
    }
    final id = const Uuid().v4();
    final at = _nowSec();
    await _safeDb.insert('bookmark_messages', {
      'id': id,
      'bookmark_id': bookmarkId,
      'text': text,
      'file_name': fileName,
      'file_mime': fileMime,
      'file_bytes': fileBytes,
      'created_at': at,
    });
    final preview = text.isNotEmpty ? text : (fileName != null ? '📎 $fileName' : '');
    await _safeDb.update('bookmarks', {'last_text': preview, 'last_at': at},
        where: 'id = ?', whereArgs: [bookmarkId]);
    await _reloadDialogs();
  }

  Future<void> deleteMessage(String messageId, String bookmarkId) async {
    await _safeDb.delete('bookmark_messages', where: 'id = ?', whereArgs: [messageId]);
    await _reloadDialogs();
  }

  /// Тап тем же эмодзи повторно — снимает реакцию (toggle), как в ЛС/LAN.
  Future<void> setReaction(String messageId, String emoji) async {
    final rows = await _safeDb.query('bookmark_messages',
        columns: ['reaction'], where: 'id = ?', whereArgs: [messageId], limit: 1);
    final current = rows.isNotEmpty ? rows.first['reaction'] as String? : null;
    await _safeDb.update('bookmark_messages', {'reaction': current == emoji ? null : emoji},
        where: 'id = ?', whereArgs: [messageId]);
  }
}
