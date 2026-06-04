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
  /// Какие peer-ы уже подгружены из БД — чтобы не дёргать SQL на каждый getter.
  final Set<String> _msgsLoadedFromDb = {};

  ValueNotifier<List<StoredMessage>> messagesNotifier(String peer) {
    final notif = _msgsByPeer.putIfAbsent(peer, () => ValueNotifier([]));
    // Первое обращение → асинхронно подгружаем историю из локальной БД.
    if (!_msgsLoadedFromDb.contains(peer)) {
      _msgsLoadedFromDb.add(peer);
      unawaited(_refreshMessages(peer));
    }
    return notif;
  }

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
      _ws.on('chat.sealed_new', _onChatSealedNew),         // ← real-time sealed
      _ws.on('chat.delivered', _onChatDelivered),
      _ws.on('chat.read', _onChatRead),
      _ws.on('chat.cleared_by_peer', _onChatClearedByPeer),
    ]);

    // Догнать накопленное в фоне — оба канала.
    unawaited(fetchPending());
    unawaited(fetchPendingSealed());
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

  // ─── Управление ключами (для UI Settings) ────────────────────────────
  /// Принудительно перезалить мой публичный ключ на сервер. Полезно когда
  /// автоматическая синхронизация не помогла и пиры пишут «не удалось
  /// расшифровать». Возвращает сообщение для пользователя.
  Future<String> forcePublishMyPubKey() async {
    try {
      final pubRaw = await _crypto.myPublicKeyRaw();
      final myPubB64 = base64Encode(pubRaw);
      final dummyEncPriv = base64Encode(List<int>.filled(48, 0));
      final dummySalt = base64Encode(List<int>.filled(16, 0));
      await _api.chatPost('/keys/upload', {
        'x25519_pub': myPubB64,
        'encrypted_private_key': dummyEncPriv,
        'key_salt': dummySalt,
      });
      _peerPubCache.clear();
      return 'Ключ обновлён. Пиры должны подтвердить новый ключ при следующем сообщении.';
    } catch (e) {
      return 'Не удалось: $e';
    }
  }

  /// Перегенерировать E2E-пару заново (новый приват + новый паблик), залить
  /// на сервер. Все ранее зашифрованные сообщения от пиров СТАНУТ нечитаемыми
  /// — это nuclear option для случая когда ничего больше не помогает.
  Future<String> regenerateKeys() async {
    try {
      await _crypto.wipe();
      await _crypto.ensureKeys();        // сгенерит новую пару
      return await forcePublishMyPubKey();
    } catch (e) {
      return 'Не удалось перегенерить: $e';
    }
  }

  // ─── Публикация моего публичного ключа ───────────────────────────────
  /// Сравниваем серверный pubkey с моим локальным. Если на сервере другой
  /// (или его нет) — публикуем мой (т.к. **приват только у нас**, мы единственный
  /// источник истины для этого аккаунта на данном устройстве). Если совпадают —
  /// ничего не делаем (экономим rate-limit 5/час).
  ///
  /// Бонус: если на сервере был чужой pubkey (например веб-клиент с другим
  /// приватом) и мы его перезаписываем — пиры увидят rotation и должны
  /// подтвердить новый ключ через TOFU. До того их зашифрованные сообщения
  /// не расшифровать (приват другой).
  Future<void> _publishMyPubKey() async {
    try {
      final pubRaw = await _crypto.myPublicKeyRaw();
      final myPubB64 = base64Encode(pubRaw);
      // 1. Сравнить с сервером
      String? serverPub;
      try {
        final mine = await _api.chatGet('/keys/me');
        if (mine is Map) serverPub = mine['x25519_pub'] as String?;
      } catch (_) {/* если /keys/me провалился — попробуем upload */}
      if (serverPub == myPubB64) {
        if (kDebugMode) print('[ChatRepo] pubkey уже актуален');
        return;
      }
      if (kDebugMode) {
        print('[ChatRepo] pubkey mismatch: '
            'server=${serverPub?.substring(0, 16) ?? "null"}... '
            'mine=${myPubB64.substring(0, 16)}... → залить мой');
      }
      // 2. Заливаем мой. encrypted_private_key — 48 байт placeholder (приват
      // в SecureStorage локально, sync приватников через seed/QR — отдельная фаза).
      final dummyEncPriv = base64Encode(List<int>.filled(48, 0));
      final dummySalt = base64Encode(List<int>.filled(16, 0));
      await _api.chatPost('/keys/upload', {
        'x25519_pub': myPubB64,
        'encrypted_private_key': dummyEncPriv,
        'key_salt': dummySalt,
      });
      if (kDebugMode) print('[ChatRepo] pubkey опубликован успешно');
      // 3. Чистим локальный кэш peer-ов: если у меня кэширован их pubkey
      // отдельно — он остаётся валидным; чистка нужна если пиры тоже сменили
      // ключи (TOFU re-pin при ошибке расшифровки).
      _peerPubCache.clear();
    } catch (e) {
      if (kDebugMode) print('[ChatRepo] publish pub failed: $e');
    }
  }

  /// При получении envelope, которую не можем расшифровать (InvalidCipherText),
  /// возможно у пира сменился pubkey. Сбрасываем TOFU pin и кэш, чтобы при
  /// следующем входящем сообщении подтянуть свежий pubkey с сервера.
  Future<void> _refreshPeerPubAfterDecryptFail(String username) async {
    _peerPubCache.remove(username);
    try {
      // Перетягиваем с сервера и пересохраняем pin.
      final r = await _api.chatGet('/keys/$username');
      final pubB64 = (r as Map)['x25519_pub'] as String?;
      if (pubB64 != null && pubB64.isNotEmpty) {
        await _db.pinPub(username, pubB64, accepted: true);
        _peerPubCache[username] = Uint8List.fromList(base64Decode(pubB64));
        if (kDebugMode) {
          print('[ChatRepo] перепиновали ключ @$username (после decrypt fail)');
        }
      }
    } catch (e) {
      if (kDebugMode) print('[ChatRepo] re-pin failed: $e');
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

  /// Sealed-сообщения хранятся в отдельной таблице на сервере (chat_dm_sealed),
  /// со своим auto-increment ID. Чтобы он не пересекался с legacy chat_dm.id
  /// в нашей единой messages-таблице — добавляем смещение.
  static const _sealedSidOffset = 1 << 40; // 1_099_511_627_776

  int _sealedSid(int rawId) => _sealedSidOffset + rawId;

  // ─── Real-time sealed event ──────────────────────────────────────────
  Future<void> _onChatSealedNew(Map<String, dynamic> d) async {
    final id = d['id'];
    final cipher = d['ciphertext'] as String?;
    final createdAt = d['created_at'];
    if (id is! int || cipher == null) return;
    final ok = await _ingestSealed(id: id, cipher: cipher, createdAt: createdAt);
    if (ok) {
      try { await _api.chatPost('/ack_sealed', {'ids': [id]}); } catch (_) {}
    }
  }

  // ─── Догон pending_sealed (Sealed Sender 2.0) ────────────────────────
  /// Тянет /pending_sealed, расшифровывает каждый envelope своим приват-ключом,
  /// инжектит как обычное входящее сообщение, ack-ает на сервер.
  Future<void> fetchPendingSealed() async {
    try {
      final r = await _api.chatGet('/pending_sealed');
      final msgs = ((r as Map)['messages'] as List?) ?? const [];
      final ackIds = <int>[];
      for (final raw in msgs) {
        final m = Map<String, dynamic>.from(raw as Map);
        final id = m['id'] as int?;
        final cipher = m['ciphertext'] as String?;
        if (id == null || cipher == null) continue;
        try {
          final ok = await _ingestSealed(id: id, cipher: cipher, createdAt: m['created_at']);
          if (ok) ackIds.add(id);
        } catch (e) {
          if (kDebugMode) print('[fetchPendingSealed] decrypt fail $id: $e');
        }
      }
      if (ackIds.isNotEmpty) {
        try {
          await _api.chatPost('/ack_sealed', {'ids': ackIds});
        } catch (e) {
          if (kDebugMode) print('[fetchPendingSealed] ack fail: $e');
        }
      }
    } catch (e) {
      if (kDebugMode) print('[fetchPendingSealed] $e');
    }
  }

  /// Inject sealed-сообщение в локальное состояние.
  Future<bool> _ingestSealed({required int id, required String cipher, dynamic createdAt}) async {
    Map<String, dynamic> env;
    try {
      env = await _crypto.decryptSealed(cipher);
    } catch (e) {
      if (kDebugMode) print('[sealed decrypt fail]: $e');
      return false;
    }
    final fromUsername = env['from_username'] as String?;
    if (fromUsername == null) return false;

    final type = env['type'] as String? ?? 'msg';
    // Управляющие sealed-типы: delivered/read с target_sid (sid отправителя).
    // target_sid у меня в БД — это payloadSid (см. sendDmText) который я
    // подкладывал в envelope при отправке. Этот sid совпадает с локальным sid
    // оптимистичного сообщения после promoteOptimistic (server real id sealed).
    if (type == 'delivered' || type == 'read') {
      final tgtSid = env['target_sid'];
      if (tgtSid is int) {
        // target_sid — это payload.sid (millis) который я положил при отправке.
        // Находим локальный sid через _sealedPayloadIndex.
        final localSid = _sealedPayloadIndex[tgtSid];
        if (localSid != null) {
          await _db.updateMessageFlags(fromUsername, localSid, {
            'delivered': 1,
            if (type == 'read') 'read': 1,
          });
          await _refreshMessages(fromUsername);
        }
      }
      return true;
    }
    if (type == 'edit') {
      final sid = env['sid'];
      if (sid is int) {
        await _db.updateMessageFlags(fromUsername, _sealedSid(sid), {
          'text': (env['text'] as String?) ?? '',
          'edited': 1,
        });
        await _refreshMessages(fromUsername);
      }
      return true;
    }
    if (type == 'delete') {
      final sid = env['sid'];
      if (sid is int) {
        await _db.updateMessageFlags(fromUsername, _sealedSid(sid), {
          'deleted': 1, 'text': '', 'file_payload': null,
        });
        await _refreshMessages(fromUsername);
      }
      return true;
    }
    if (type == 'react') {
      final sid = env['sid'];
      final emoji = env['emoji'] as String?;
      if (sid is int && emoji != null) {
        await _toggleReactionLocal(fromUsername, _sealedSid(sid), emoji, fromUsername);
        await _refreshMessages(fromUsername);
      }
      return true;
    }

    // Обычное text / file / voice
    final isFile = type == 'file' || type == 'voice';
    final localSid = _sealedSid(id);
    final stored = StoredMessage(
      sid: localSid,
      peer: fromUsername,
      fromMe: false,
      text: (env['text'] as String?) ?? '',
      createdAt: createdAt,
      replyTo: env['reply_to'] is int ? env['reply_to'] as int : null,
      replyPreview: env['reply_preview'] as String?,
      forwardedFrom: env['forwarded_from'] as String?,
      filePayload: isFile
          ? {
              'file_id': env['file_id'],
              'file_name': env['file_name'] ?? '',
              'mime': env['mime'] ?? 'application/octet-stream',
              'size': env['size'] ?? 0,
              'key': env['key'],
              'iv': env['iv'],
              if (type == 'voice') 'voice': true,
              if (type == 'voice') 'duration': env['duration'] ?? 0,
            }
          : null,
    );
    if (await _db.messageExists(fromUsername, localSid)) return true; // dedup
    await _db.upsertMessage(stored);
    await _refreshMessages(fromUsername);
    final preview = isFile
        ? (type == 'voice' ? '[Голосовое]' : '[Файл: ${env['file_name'] ?? ''}]')
        : stored.text;
    await _bumpDialog(fromUsername, lastText: preview, fromMe: false,
        lastAt: createdAt, incUnread: true);

    // После приёма — sealed-delivered обратно отправителю с target_sid внутри
    final senderSid = env['sid'];
    if (senderSid is int) {
      try {
        final peerPub = await getPeerPub(fromUsername);
        final me = _myUsername ?? await AuthService.username() ?? '';
        final reply = await _crypto.encryptSealed(
          receiverPubRaw: peerPub,
          payload: {'type': 'delivered', 'target_sid': senderSid},
          fromUsername: me,
        );
        await _api.chatPost('/send_sealed', {
          'to_username': fromUsername,
          'ciphertext': reply,
        });
      } catch (e) {
        if (kDebugMode) print('[sealed delivered echo] $e');
      }
    }
    return true;
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

  // ─── Отправка текста (через legacy /send — sealed-sender в вебе временно
  //     ОТКЛЮЧЁН: см. chat/index.html — для отправки используется /send,
  //     /send_sealed только для delivered-echo. Чтобы веб-получатель видел
  //     мои сообщения, шлём legacy способом.) ──────────────────────────────
  Future<void> sendDmText(String toUsername, String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    final tempSid = -DateTime.now().microsecondsSinceEpoch;
    final optimistic = StoredMessage(
      sid: tempSid,
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
      final ciphertext =
          await _crypto.encryptFor(theirPubRaw: peerPub, plaintext: payload);
      final resp = await _api.chatPost('/send', {
        'to_username': toUsername,
        'ciphertext': ciphertext,
      });
      final realSid = (resp as Map)['id'] as int;
      final createdAt = resp['created_at'];
      final recipientOnline = (resp['recipient_online'] as bool?) ?? false;
      await _db.promoteOptimistic(
        peer: toUsername,
        tempSid: 'tmp-$tempSid',
        realSid: realSid,
        createdAt: createdAt,
      );
      if (recipientOnline) {
        await _db.updateMessageFlags(toUsername, realSid, {'delivered': 1});
      }
      await _refreshMessages(toUsername);
      await _bumpDialog(toUsername,
          lastText: trimmed, fromMe: true, lastAt: createdAt);
    } catch (e) {
      if (kDebugMode) print('[sendDmText] $e');
      await _db.updateMessageFlags(toUsername, tempSid, {'pending': 0});
      await _refreshMessages(toUsername);
      rethrow;
    }
  }

  /// Mapping payload.sid → local sid для sealed delivered/read echo.
  /// LRU-cap чтобы не накапливать память (sealed-delivered приходит сразу
  /// после отправки; mapping нужен только short-term).
  final Map<int, int> _sealedPayloadIndex = {};
  static const _sealedPayloadCap = 500;

  void _rememberSealedPayload(int payloadSid, int localSid) {
    if (_sealedPayloadIndex.length >= _sealedPayloadCap) {
      // Удаляем самые старые записи (Dart Map = LinkedHashMap = по вставке).
      final toRemove = _sealedPayloadIndex.keys.take(100).toList();
      for (final k in toRemove) {
        _sealedPayloadIndex.remove(k);
      }
    }
    _sealedPayloadIndex[payloadSid] = localSid;
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
    // Pubkey пира одинаков и для исходящего, и для входящего (DM один общий
    // ECDH с peer.static_pub). Раньше тут был баг с бессмысленным тернарником.
    final senderPub = await getPeerPub(peerUsername);
    final cipher = m['ciphertext'] as String;
    String plainJson;
    try {
      plainJson = await _crypto.decryptFrom(theirPubRaw: senderPub, envelopeB64: cipher);
    } catch (e) {
      if (kDebugMode) {
        print('[ChatRepo._ingestIncoming] decrypt fail (peer=$peerUsername): $e');
      }
      // Возможно ключ пира сменился — перепиновываем, чтобы СЛЕДУЮЩЕЕ
      // сообщение могло расшифроваться.
      unawaited(_refreshPeerPubAfterDecryptFail(peerUsername));
      plainJson = '{"type":"msg","text":"[не удалось расшифровать — ключ собеседника мог измениться]"}';
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
    // Гарантированно подгружаем историю из БД при открытии чата.
    _msgsLoadedFromDb.add(peer);
    await _refreshMessages(peer);
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
