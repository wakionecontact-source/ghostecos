// LanChatStore — БД LAN-чатов. ПРИВЯЗАНА К УСТРОЙСТВУ, а не к аккаунту:
// отдельный файл lan_chats.db (не username_*.db как у DbService), поэтому
// история остаётся одной и той же при смене/выходе из аккаунта и доступна
// в гостевом режиме без единого обращения к серверу.
//
// StoredDialog.username для LAN-чатов хранит синтетический 'lan:<deviceId>' —
// этого достаточно, чтобы отличить их от серверных диалогов в общем списке
// (chat_list_screen.dart) без отдельного поля-дискриминатора.
import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'db_service.dart' show StoredDialog;
import '../core/local/app_logger.dart';

const lanDialogPrefix = 'lan:';

/// Устройство, с которым когда-либо был обмен ключами (принято) — для
/// списка в LanScanScreen, живёт независимо от истории сообщений/чата.
class LanKnownDevice {
  final String deviceId;
  final String displayName;
  final int? acceptedAt; // unix seconds — момент первого рукопожатия
  final String
  transport; // 'lan' | 'bluetooth' | 'wifiDirect' — как узнали изначально
  const LanKnownDevice({
    required this.deviceId,
    required this.displayName,
    this.acceptedAt,
    this.transport = 'lan',
  });
}

/// Статус СВОЕГО сообщения — зеркало серверного чата (chat_screen.dart
/// _ticks), но БЕЗ промежуточной "дискеты" ("на сервере, не подтверждено
/// доставкой") — тут сервера-посредника нет, только 3 состояния.
enum LanMsgStatus { queued, delivered, read }

class LanChatMessage {
  final String msgId;
  final String deviceId;
  final bool fromMe;
  final String text;
  final int createdAt; // unix seconds — как created_at в DbService
  final String? fileName;
  final String? fileMime;
  final Uint8List? fileBytes;
  final String? replyToMsgId;
  final String? replyPreview;

  /// true — создано локально, но ещё не ушло по проводу (пир был офлайн).
  /// Флашится автоматически при реконнекте (см. MainShell).
  final bool queued;
  final bool delivered; // пришёл __ack__ от пира
  final bool read; // пришёл __seen__ от пира
  /// Своя реакция на сообщение (Twemoji-набор, как в ЛС) — ЛОКАЛЬНАЯ, по
  /// проводу пиру пока не уходит (нет отдельного wire-события для неё).
  final String? reaction;

  LanChatMessage({
    required this.msgId,
    required this.deviceId,
    required this.fromMe,
    required this.text,
    required this.createdAt,
    this.fileName,
    this.fileMime,
    this.fileBytes,
    this.replyToMsgId,
    this.replyPreview,
    this.queued = false,
    this.delivered = false,
    this.read = false,
    this.reaction,
  });

  bool get hasFile => fileName != null && fileBytes != null;

  LanMsgStatus get status => read
      ? LanMsgStatus.read
      : (delivered ? LanMsgStatus.delivered : LanMsgStatus.queued);

  Map<String, dynamic> toMap() => {
    'msg_id': msgId,
    'device_id': deviceId,
    'from_me': fromMe ? 1 : 0,
    'text': text,
    'created_at': createdAt,
    'file_name': fileName,
    'file_mime': fileMime,
    'file_bytes': fileBytes,
    'reply_to_msg_id': replyToMsgId,
    'reply_preview': replyPreview,
    'queued': queued ? 1 : 0,
    'is_delivered': delivered ? 1 : 0,
    'is_read': read ? 1 : 0,
    'reaction': reaction,
  };

  static LanChatMessage fromMap(Map<String, dynamic> m) => LanChatMessage(
    msgId: m['msg_id'] as String,
    deviceId: m['device_id'] as String,
    fromMe: (m['from_me'] as int) == 1,
    text: m['text'] as String? ?? '',
    createdAt: m['created_at'] as int,
    fileName: m['file_name'] as String?,
    fileMime: m['file_mime'] as String?,
    fileBytes: m['file_bytes'] as Uint8List?,
    replyToMsgId: m['reply_to_msg_id'] as String?,
    replyPreview: m['reply_preview'] as String?,
    queued: (m['queued'] as int? ?? 0) == 1,
    delivered: (m['is_delivered'] as int? ?? 0) == 1,
    read: (m['is_read'] as int? ?? 0) == 1,
    reaction: m['reaction'] as String?,
  );
}

class LanChatStore {
  LanChatStore._();
  static final LanChatStore instance = LanChatStore._();

  Database? _db;
  String? _dbPath;
  final ValueNotifier<List<StoredDialog>> dialogsNotifier = ValueNotifier(
    const [],
  );

  /// Все устройства, с которыми когда-либо обменялись рукопожатием — не
  /// только те, что "принял в этой сессии" (для LanScanScreen).
  final ValueNotifier<List<LanKnownDevice>> knownDevicesNotifier =
      ValueNotifier(const []);

  static int _nowSec() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

  Future<void> init() async {
    if (_db != null) return;
    final dir = await getApplicationSupportDirectory();
    final path = p.join(dir.path, 'lan_chats.db');
    _dbPath = path;
    _db = await openDatabase(
      path,
      version: 7,
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
            unread        INTEGER NOT NULL DEFAULT 0,
            accepted_at   INTEGER
          )
        ''');
        await db.execute('''
          CREATE TABLE lan_messages (
            msg_id        TEXT PRIMARY KEY,
            device_id     TEXT NOT NULL,
            from_me       INTEGER NOT NULL DEFAULT 0,
            text          TEXT NOT NULL DEFAULT '',
            created_at    INTEGER NOT NULL,
            file_name     TEXT,
            file_mime     TEXT,
            file_bytes    BLOB,
            queued        INTEGER NOT NULL DEFAULT 0,
            is_delivered  INTEGER NOT NULL DEFAULT 0,
            is_read       INTEGER NOT NULL DEFAULT 0,
            reaction      TEXT,
            reply_to_msg_id TEXT,
            reply_preview TEXT
          )
        ''');
        await db.execute(
          'CREATE INDEX idx_lan_msg_device ON lan_messages(device_id, created_at)',
        );
      },
      onUpgrade: (db, oldV, newV) async {
        if (oldV < 2) {
          await db.execute(
            "ALTER TABLE lan_dialogs ADD COLUMN identity_pub TEXT NOT NULL DEFAULT ''",
          );
        }
        if (oldV < 3) {
          await db.execute(
            'ALTER TABLE lan_dialogs ADD COLUMN accepted_at INTEGER',
          );
          // Для уже существующих пар точного момента рукопожатия не знаем —
          // берём last_at как лучшее приближение (когда чат создался).
          await db.execute(
            'UPDATE lan_dialogs SET accepted_at = last_at WHERE accepted_at IS NULL',
          );
        }
        if (oldV < 4) {
          await db.execute(
            'ALTER TABLE lan_messages ADD COLUMN file_name TEXT',
          );
          await db.execute(
            'ALTER TABLE lan_messages ADD COLUMN file_mime TEXT',
          );
          await db.execute(
            'ALTER TABLE lan_messages ADD COLUMN file_bytes BLOB',
          );
        }
        if (oldV < 5) {
          await db.execute(
            'ALTER TABLE lan_messages ADD COLUMN queued INTEGER NOT NULL DEFAULT 0',
          );
          await db.execute(
            'ALTER TABLE lan_messages ADD COLUMN is_delivered INTEGER NOT NULL DEFAULT 0',
          );
          await db.execute(
            'ALTER TABLE lan_messages ADD COLUMN is_read INTEGER NOT NULL DEFAULT 0',
          );
          // Старые сообщения были отправлены/приняты ДО этой фичи — считаем
          // их доставленными (не будем задним числом гонять статус по немым
          // историческим строкам).
          await db.execute(
            'UPDATE lan_messages SET is_delivered = 1 WHERE from_me = 1',
          );
        }
        if (oldV < 6) {
          await db.execute('ALTER TABLE lan_messages ADD COLUMN reaction TEXT');
        }
        if (oldV < 7) {
          await db.execute(
            'ALTER TABLE lan_messages ADD COLUMN reply_to_msg_id TEXT',
          );
          await db.execute(
            'ALTER TABLE lan_messages ADD COLUMN reply_preview TEXT',
          );
        }
      },
    );
    await _reloadDialogs();
    appLog.info('storage', 'LAN chat database opened');
  }

  Database get _safeDb {
    final d = _db;
    if (d == null) throw StateError('LanChatStore не инициализирован');
    return d;
  }

  Future<void> _reloadDialogs() async {
    final rows = await _safeDb.query('lan_dialogs', orderBy: 'last_at DESC');
    dialogsNotifier.value = rows
        .map(
          (r) => StoredDialog(
            username: '$lanDialogPrefix${r['device_id']}',
            displayName: r['display_name'] as String,
            lastText: r['last_text'] as String? ?? '',
            lastAt: r['last_at'],
            lastFromMe: (r['last_from_me'] as int? ?? 0) == 1,
            unread: r['unread'] as int? ?? 0,
          ),
        )
        .toList();
    final known =
        rows
            .map(
              (r) => LanKnownDevice(
                deviceId: r['device_id'] as String,
                displayName: r['display_name'] as String,
                acceptedAt: r['accepted_at'] as int?,
                transport: r['transport'] as String? ?? 'lan',
              ),
            )
            .toList()
          ..sort((a, b) => (b.acceptedAt ?? 0).compareTo(a.acceptedAt ?? 0));
    knownDevicesNotifier.value = known;
  }

  /// TOFU-проверка: если для этого device_id уже есть закреплённая
  /// identity_pub и пришедшая НЕ совпадает — это либо переустановка чужого
  /// устройства с тем же UUID, либо подмена. Возвращает false → вызывающий
  /// код должен отклонить соединение, а не тихо переписать ключ.
  Future<bool> checkAndPinIdentity(
    String deviceId,
    String identityPubB64,
  ) async {
    if (identityPubB64.isEmpty)
      return true; // старые пиры без подписи — не блокируем
    final rows = await _safeDb.query(
      'lan_dialogs',
      columns: ['identity_pub'],
      where: 'device_id = ?',
      whereArgs: [deviceId],
      limit: 1,
    );
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
    // Раньше тут был отдельный query-затем-insert — с двух конкурентных
    // вызовов для одного device_id (напр. LAN и Wi-Fi Direct сигналы
    // приходят в узком окне почти одновременно, см. LocalHub._onRawRequest)
    // оба видели "записи нет" и оба пытались insert, второй падал на
    // UNIQUE-constraint (device_id — PRIMARY KEY), роняя весь accept-флоу.
    // INSERT OR IGNORE атомарен на уровне БД — гонки не будет, "проигравший"
    // просто ничего не вставляет, а последующий update ниже всё равно
    // дозаполнит нужные поля у уже существующей строки.
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
      'accepted_at': _nowSec(),
    }, conflictAlgorithm: ConflictAlgorithm.ignore);

    final existing = await _safeDb.query(
      'lan_dialogs',
      where: 'device_id = ?',
      whereArgs: [deviceId],
      limit: 1,
    );
    if (existing.isNotEmpty) {
      final update = <String, Object?>{};
      if (peerPubB64.isNotEmpty) update['peer_pub'] = peerPubB64;
      final storedIdentity = existing.first['identity_pub'] as String? ?? '';
      if (storedIdentity.isEmpty && identityPubB64.isNotEmpty) {
        update['identity_pub'] = identityPubB64;
      }
      if (update.isNotEmpty) {
        await _safeDb.update(
          'lan_dialogs',
          update,
          where: 'device_id = ?',
          whereArgs: [deviceId],
        );
      }
    }
    await _reloadDialogs();
  }

  Future<String?> getPeerPub(String deviceId) async {
    final rows = await _safeDb.query(
      'lan_dialogs',
      columns: ['peer_pub'],
      where: 'device_id = ?',
      whereArgs: [deviceId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final v = rows.first['peer_pub'] as String?;
    return (v == null || v.isEmpty) ? null : v;
  }

  Future<String?> getDisplayName(String deviceId) async {
    final rows = await _safeDb.query(
      'lan_dialogs',
      columns: ['display_name'],
      where: 'device_id = ?',
      whereArgs: [deviceId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return rows.first['display_name'] as String?;
  }

  Future<List<LanChatMessage>> getMessages(String deviceId) async {
    final rows = await _safeDb.query(
      'lan_messages',
      where: 'device_id = ?',
      whereArgs: [deviceId],
      orderBy: 'created_at ASC',
    );
    return rows.map(LanChatMessage.fromMap).toList();
  }

  Future<void> addMessage({
    required String deviceId,
    required String msgId,
    required bool fromMe,
    String text = '',
    int? createdAtSec,
    String? fileName,
    String? fileMime,
    Uint8List? fileBytes,
    String? replyToMsgId,
    String? replyPreview,
    bool queued = false,
  }) async {
    appLog.info(
      fileName == null ? 'msg' : 'file',
      'LAN ${fromMe ? 'outgoing' : 'incoming'} ${fileName == null ? 'message' : 'file'} '
      'device=$deviceId id=$msgId',
    );
    final at = createdAtSec ?? _nowSec();
    await _safeDb.insert(
      'lan_messages',
      LanChatMessage(
        msgId: msgId,
        deviceId: deviceId,
        fromMe: fromMe,
        text: text,
        createdAt: at,
        fileName: fileName,
        fileMime: fileMime,
        fileBytes: fileBytes,
        replyToMsgId: replyToMsgId,
        replyPreview: replyPreview,
        queued: queued,
      ).toMap(),
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
    final preview = text.isNotEmpty
        ? text
        : (fileName != null ? '📎 $fileName' : '');
    await _safeDb.rawUpdate(
      'UPDATE lan_dialogs SET last_text = ?, last_at = ?, last_from_me = ?, '
      'unread = unread + ? WHERE device_id = ?',
      [preview, at, fromMe ? 1 : 0, fromMe ? 0 : 1, deviceId],
    );
    await _reloadDialogs();
  }

  /// Сообщения, созданные локально, пока пир был офлайн — ждут флаша при
  /// реконнекте (см. MainShell._flushQueuedLanMessages).
  Future<List<LanChatMessage>> getQueuedMessages(String deviceId) async {
    final rows = await _safeDb.query(
      'lan_messages',
      where: 'device_id = ? AND queued = 1',
      whereArgs: [deviceId],
      orderBy: 'created_at ASC',
    );
    return rows.map(LanChatMessage.fromMap).toList();
  }

  /// Сообщение реально ушло по проводу — снимаем queued (не меняет
  /// delivered/read, это отдельные события от __ack__/__seen__).
  Future<void> markSent(String deviceId, String msgId) async {
    await _safeDb.update(
      'lan_messages',
      {'queued': 0},
      where: 'device_id = ? AND msg_id = ?',
      whereArgs: [deviceId, msgId],
    );
    await _reloadDialogs();
  }

  /// Пришёл __ack__ от пира — сообщение точно доставлено на его устройство.
  Future<void> markDelivered(String deviceId, String msgId) async {
    await _safeDb.update(
      'lan_messages',
      {'is_delivered': 1},
      where: 'device_id = ? AND msg_id = ?',
      whereArgs: [deviceId, msgId],
    );
    await _reloadDialogs();
  }

  /// Пришёл __seen__ от пира — список msg_id, которые он открыл/увидел.
  /// НЕ путать с markRead(deviceId) ниже — тот про НАШ счётчик непрочитанных,
  /// этот про то, что ЧУЖИЕ сообщения (наши, с их стороны) отметили прочитанными.
  Future<void> markMessagesRead(String deviceId, List<String> msgIds) async {
    if (msgIds.isEmpty) return;
    final placeholders = List.filled(msgIds.length, '?').join(',');
    await _safeDb.rawUpdate(
      'UPDATE lan_messages SET is_delivered = 1, is_read = 1 '
      'WHERE device_id = ? AND msg_id IN ($placeholders)',
      [deviceId, ...msgIds],
    );
    await _reloadDialogs();
  }

  /// Тап тем же эмодзи повторно — снимает реакцию (toggle), как в ЛС.
  Future<void> setReaction(String deviceId, String msgId, String emoji) async {
    final rows = await _safeDb.query(
      'lan_messages',
      columns: ['reaction'],
      where: 'msg_id = ?',
      whereArgs: [msgId],
      limit: 1,
    );
    final current = rows.isNotEmpty ? rows.first['reaction'] as String? : null;
    await _safeDb.update(
      'lan_messages',
      {'reaction': current == emoji ? null : emoji},
      where: 'device_id = ? AND msg_id = ?',
      whereArgs: [deviceId, msgId],
    );
  }

  Future<void> deleteMessages(String deviceId, List<String> msgIds) async {
    if (msgIds.isEmpty) return;
    final placeholders = List.filled(msgIds.length, '?').join(',');
    await _safeDb.rawDelete(
      'DELETE FROM lan_messages WHERE device_id = ? AND msg_id IN ($placeholders)',
      [deviceId, ...msgIds],
    );
    await _reloadDialogs();
  }

  /// Переименовать локальный ярлык устройства (не влияет на его настоящий
  /// device_id/identity — чисто отображаемое имя на этом устройстве).
  Future<void> renameChat(String deviceId, String name) async {
    if (name.trim().isEmpty) return;
    await _safeDb.update(
      'lan_dialogs',
      {'display_name': name.trim()},
      where: 'device_id = ?',
      whereArgs: [deviceId],
    );
    await _reloadDialogs();
  }

  Future<void> markRead(String deviceId) async {
    await _safeDb.update(
      'lan_dialogs',
      {'unread': 0},
      where: 'device_id = ?',
      whereArgs: [deviceId],
    );
    await _reloadDialogs();
  }

  Future<void> markUnread(String deviceId) async {
    await _safeDb.update(
      'lan_messages',
      {'is_read': 0},
      where: 'device_id = ? AND from_me = 0',
      whereArgs: [deviceId],
    );
    final rows = await _safeDb.rawQuery(
      'SELECT COUNT(*) AS count FROM lan_messages '
      'WHERE device_id = ? AND from_me = 0',
      [deviceId],
    );
    final count = (rows.first['count'] as int?) ?? 0;
    await _safeDb.update(
      'lan_dialogs',
      {'unread': count},
      where: 'device_id = ?',
      whereArgs: [deviceId],
    );
    await _reloadDialogs();
  }

  Future<void> clearChat(String deviceId) async {
    await _safeDb.delete(
      'lan_messages',
      where: 'device_id = ?',
      whereArgs: [deviceId],
    );
    await _safeDb.delete(
      'lan_dialogs',
      where: 'device_id = ?',
      whereArgs: [deviceId],
    );
    await _reloadDialogs();
  }

  /// Удаляет байты вложений LAN-сообщений, сохраняя строки истории и имена
  /// файлов. Вложения LAN нельзя скачать с сервера повторно, поэтому экран
  /// просит отдельное подтверждение перед этой операцией.
  Future<int> clearMediaCache({String? preserveCategory}) async {
    var where = 'file_bytes IS NOT NULL';
    final whereArgs = <Object?>[];
    switch (preserveCategory) {
      case 'photo':
        where += " AND (file_mime IS NULL OR file_mime NOT LIKE ?)";
        whereArgs.add('image/%');
      case 'video':
        where += " AND (file_mime IS NULL OR file_mime NOT LIKE ?)";
        whereArgs.add('video/%');
      case 'voice':
        where += " AND (file_mime IS NULL OR file_mime NOT LIKE ?)";
        whereArgs.add('audio/%');
      case 'files':
        where +=
            " AND (file_mime LIKE ? OR file_mime LIKE ? OR file_mime LIKE ?)";
        whereArgs.addAll(['image/%', 'video/%', 'audio/%']);
      case 'db_overhead':
        where = '0 = 1';
        whereArgs.clear();
    }
    final rows = await _safeDb.rawQuery(
      'SELECT COUNT(*) AS count FROM lan_messages WHERE $where',
      whereArgs,
    );
    final count = (rows.first['count'] as int?) ?? 0;
    if (count > 0) {
      await _safeDb.rawUpdate(
        'UPDATE lan_messages SET file_bytes = NULL WHERE $where',
        whereArgs,
      );
    }
    try {
      await _safeDb.execute('VACUUM');
    } catch (_) {}
    return count;
  }

  Future<int> clearMediaCacheForDevices(
    Iterable<String> deviceIds, {
    Set<String>? categories,
  }) async {
    final ids = deviceIds.where((id) => id.trim().isNotEmpty).toSet().toList();
    if (ids.isEmpty || categories == null || categories.isEmpty) return 0;
    final placeholders = List.filled(ids.length, '?').join(',');
    final rows = await _safeDb.rawQuery(
      'SELECT device_id, msg_id, file_mime FROM lan_messages '
      'WHERE device_id IN ($placeholders) AND file_bytes IS NOT NULL',
      ids,
    );
    var removed = 0;
    for (final row in rows) {
      final mime = row['file_mime'] as String? ?? '';
      final category = mime.startsWith('image/')
          ? 'photo'
          : mime.startsWith('video/')
          ? 'video'
          : mime.startsWith('audio/')
          ? 'voice'
          : 'files';
      if (!categories.contains(category)) continue;
      final count = await _safeDb.rawUpdate(
        'UPDATE lan_messages SET file_bytes = NULL WHERE device_id = ? AND msg_id = ?',
        [row['device_id'], row['msg_id']],
      );
      removed += count;
    }
    return removed;
  }

  Future<int> clearMediaCacheByCategories(Set<String> categories) async {
    if (categories.isEmpty) return 0;
    final rows = await _safeDb.rawQuery(
      'SELECT device_id, msg_id, file_mime FROM lan_messages WHERE file_bytes IS NOT NULL',
    );
    var removed = 0;
    for (final row in rows) {
      final mime = row['file_mime'] as String? ?? '';
      final category = mime.startsWith('image/')
          ? 'photo'
          : mime.startsWith('video/')
          ? 'video'
          : mime.startsWith('audio/')
          ? 'voice'
          : 'files';
      if (!categories.contains(category)) continue;
      removed += await _safeDb.rawUpdate(
        'UPDATE lan_messages SET file_bytes = NULL WHERE device_id = ? AND msg_id = ?',
        [row['device_id'], row['msg_id']],
      );
    }
    return removed;
  }

  /// Та же разбивка по категориям, что и DbService.storageByCategory, но для
  /// вложений LAN-чатов (лежат в lan_messages.file_bytes, не в отдельном
  /// filecache) — экран "Хранилище" суммирует оба источника.
  Future<Map<String, int>> storageByCategory() async {
    final rows = await _safeDb.rawQuery(
      'SELECT file_mime AS mime, SUM(LENGTH(file_bytes)) AS total FROM lan_messages '
      'WHERE file_bytes IS NOT NULL GROUP BY file_mime',
    );
    var photo = 0, video = 0, voice = 0, files = 0, cachedTotal = 0;
    for (final r in rows) {
      final mime = r['mime'] as String? ?? '';
      final total = (r['total'] as int?) ?? 0;
      cachedTotal += total;
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
    final overhead = (dbFileSize - cachedTotal).clamp(0, dbFileSize);
    return {
      'photo': photo,
      'video': video,
      'voice': voice,
      'files': files,
      'db_overhead': overhead,
    };
  }
}

final lanChatStore = LanChatStore.instance;
