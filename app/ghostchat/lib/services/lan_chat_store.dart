// LanChatStore — БД LAN-чатов. ПРИВЯЗАНА К УСТРОЙСТВУ, а не к аккаунту:
// отдельный файл lan_chats.db (не username_*.db как у DbService), поэтому
// история остаётся одной и той же при смене/выходе из аккаунта и доступна
// в гостевом режиме без единого обращения к серверу.
//
// StoredDialog.username для LAN-чатов хранит синтетический 'lan:<deviceId>' —
// этого достаточно, чтобы отличить их от серверных диалогов в общем списке
// (chat_list_screen.dart) без отдельного поля-дискриминатора.
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'db_service.dart' show StoredDialog;

const lanDialogPrefix = 'lan:';

class LanChatMessage {
  final String msgId;
  final String deviceId;
  final bool fromMe;
  final String text;
  final int createdAt; // unix seconds — как created_at в DbService

  LanChatMessage({
    required this.msgId,
    required this.deviceId,
    required this.fromMe,
    required this.text,
    required this.createdAt,
  });

  Map<String, dynamic> toMap() => {
        'msg_id': msgId,
        'device_id': deviceId,
        'from_me': fromMe ? 1 : 0,
        'text': text,
        'created_at': createdAt,
      };

  static LanChatMessage fromMap(Map<String, dynamic> m) => LanChatMessage(
        msgId: m['msg_id'] as String,
        deviceId: m['device_id'] as String,
        fromMe: (m['from_me'] as int) == 1,
        text: m['text'] as String? ?? '',
        createdAt: m['created_at'] as int,
      );
}

class LanChatStore {
  LanChatStore._();
  static final LanChatStore instance = LanChatStore._();

  Database? _db;
  final ValueNotifier<List<StoredDialog>> dialogsNotifier =
      ValueNotifier(const []);

  static int _nowSec() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

  Future<void> init() async {
    if (_db != null) return;
    final dir = await getApplicationSupportDirectory();
    final path = p.join(dir.path, 'lan_chats.db');
    _db = await openDatabase(
      path,
      version: 2,
      onCreate: (db, v) async {
        await db.execute('''
          CREATE TABLE lan_dialogs (
            device_id     TEXT PRIMARY KEY,
            display_name  TEXT NOT NULL,
            peer_pub      TEXT NOT NULL DEFAULT '',
            identity_pub  TEXT NOT NULL DEFAULT '',
            transport     TEXT NOT NULL DEFAULT 'lan',
            last_text     TEXT NOT NULL DEFAULT '',
            last_at       INTEGER,
            last_from_me  INTEGER NOT NULL DEFAULT 0,
            unread        INTEGER NOT NULL DEFAULT 0
          )
        ''');
        await db.execute('''
          CREATE TABLE lan_messages (
            msg_id        TEXT PRIMARY KEY,
            device_id     TEXT NOT NULL,
            from_me       INTEGER NOT NULL DEFAULT 0,
            text          TEXT NOT NULL DEFAULT '',
            created_at    INTEGER NOT NULL
          )
        ''');
        await db.execute(
            'CREATE INDEX idx_lan_msg_device ON lan_messages(device_id, created_at)');
      },
      onUpgrade: (db, oldV, newV) async {
        if (oldV < 2) {
          await db.execute(
              "ALTER TABLE lan_dialogs ADD COLUMN identity_pub TEXT NOT NULL DEFAULT ''");
        }
      },
    );
    await _reloadDialogs();
  }

  Database get _safeDb {
    final d = _db;
    if (d == null) throw StateError('LanChatStore не инициализирован');
    return d;
  }

  Future<void> _reloadDialogs() async {
    final rows = await _safeDb.query('lan_dialogs', orderBy: 'last_at DESC');
    dialogsNotifier.value = rows
        .map((r) => StoredDialog(
              username: '$lanDialogPrefix${r['device_id']}',
              displayName: r['display_name'] as String,
              lastText: r['last_text'] as String? ?? '',
              lastAt: r['last_at'],
              lastFromMe: (r['last_from_me'] as int? ?? 0) == 1,
              unread: r['unread'] as int? ?? 0,
            ))
        .toList();
  }

  /// TOFU-проверка: если для этого device_id уже есть закреплённая
  /// identity_pub и пришедшая НЕ совпадает — это либо переустановка чужого
  /// устройства с тем же UUID, либо подмена. Возвращает false → вызывающий
  /// код должен отклонить соединение, а не тихо переписать ключ.
  Future<bool> checkAndPinIdentity(String deviceId, String identityPubB64) async {
    if (identityPubB64.isEmpty) return true; // старые пиры без подписи — не блокируем
    final rows = await _safeDb.query('lan_dialogs',
        columns: ['identity_pub'], where: 'device_id = ?', whereArgs: [deviceId], limit: 1);
    if (rows.isEmpty || (rows.first['identity_pub'] as String? ?? '').isEmpty) {
      return true; // пока нечего сверять — запишется в createOrGetChat
    }
    return rows.first['identity_pub'] == identityPubB64;
  }

  /// Создать диалог при первом принятии/подключении, либо обновить
  /// публичный ключ пира, если он изменился/раньше был неизвестен.
  /// ВАЖНО: identity_pub закрепляется один раз и больше не переписывается
  /// молча — на смену identity надо явно звать checkAndPinIdentity заранее.
  Future<void> createOrGetChat({
    required String deviceId,
    required String displayName,
    String peerPubB64 = '',
    String identityPubB64 = '',
    String transport = 'lan',
  }) async {
    final existing = await _safeDb.query('lan_dialogs',
        where: 'device_id = ?', whereArgs: [deviceId], limit: 1);
    if (existing.isEmpty) {
      await _safeDb.insert('lan_dialogs', {
        'device_id': deviceId,
        'display_name': displayName,
        'peer_pub': peerPubB64,
        'identity_pub': identityPubB64,
        'transport': transport,
        'last_text': '',
        'last_at': _nowSec(),
        'last_from_me': 0,
        'unread': 0,
      });
    } else {
      final update = <String, Object?>{};
      if (peerPubB64.isNotEmpty) update['peer_pub'] = peerPubB64;
      final storedIdentity = existing.first['identity_pub'] as String? ?? '';
      if (storedIdentity.isEmpty && identityPubB64.isNotEmpty) {
        update['identity_pub'] = identityPubB64;
      }
      if (update.isNotEmpty) {
        await _safeDb.update('lan_dialogs', update,
            where: 'device_id = ?', whereArgs: [deviceId]);
      }
    }
    await _reloadDialogs();
  }

  Future<String?> getPeerPub(String deviceId) async {
    final rows = await _safeDb.query('lan_dialogs',
        columns: ['peer_pub'],
        where: 'device_id = ?',
        whereArgs: [deviceId],
        limit: 1);
    if (rows.isEmpty) return null;
    final v = rows.first['peer_pub'] as String?;
    return (v == null || v.isEmpty) ? null : v;
  }

  Future<String?> getDisplayName(String deviceId) async {
    final rows = await _safeDb.query('lan_dialogs',
        columns: ['display_name'],
        where: 'device_id = ?',
        whereArgs: [deviceId],
        limit: 1);
    if (rows.isEmpty) return null;
    return rows.first['display_name'] as String?;
  }

  Future<List<LanChatMessage>> getMessages(String deviceId) async {
    final rows = await _safeDb.query('lan_messages',
        where: 'device_id = ?', whereArgs: [deviceId], orderBy: 'created_at ASC');
    return rows.map(LanChatMessage.fromMap).toList();
  }

  Future<void> addMessage({
    required String deviceId,
    required String msgId,
    required bool fromMe,
    required String text,
    int? createdAtSec,
  }) async {
    final at = createdAtSec ?? _nowSec();
    await _safeDb.insert(
      'lan_messages',
      LanChatMessage(
        msgId: msgId,
        deviceId: deviceId,
        fromMe: fromMe,
        text: text,
        createdAt: at,
      ).toMap(),
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
    await _safeDb.rawUpdate(
      'UPDATE lan_dialogs SET last_text = ?, last_at = ?, last_from_me = ?, '
      'unread = unread + ? WHERE device_id = ?',
      [text, at, fromMe ? 1 : 0, fromMe ? 0 : 1, deviceId],
    );
    await _reloadDialogs();
  }

  Future<void> markRead(String deviceId) async {
    await _safeDb.update('lan_dialogs', {'unread': 0},
        where: 'device_id = ?', whereArgs: [deviceId]);
    await _reloadDialogs();
  }

  Future<void> clearChat(String deviceId) async {
    await _safeDb.delete('lan_messages',
        where: 'device_id = ?', whereArgs: [deviceId]);
    await _safeDb.delete('lan_dialogs',
        where: 'device_id = ?', whereArgs: [deviceId]);
    await _reloadDialogs();
  }
}

final lanChatStore = LanChatStore.instance;
