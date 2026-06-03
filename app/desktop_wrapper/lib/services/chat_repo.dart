// ChatRepo — оркестратор чата. Связывает ApiClient + WsClient + DbService +
// CryptoService в один высокоуровневый API.
//
// Слушает WS-события (chat.new / chat.echo / chat.delivered / chat.read /
// chat.cleared_by_peer), мержит в БД, нотифицирует UI через ValueNotifier-ы:
//   - dialogsNotifier — List<StoredDialog> для главного списка
//   - messagesNotifier(peer) — List<StoredMessage> для открытого чата
//
// Минимальный MVP (M5.1): текст в DM. Медиа/группы/реакции/edit/delete —
// следующими коммитами.

import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:pointycastle/export.dart';
import 'api_client.dart';
import 'auth_service.dart';
import 'crypto_service.dart';
import 'db_service.dart';
import 'ws_client.dart';

class ChatRepo {
  ChatRepo._();
  static final ChatRepo instance = ChatRepo._();

  final _api = ApiClient();
  final _ws = WsClient.instance;
  final _crypto = CryptoService.instance;
  final _db = DbService.instance;

  /// Список диалогов для главного списка.
  final ValueNotifier<List<StoredDialog>> dialogsNotifier = ValueNotifier([]);

  /// Сообщения по peer. Каждый ChatScreen подписывается на свой.
  final Map<String, ValueNotifier<List<StoredMessage>>> _msgsByPeer = {};
  ValueNotifier<List<StoredMessage>> messagesNotifier(String peer) =>
      _msgsByPeer.putIfAbsent(peer, () => ValueNotifier([]));

  /// Кэш чужих pubkey-ов в RAM на сессию.
  final Map<String, Uint8List> _peerPubCache = {};

  /// Подписки WS — для cancel при logout.
  final List<dynamic> _subs = [];

  String? _myUsername;

  bool _initialized = false;

  /// Вызвать ОДИН раз после login, когда DbService и CryptoService готовы.
  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    _myUsername = await AuthService.username();

    // Зальём свой публичный ключ на сервер (других схема не требует —
    // приватный храним только локально в SecureStorage).
    await _publishMyPubKey();

    // Загрузить локальный список диалогов сразу.
    final dialogs = await _db.getDialogs();
    dialogsNotifier.value = dialogs;

    // WS подписки.
    _subs.addAll([
      _ws.on('chat.new', _onChatNew),
      _ws.on('chat.echo', _onChatEcho),
      _ws.on('chat.delivered', _onChatDelivered),
      _ws.on('chat.read', _onChatRead),
      _ws.on('chat.cleared_by_peer', _onChatClearedByPeer),
    ]);

    // Догнать накопленное в фоне.
    unawaited(fetchPending());
  }

  Future<void> dispose() async {
    for (final s in _subs) {
      try { s.cancel(); } catch (_){}
    }
    _subs.clear();
    _peerPubCache.clear();
    _msgsByPeer.clear();
    dialogsNotifier.value = [];
    _initialized = false;
  }

  // ─── Публикация моего публичного ключа ───────────────────────────────
  Future<void> _publishMyPubKey() async {
    try {
      final pubRaw = await _crypto.myPublicKeyRaw();
      await _api.chatPost('/keys/upload', {
        'x25519_pub': base64Encode(pubRaw),
        // Веб-фронт шифрует приват паролем — у нас приват в SecureStorage,
        // recovery через mobile НЕ предусмотрено пока (M8).
        'encrypted_private_key': '',
        'key_salt': '',
      });
    } catch (e) {
      if (kDebugMode) print('[ChatRepo] publish pub failed: $e');
    }
  }

  // ─── Получение чужого pubkey (с кэшем) ───────────────────────────────
  Future<Uint8List> getPeerPub(String username) async {
    if (_peerPubCache.containsKey(username)) return _peerPubCache[username]!;
    final r = await _api.chatGet('/keys/$username');
    final pubB64 = (r as Map)['x25519_pub'] as String?;
    if (pubB64 == null || pubB64.isEmpty) {
      throw Exception('У @$username нет E2E-ключей');
    }
    final raw = Uint8List.fromList(base64Decode(pubB64));
    _peerPubCache[username] = raw;
    // TOFU pin (первое значение запоминаем; в M8 добавим UI для смены ключа).
    final pinned = await _db.getPinnedPub(username);
    if (pinned == null) {
      await _db.pinPub(username, pubB64, accepted: true);
    } else if (pinned != pubB64) {
      if (kDebugMode) {
        print('[ChatRepo] WARN: pubkey changed for $username! pinned vs new differ');
      }
      // TODO M8: показать UI «ключ собеседника изменился, принять?»
    }
    return raw;
  }

  // ─── Догон pending с сервера (legacy /pending) ────────────────────────
  Future<void> fetchPending() async {
    try {
      final r = await _api.chatGet('/pending');
      final msgs = ((r as Map)['messages'] as List?) ?? const [];
      final ackIds = <int>[];
      for (final raw in msgs) {
        final m = Map<String, dynamic>.from(raw as Map);
        try {
          await _ingestIncoming(m, fromPending: true);
          ackIds.add(m['id'] as int);
        } catch (e) {
          if (kDebugMode) print('[fetchPending] ingest failed: $e');
        }
      }
      if (ackIds.isNotEmpty) {
        try {
          await _api.chatPost('/ack', {'ids': ackIds});
        } catch (e) {
          if (kDebugMode) print('[fetchPending] ack failed: $e');
        }
      }
    } catch (e) {
      if (kDebugMode) print('[fetchPending] $e');
    }
  }

  // ─── Файлы: encrypted blob cache (parity с веб filecache) ────────────
  /// Cache-first скачивание файла. Возвращает encrypted blob или null.
  Future<Uint8List?> fetchEncryptedFile(int fileId) async {
    final cached = await _db.getCachedFile(fileId.toString());
    if (cached != null) return cached;
    final raw = await _api.downloadFile(fileId);
    if (raw == null) return null;
    final bytes = Uint8List.fromList(raw);
    await _db.cacheFile(fileId.toString(), bytes, null);
    return bytes;
  }

  /// Загружает файл (картинка/файл/voice) для конкретного peer'а.
  /// Сама шифрует AES-256, аплоадит зашифрованный blob, отправляет
  /// сообщение с {type, file_id, key, iv, ...}.
  ///
  /// type — 'file' для обычного, 'voice' для голосового.
  Future<void> sendDmFile({
    required String toUsername,
    required Uint8List bytes,
    required String mime,
    required String fileName,
    bool voice = false,
    int duration = 0,
  }) async {
    final tempSidId = -DateTime.now().microsecondsSinceEpoch;
    final tmpKey = 'tmp-$tempSidId';
    // Оптимистично показываем в чате (без file_id ещё)
    await _db.upsertMessage(StoredMessage(
      sid: tempSidId,
      peer: toUsername,
      fromMe: true,
      text: '',
      createdAt: DateTime.now().toUtc().toIso8601String(),
      pending: true,
      tempSid: tmpKey,
      filePayload: {
        'file_name': fileName,
        'mime': mime,
        'size': bytes.length,
        if (voice) 'voice': true,
        if (voice) 'duration': duration,
      },
    ));
    await _refreshMessages(toUsername);
    await _bumpDialog(toUsername,
        lastText: voice ? '[Голосовое]' : '[Файл: $fileName]', fromMe: true);

    try {
      // 1. Шифруем blob свежим AES-256 ключом
      final aesKey = _randomBytes(32);
      final iv = _randomBytes(12);
      final encBytes = _aesGcmEncryptBytes(aesKey, iv, bytes);
      // 2. Аплоадим encrypted blob
      final up = await _api.uploadFile(
        toUsername: toUsername,
        encryptedBytes: encBytes,
        name: voice ? 'voice' : fileName,
      );
      final fileId = up['file_id'] as int;
      // 3. Кэшируем у себя (parity с веб)
      await _db.cacheFile(fileId.toString(), encBytes, mime);
      // 4. Шифруем payload пэйра для отправки
      final peerPub = await getPeerPub(toUsername);
      final payload = {
        'type': voice ? 'voice' : 'file',
        'file_id': fileId,
        'file_name': fileName,
        'mime': mime,
        'size': bytes.length,
        'key': base64Encode(aesKey),
        'iv': base64Encode(iv),
        if (voice) 'voice': true,
        if (voice) 'duration': duration,
      };
      final ciphertext = await _crypto.encryptFor(
        theirPubRaw: peerPub, plaintext: jsonEncode(payload));
      final resp = await _api.chatPost('/send', {
        'to_username': toUsername,
        'ciphertext': ciphertext,
      });
      final realSid = (resp as Map)['id'] as int;
      final createdAt = resp['created_at'];
      final recipientOnline = (resp['recipient_online'] as bool?) ?? false;
      await _db.promoteOptimistic(
          peer: toUsername, tempSid: tmpKey, realSid: realSid, createdAt: createdAt);
      // Заполним file_payload реальным file_id
      await _db.updateMessageFlags(toUsername, realSid, {
        'file_payload': jsonEncode({
          'file_id': fileId,
          'file_name': fileName,
          'mime': mime,
          'size': bytes.length,
          'key': base64Encode(aesKey),
          'iv': base64Encode(iv),
          if (voice) 'voice': 1,
          if (voice) 'duration': duration,
        }),
        if (recipientOnline) 'delivered': 1,
      });
      await _refreshMessages(toUsername);
    } catch (e) {
      if (kDebugMode) print('[sendDmFile] $e');
      rethrow;
    }
  }

  /// Расшифровать encrypted blob медиа-сообщения. Возвращает plaintext bytes.
  Future<Uint8List?> decryptMediaBlob(StoredMessage m) async {
    final fp = m.filePayload;
    if (fp == null) return null;
    final fileId = fp['file_id'] as int?;
    final keyB64 = fp['key'] as String?;
    final ivB64 = fp['iv'] as String?;
    if (fileId == null || keyB64 == null || ivB64 == null) return null;
    final encBytes = await fetchEncryptedFile(fileId);
    if (encBytes == null) return null;
    final aesKey = Uint8List.fromList(base64Decode(keyB64));
    final iv = Uint8List.fromList(base64Decode(ivB64));
    try {
      return _aesGcmDecryptBytes(aesKey, iv, encBytes);
    } catch (e) {
      if (kDebugMode) print('[decryptMediaBlob] $e');
      return null;
    }
  }

  // ─── AES-GCM low-level (для файлов) ───────────────────────────────────
  Uint8List _aesGcmEncryptBytes(Uint8List key, Uint8List iv, Uint8List plain) {
    final cipher = GCMBlockCipher(AESEngine())
      ..init(true, AEADParameters(KeyParameter(key), 128, iv, Uint8List(0)));
    return cipher.process(plain);
  }

  Uint8List _aesGcmDecryptBytes(Uint8List key, Uint8List iv, Uint8List ct) {
    final cipher = GCMBlockCipher(AESEngine())
      ..init(false, AEADParameters(KeyParameter(key), 128, iv, Uint8List(0)));
    return cipher.process(ct);
  }

  Uint8List _randomBytes(int n) {
    final r = Random.secure();
    return Uint8List.fromList(List<int>.generate(n, (_) => r.nextInt(256)));
  }

  // ─── Отправка текста ─────────────────────────────────────────────────
  Future<void> sendDmText(String toUsername, String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    final tempSid = -DateTime.now().microsecondsSinceEpoch;
    final optimistic = StoredMessage(
      sid: tempSid,                                  // отрицательный пока ждём server id
      peer: toUsername,
      fromMe: true,
      text: trimmed,
      createdAt: DateTime.now().toUtc().toIso8601String(),
      pending: true,
      tempSid: 'tmp-$tempSid',
    );
    await _db.upsertMessage(optimistic);
    await _refreshMessages(toUsername);
    await _bumpDialog(toUsername, lastText: trimmed, fromMe: true);

    try {
      final peerPub = await getPeerPub(toUsername);
      final payload = jsonEncode({'type': 'msg', 'text': trimmed});
      final ciphertext = await _crypto.encryptFor(theirPubRaw: peerPub, plaintext: payload);
      final resp = await _api.chatPost('/send', {
        'to_username': toUsername,
        'ciphertext': ciphertext,
      });
      final realSid = (resp as Map)['id'] as int;
      final createdAt = resp['created_at'];
      final recipientOnline = (resp['recipient_online'] as bool?) ?? false;
      await _db.promoteOptimistic(
        peer: toUsername, tempSid: 'tmp-$tempSid', realSid: realSid, createdAt: createdAt,
      );
      // Если получатель онлайн — он почти точно сделает /ack → ставим delivered
      // оптимистично, чтобы не показывать вечную дискету.
      if (recipientOnline) {
        await _db.updateMessageFlags(toUsername, realSid, {'delivered': 1});
      }
      await _refreshMessages(toUsername);
      await _bumpDialog(toUsername, lastText: trimmed, fromMe: true, lastAt: createdAt);
    } catch (e) {
      if (kDebugMode) print('[sendDmText] $e');
      // Помечаем как failed (для UI можно добавить иконку).
      await _db.updateMessageFlags(toUsername, tempSid, {'pending': 0});
      await _refreshMessages(toUsername);
      rethrow;
    }
  }

  // ─── WS handlers ──────────────────────────────────────────────────────
  Future<void> _onChatNew(Map<String, dynamic> d) async {
    await _ingestIncoming(d, fromPending: false);
    final id = d['id'] as int?;
    if (id != null) {
      try { await _api.chatPost('/ack', {'ids': [id]}); } catch (_){}
    }
  }

  Future<void> _onChatEcho(Map<String, dynamic> d) async {
    // Echo своего сообщения — дедуп по sid в БД. Если уже есть — игнорим.
    final id = d['id'] as int?;
    final fromUsername = d['from_username'] as String?;
    final toUsername = d['to_username'] as String?;
    if (id == null) return;
    final peer = (fromUsername == _myUsername) ? toUsername : fromUsername;
    if (peer == null) return;
    if (await _db.messageExists(peer, id)) return;
    // Другая вкладка/устройство — это новое сообщение от нас, добавим.
    await _ingestIncoming(d, fromPending: false);
  }

  Future<void> _onChatDelivered(Map<String, dynamic> d) async {
    final ids = (d['ids'] as List?)?.cast<int>() ?? [];
    final peer = d['by_username'] as String?;
    if (peer == null || ids.isEmpty) return;
    for (final id in ids) {
      await _db.updateMessageFlags(peer, id, {'delivered': 1});
    }
    await _refreshMessages(peer);
  }

  Future<void> _onChatRead(Map<String, dynamic> d) async {
    final ids = (d['ids'] as List?)?.cast<int>() ?? [];
    final peer = d['by_username'] as String?;
    if (peer == null || ids.isEmpty) return;
    for (final id in ids) {
      await _db.updateMessageFlags(peer, id, {'read': 1, 'delivered': 1});
    }
    await _refreshMessages(peer);
  }

  Future<void> _onChatClearedByPeer(Map<String, dynamic> d) async {
    final peer = d['by_username'] as String?;
    if (peer == null) return;
    await _db.deleteMessagesByPeer(peer);
    await _db.deleteDialog(peer);
    _msgsByPeer[peer]?.value = [];
    dialogsNotifier.value = await _db.getDialogs();
  }

  // ─── Расшифровка и сохранение входящего ───────────────────────────────
  Future<void> _ingestIncoming(Map<String, dynamic> m, {required bool fromPending}) async {
    final isMine = m['from_username'] == _myUsername;
    final peerUsername = isMine ? m['to_username'] as String : m['from_username'] as String;
    final senderPub = await getPeerPub(isMine ? peerUsername : peerUsername);
    final cipher = m['ciphertext'] as String;
    String plainJson;
    try {
      plainJson = await _crypto.decryptFrom(theirPubRaw: senderPub, envelopeB64: cipher);
    } catch (e) {
      plainJson = '{"type":"msg","text":"[не удалось расшифровать]"}';
    }
    final payload = _parsePayload(plainJson);
    final type = payload['type'] as String? ?? 'msg';

    // ─── Управляющие типы: правка/удаление/реакция/forward-ack ───
    if (type == 'edit') {
      final targetSid = payload['sid'] as int?;
      final newText = payload['text'] as String? ?? '';
      if (targetSid != null) {
        await _db.updateMessageFlags(peerUsername, targetSid, {
          'text': newText,
          'edited': 1,
        });
        await _refreshMessages(peerUsername);
      }
      return;
    }
    if (type == 'delete') {
      final targetSid = payload['sid'] as int?;
      if (targetSid != null) {
        await _db.updateMessageFlags(peerUsername, targetSid, {
          'deleted': 1,
          'text': '',
          'file_payload': null,
        });
        await _refreshMessages(peerUsername);
      }
      return;
    }
    if (type == 'react') {
      final targetSid = payload['sid'] as int?;
      final emoji = payload['emoji'] as String?;
      final actor = isMine ? _myUsername : peerUsername;
      if (targetSid != null && emoji != null && actor != null) {
        await _toggleReactionLocal(peerUsername, targetSid, emoji, actor);
        await _refreshMessages(peerUsername);
      }
      return;
    }

    // ─── Обычное сообщение / файл / голосовое ───
    final isFile = type == 'file' || type == 'voice';
    final stored = StoredMessage(
      sid: m['id'] as int,
      peer: peerUsername,
      fromMe: isMine,
      text: (payload['text'] as String?) ?? '',
      createdAt: m['created_at'],
      replyTo: payload['reply_to'] is int ? payload['reply_to'] as int : null,
      replyPreview: payload['reply_preview'] as String?,
      forwardedFrom: payload['forwarded_from'] as String?,
      filePayload: isFile
          ? {
              'file_id': payload['file_id'],
              'file_name': payload['file_name'] ?? '',
              'mime': payload['mime'] ?? 'application/octet-stream',
              'size': payload['size'] ?? 0,
              'key': payload['key'],
              'iv': payload['iv'],
              if (type == 'voice') 'voice': true,
              if (type == 'voice') 'duration': payload['duration'] ?? 0,
            }
          : null,
    );
    await _db.upsertMessage(stored);
    await _refreshMessages(peerUsername);
    final preview = isFile
        ? (type == 'voice' ? '[Голосовое]' : '[Файл: ${payload['file_name'] ?? ''}]')
        : stored.text;
    await _bumpDialog(
      peerUsername,
      lastText: preview,
      fromMe: isMine,
      lastAt: m['created_at'],
      incUnread: !isMine && fromPending,
    );
  }

  /// Локально применить toggle реакции к сообщению.
  Future<void> _toggleReactionLocal(
      String peer, int sid, String emoji, String actor) async {
    final list = await _db.getMessages(peer);
    final m = list.firstWhere((x) => x.sid == sid,
        orElse: () => StoredMessage(sid: -1, peer: peer, fromMe: false, createdAt: ''));
    if (m.sid == -1) return;
    final reactions = Map<String, List<String>>.from(
        m.reactions ?? <String, List<String>>{});
    final users = List<String>.from(reactions[emoji] ?? const []);
    if (users.contains(actor)) {
      users.remove(actor);
    } else {
      users.add(actor);
    }
    if (users.isEmpty) {
      reactions.remove(emoji);
    } else {
      reactions[emoji] = users;
    }
    await _db.updateMessageFlags(peer, sid, {
      'reactions': reactions.isEmpty ? null : jsonEncode(reactions),
    });
  }

  // ─── Edit / Delete / React / Forward (исходящие) ────────────────────────
  Future<void> editDmMessage({
    required String toUsername,
    required int sid,
    required String newText,
  }) async {
    final peerPub = await getPeerPub(toUsername);
    final payload = jsonEncode({'type': 'edit', 'sid': sid, 'text': newText});
    final ciphertext = await _crypto.encryptFor(
        theirPubRaw: peerPub, plaintext: payload);
    await _api.chatPost('/send', {
      'to_username': toUsername,
      'ciphertext': ciphertext,
    });
    await _db.updateMessageFlags(toUsername, sid, {
      'text': newText,
      'edited': 1,
    });
    await _refreshMessages(toUsername);
  }

  Future<void> deleteDmMessage({
    required String toUsername,
    required int sid,
  }) async {
    final peerPub = await getPeerPub(toUsername);
    final payload = jsonEncode({'type': 'delete', 'sid': sid});
    final ciphertext = await _crypto.encryptFor(
        theirPubRaw: peerPub, plaintext: payload);
    await _api.chatPost('/send', {
      'to_username': toUsername,
      'ciphertext': ciphertext,
    });
    await _db.updateMessageFlags(toUsername, sid, {
      'deleted': 1,
      'text': '',
      'file_payload': null,
    });
    await _refreshMessages(toUsername);
  }

  Future<void> reactDmMessage({
    required String toUsername,
    required int sid,
    required String emoji,
  }) async {
    final me = _myUsername ?? await AuthService.username();
    if (me == null) return;
    final peerPub = await getPeerPub(toUsername);
    final payload = jsonEncode({'type': 'react', 'sid': sid, 'emoji': emoji});
    final ciphertext = await _crypto.encryptFor(
        theirPubRaw: peerPub, plaintext: payload);
    await _api.chatPost('/send', {
      'to_username': toUsername,
      'ciphertext': ciphertext,
    });
    await _toggleReactionLocal(toUsername, sid, emoji, me);
    await _refreshMessages(toUsername);
  }

  /// Переслать сообщение другому пользователю.
  /// Если оригинал текст — отправляется новый текст с forwarded_from.
  /// Если оригинал файл — повторно шифруется для нового адресата.
  Future<void> forwardDmMessage({
    required StoredMessage original,
    required String toUsername,
  }) async {
    final originalAuthor = original.fromMe
        ? (_myUsername ?? await AuthService.username() ?? '')
        : original.peer;
    final peerPub = await getPeerPub(toUsername);

    if (original.filePayload != null) {
      // Перешифровываем blob новым ключом для нового адресата
      final plainBytes = await decryptMediaBlob(original);
      if (plainBytes == null) throw Exception('Не удалось расшифровать оригинал');
      final fp = original.filePayload!;
      final isVoice = fp['voice'] == true || fp['voice'] == 1;
      await sendDmFile(
        toUsername: toUsername,
        bytes: plainBytes,
        mime: fp['mime'] as String? ?? 'application/octet-stream',
        fileName: fp['file_name'] as String? ?? 'file',
        voice: isVoice,
        duration: (fp['duration'] as int?) ?? 0,
      );
      // forwarded_from-метку добавим в текстовом отдельном сообщении (UX мейл)
      return;
    }

    final tempSid = -DateTime.now().microsecondsSinceEpoch;
    final optimistic = StoredMessage(
      sid: tempSid,
      peer: toUsername,
      fromMe: true,
      text: original.text,
      createdAt: DateTime.now().toUtc().toIso8601String(),
      pending: true,
      tempSid: 'tmp-$tempSid',
      forwardedFrom: originalAuthor,
    );
    await _db.upsertMessage(optimistic);
    await _refreshMessages(toUsername);
    await _bumpDialog(toUsername, lastText: original.text, fromMe: true);

    final payload = jsonEncode({
      'type': 'msg',
      'text': original.text,
      'forwarded_from': originalAuthor,
    });
    final ciphertext = await _crypto.encryptFor(
        theirPubRaw: peerPub, plaintext: payload);
    final resp = await _api.chatPost('/send', {
      'to_username': toUsername,
      'ciphertext': ciphertext,
    });
    final realSid = (resp as Map)['id'] as int;
    final createdAt = resp['created_at'];
    await _db.promoteOptimistic(
      peer: toUsername,
      tempSid: 'tmp-$tempSid',
      realSid: realSid,
      createdAt: createdAt,
    );
    await _refreshMessages(toUsername);
  }

  Map<String, dynamic> _parsePayload(String raw) {
    final t = raw.trimLeft();
    if (t.startsWith('{')) {
      try { return Map<String, dynamic>.from(jsonDecode(t) as Map); }
      catch (_) {}
    }
    return {'type': 'msg', 'text': raw};
  }

  Future<void> _refreshMessages(String peer) async {
    final list = await _db.getMessages(peer);
    final notif = _msgsByPeer[peer];
    if (notif != null) notif.value = list;
  }

  Future<void> _bumpDialog(
    String username, {
    required String lastText,
    required bool fromMe,
    dynamic lastAt,
    bool incUnread = false,
  }) async {
    final existing = await _db.getDialog(username);
    final dlg = StoredDialog(
      username: username,
      displayName: existing?.displayName ?? username,
      lastText: lastText,
      lastAt: lastAt ?? DateTime.now().toUtc().toIso8601String(),
      lastFromMe: fromMe,
      unread: incUnread ? (existing?.unread ?? 0) + 1 : (existing?.unread ?? 0),
    );
    await _db.upsertDialog(dlg);
    dialogsNotifier.value = await _db.getDialogs();
  }

  Future<void> markChatRead(String peer) async {
    await _db.resetUnread(peer);
    dialogsNotifier.value = await _db.getDialogs();
    // Сообщим серверу что прочитал входящие (он пингует sender'у двойную галку).
    try {
      final msgs = await _db.getMessages(peer);
      final theirIds = msgs.where((m) => !m.fromMe && !m.read).map((m) => m.sid).toList();
      if (theirIds.isNotEmpty) {
        await _api.chatPost('/read', {'ids': theirIds, 'from_username': peer});
        for (final id in theirIds) {
          await _db.updateMessageFlags(peer, id, {'read': 1});
        }
        await _refreshMessages(peer);
      }
    } catch (e) {
      if (kDebugMode) print('[markChatRead] $e');
    }
  }
}
