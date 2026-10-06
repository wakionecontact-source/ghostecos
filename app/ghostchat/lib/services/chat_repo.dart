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
import 'package:uuid/uuid.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:pointycastle/export.dart';
import 'package:video_compress/video_compress.dart';
import 'api_client.dart';
import 'auth_service.dart';
import 'crypto_service.dart';
import 'notification_service.dart';
import 'crypto_v2.dart';
import 'chat_message_auth.dart';
import 'bot_message_delivery.dart';
import 'db_service.dart';
import 'ws_client.dart';
import 'triangle_service.dart';
import 'profile_cache.dart';
import 'privacy_settings.dart';
import '../core/local/app_logger.dart';
import '../core/models/bot_reply_markup.dart';
import '../core/models/message_button.dart';

class V2IdentitySecurityException implements Exception {
  final String message;
  const V2IdentitySecurityException(this.message);

  @override
  String toString() => message;
}

String _compactMediaSendError(Object error) {
  final raw = error.toString();
  final lower = raw.toLowerCase();
  final isCiphertextLimit =
      lower.contains('ciphertext') &&
      (lower.contains('string_too_long') ||
          lower.contains('max_length') ||
          lower.contains('too long'));
  if (isCiphertextLimit || raw.length > 4096) {
    return isCiphertextLimit
        ? 'Служебные данные файла превышают лимит сервера'
        : 'Сервер вернул слишком длинную ошибку при отправке файла';
  }
  return raw;
}

int? _mediaDurationSeconds(dynamic value) {
  if (value is num && value > 0) return value.round();
  final parsed = int.tryParse(value?.toString() ?? '');
  return parsed != null && parsed > 0 ? parsed : null;
}

int? _createdAtMillis(dynamic value) {
  if (value is num) {
    final raw = value.toInt();
    if (raw <= 0) return null;
    return raw < 100000000000 ? raw * 1000 : raw;
  }
  if (value is String) {
    final raw = value.trim();
    final numeric = int.tryParse(raw);
    if (numeric != null && numeric > 0) {
      return numeric < 100000000000 ? numeric * 1000 : numeric;
    }
    final parsed = DateTime.tryParse(raw);
    if (parsed == null) return null;
    // SQLite's datetime('now') is UTC but has no timezone suffix. Do not let
    // DateTime.parse reinterpret that legacy server value as local Moscow
    // time, otherwise a new message could look older than the delete cutoff.
    final hasTimezone = RegExp(
      r'(?:z|[+-]\d{2}:?\d{2})$',
      caseSensitive: false,
    ).hasMatch(raw);
    if (hasTimezone) return parsed.toUtc().millisecondsSinceEpoch;
    return DateTime.utc(
      parsed.year,
      parsed.month,
      parsed.day,
      parsed.hour,
      parsed.minute,
      parsed.second,
      parsed.millisecond,
      parsed.microsecond,
    ).millisecondsSinceEpoch;
  }
  return null;
}

/// Итог синхронизации ключей — UI (KeyGate) реагирует:
///   ok             — всё синхронизировано, показывать ничего не надо;
///   skipped        — пользователь явно пропустил проверку в этой сессии;
///   needChooseMode — режим хранения не выбран, показать выбор server/local;
///   needPassword   — server-режим, нужен пароль для приватника с сервера;
///   serverCopyMissing — серверный режим есть, но зашифрованной копии нет;
///   error          — сетевой/иной сбой (вход не блокируем).
enum KeySyncOutcome {
  ok,
  skipped,
  needChooseMode,
  needPassword,
  serverCopyMissing,
  needUpdateConfirm,
  keyMismatch,
  error,
}

/// Публичное состояние серверной копии. В обычном периодическом watcher'е
/// используется только metadata; зашифрованный blob запрашивается лишь на
/// экране входа или после явного согласия пользователя на восстановление.
class KeyServerState {
  final String? mode;
  final String? publicKey;
  final String? encryptedPrivateKey;
  final String? keySalt;
  final String? keyKdf;
  final String? keyFormat;
  final bool? serverCopyAvailable;

  const KeyServerState({
    this.mode,
    this.publicKey,
    this.encryptedPrivateKey,
    this.keySalt,
    this.keyKdf,
    this.keyFormat,
    this.serverCopyAvailable,
  });

  bool get hasServerCopy {
    final hasPayload =
        encryptedPrivateKey != null &&
        encryptedPrivateKey!.isNotEmpty &&
        keySalt != null &&
        keySalt!.isNotEmpty;
    // A metadata-only status must never be treated as a downloadable copy.
    return hasPayload && serverCopyAvailable != false;
  }

  factory KeyServerState.fromMap(Map<String, dynamic> m) => KeyServerState(
    mode: _optionalString(m['storage_mode'] ?? m['mode']),
    publicKey: _optionalString(m['x25519_pub']),
    encryptedPrivateKey: _optionalString(m['encrypted_private_key']),
    keySalt: _optionalString(m['key_salt']),
    keyKdf: _optionalString(m['key_kdf']),
    keyFormat: _optionalString(m['key_format']),
    serverCopyAvailable: _optionalBool(
      m['has_server_key'] ?? m['has_server_priv'],
    ),
  );

  static String? _optionalString(Object? value) =>
      value is String ? value : null;

  static bool? _optionalBool(Object? value) {
    if (value is bool) return value;
    if (value is num) return value != 0;
    if (value is String) {
      switch (value.trim().toLowerCase()) {
        case 'true':
        case '1':
        case 'yes':
          return true;
        case 'false':
        case '0':
        case 'no':
          return false;
      }
    }
    return null;
  }
}

class ChatRepo {
  ChatRepo._();
  static final ChatRepo instance = ChatRepo._();

  final _api = ApiClient();
  final _ws = WsClient.instance;
  final _crypto = CryptoService.instance;
  final _db = DbService.instance;

  // Keep the general message guard compatible with the 16,000-character API
  // contract. The current production validator has an additional 4,000-char
  // base64 helper limit, so media envelopes use the smaller budget below.
  static const _maxChatCiphertextChars = 15_000;
  static const _maxMediaCiphertextChars = 3_800;

  // ── v2 (Signal-style: Ed25519 identity + X25519 device, per-device sealed) ──
  bool _v2Published = false;
  final Map<String, Map<String, dynamic>> _v2KeysCache = {};
  final Map<String, DateTime> _v2KeysFetchedAt = {};
  static const _v2PeerKeysTtl = Duration(seconds: 20);
  final Map<String, String> _v2WhoisCache = {};

  // The open 1:1 chat owns a single serialized key check. The UI timer is
  // deliberately outside ChatRepo, but this guard keeps reconnects/lifecycle
  // callbacks from starting another /keys/me request while one is running.
  Future<void>? _openChatKeyCheckInFlight;
  String? _lastOwnKeyCheckState;
  String? _lastOwnV2IdentityMismatch;
  Timer? _ownKeyCheckTimer;
  Timer? _outboxRetryTimer;
  Future<void>? _outboxDrain;
  DateTime? _lastV2DeviceRepairAt;
  bool _keySyncSkippedForSession = false;

  /// Список диалогов для главного списка.
  final ValueNotifier<List<StoredDialog>> dialogsNotifier = ValueNotifier([]);

  /// Состояние синхронизации E2E-ключей. UI (KeyGate) подписывается: при
  /// needChooseMode показывает выбор режима, при needPassword запрашивает пароль.
  final ValueNotifier<KeySyncOutcome> keySyncNotifier = ValueNotifier(
    KeySyncOutcome.ok,
  );

  /// Online/offline статус пиров. Подписка через `watchPresence(username)`.
  /// Запрашивается через WS `presence.ask`, обновляется через WS `presence`.
  final Map<String, ValueNotifier<bool>> _presenceByPeer = {};
  final Map<String, DateTime> _presenceRequestedAt = {};
  static const _presenceRequestDebounce = Duration(seconds: 3);

  String _normalizePresenceUsername(String username) =>
      username.trim().toLowerCase();

  void _requestPresence(String username, {bool force = false}) {
    final normalized = _normalizePresenceUsername(username);
    if (normalized.isEmpty || !_ws.isConnected) return;

    final now = DateTime.now();
    final previous = _presenceRequestedAt[normalized];
    if (!force &&
        previous != null &&
        now.difference(previous) < _presenceRequestDebounce) {
      return;
    }

    _presenceRequestedAt[normalized] = now;
    _ws.send('presence.ask', {'username': normalized});
  }

  void _refreshWatchedPresence() {
    if (!_ws.isConnected) return;
    for (final username in _presenceByPeer.keys) {
      _requestPresence(username, force: true);
    }
  }

  ValueNotifier<bool> watchPresence(String username) {
    final normalized = _normalizePresenceUsername(username);
    if (normalized.isEmpty) return ValueNotifier(false);
    final notif = _presenceByPeer.putIfAbsent(
      normalized,
      () => ValueNotifier(false),
    );
    // Не теряем запрос, если виджет построился раньше WebSocket: при первом
    // подключении/переподключении _refreshWatchedPresence() запросит статус
    // снова. В build статус также не спамит сервер благодаря debounce.
    _requestPresence(normalized);
    return notif;
  }

  /// Сообщения по peer. Каждый ChatScreen подписывается на свой.
  final Map<String, ValueNotifier<List<StoredMessage>>> _msgsByPeer = {};

  // Прогресс отправки медиа (0..1) по tempSid — для спиннера-% на пузыре.
  final Map<String, ValueNotifier<double>> _uploadProgress = {};
  ValueNotifier<double> uploadProgress(String tempSid) =>
      _uploadProgress.putIfAbsent(tempSid, () => ValueNotifier<double>(0));

  // WS echo can arrive before the send RPC response. Keep a short-lived
  // file-id mapping so the incoming echo promotes the optimistic media bubble
  // instead of inserting a second file/video message.
  final Map<int, String> _pendingMediaTempKeys = {};

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

  /// Кэш одного pubkey (legacy: owner-device) пира в RAM.
  final Map<String, Uint8List> _peerPubCache = {};

  /// Боты не участвуют в E2E (см. bot_api.py на сервере) — кэш "это бот?"
  /// по username, заполняется в _loadPeerKeys вместе с остальным.
  final Map<String, bool> _peerIsBotCache = {};
  final Set<String> _botHistoryReplayScheduled = {};
  final Map<String, int> _botReplyCatchUpAfterSid = {};
  final Set<String> _botReplyCatchUpRunning = {};
  final Map<String, String?> _peerBotStatusCache = {};
  final Map<String, ValueNotifier<String?>> _peerBotStatusNotifiers = {};
  // Несколько экранов/WS-событий могут одновременно запросить информацию о
  // том же peer. Один HTTP-запрос на peer защищает и сервер, и кэши от гонки.
  final Map<String, Future<void>> _peerKeysInFlight = {};
  // Для legacy-входящих сообщений можно безопасно перебрать опубликованные
  // device-pubkey'и: неподходящий ключ даст только GCM/tag failure и не может
  // расшифровать сообщение без соответствующего приватника. Отправка при
  // этом продолжает использовать только TOFU-подтверждённый owner-ключ.
  final Map<String, List<Uint8List>> _peerDecryptPubsCache = {};
  final Map<String, Future<void>> _peerDecryptRefreshInFlight = {};
  final Map<String, DateTime> _lastPeerDecryptRecoveryAt = {};
  static const _peerDecryptRecoveryCooldown = Duration(seconds: 5);
  final Map<String, DateTime> _peerInfoFetchedAt = {};
  static const _peerInfoCacheTtl = Duration(minutes: 5);

  // Блокировки собеседников принадлежат аккаунту, а не устройству. Нужен
  // локальный fallback: сервер может быть временно недоступен, но после
  // нажатия «Заблокировать» сообщения и отправка не должны продолжаться.
  final Set<String> _blockedPeers = <String>{};

  // Local tombstones prevent an old pending/sealed message from recreating a
  // chat after the user deleted it. The marker is account-scoped and only
  // suppresses messages created before the deletion moment; a later message
  // from the same peer can still start a fresh conversation.
  final Map<String, int> _deletedChatCutoffs = <String, int>{};

  String _blockedPeersKey(String username) =>
      'chat_blocked_peers_v1_${username.toLowerCase()}';

  Future<void> _loadBlockedPeers(String username) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _blockedPeers
        ..clear()
        ..addAll(prefs.getStringList(_blockedPeersKey(username)) ?? const []);
    } catch (e) {
      appLog.warn('storage', '[ChatRepo] blocked peers load failed: $e');
    }
  }

  String _deletedChatCutoffsKey(String username) =>
      'chat_deleted_cutoffs_v1_${username.toLowerCase()}';

  Future<void> _loadDeletedChatCutoffs(String username) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_deletedChatCutoffsKey(username));
      if (raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      _deletedChatCutoffs
        ..clear()
        ..addEntries(
          decoded.entries
              .where((entry) {
                return entry.key is String &&
                    entry.value is num &&
                    entry.value > 0;
              })
              .map(
                (entry) => MapEntry(
                  (entry.key as String).trim().toLowerCase(),
                  (entry.value as num).toInt(),
                ),
              ),
        );
    } catch (e) {
      appLog.warn('storage', '[ChatRepo] deleted chat markers load failed: $e');
    }
  }

  Future<void> _saveDeletedChatCutoffs() async {
    try {
      final me = _myUsername ?? await AuthService.username();
      if (me == null || me.trim().isEmpty) return;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _deletedChatCutoffsKey(me),
        jsonEncode(_deletedChatCutoffs),
      );
    } catch (e) {
      appLog.warn('storage', '[ChatRepo] deleted chat markers save failed: $e');
    }
  }

  Future<void> _rememberChatDeleted(String username) async {
    final peer = username.trim().toLowerCase();
    if (peer.isEmpty) return;
    _deletedChatCutoffs[peer] = DateTime.now().toUtc().millisecondsSinceEpoch;
    await _saveDeletedChatCutoffs();
  }

  Future<void> _forgetChatDeleted(String username) async {
    final peer = username.trim().toLowerCase();
    if (_deletedChatCutoffs.remove(peer) == null) return;
    await _saveDeletedChatCutoffs();
  }

  bool _isOlderThanChatDelete(String username, dynamic createdAt) {
    final cutoff = _deletedChatCutoffs[username.trim().toLowerCase()];
    final timestamp = _createdAtMillis(createdAt);
    return cutoff != null && timestamp != null && timestamp <= cutoff;
  }

  bool isPeerBlocked(String username) =>
      _blockedPeers.contains(username.trim().toLowerCase());

  /// Заблокировать собеседника локально и на сервере. Локальное состояние
  /// сохраняем первым, чтобы результат не зависел от сети.
  Future<void> blockPeer(String username) async {
    final peer = username.trim().toLowerCase();
    if (peer.isEmpty) return;
    _blockedPeers.add(peer);
    try {
      final prefs = await SharedPreferences.getInstance();
      final me = _myUsername ?? await AuthService.username();
      if (me != null) {
        await prefs.setStringList(_blockedPeersKey(me), _blockedPeers.toList());
      }
    } catch (e) {
      appLog.warn('storage', '[ChatRepo] blocked peers save failed: $e');
    }
    try {
      await _api.chatPost('/block/${Uri.encodeComponent(peer)}');
      appLog.info('chat', 'peer blocked: @$peer');
    } catch (e) {
      // Серверная ручка появилась позже клиента; local-first блокировка всё
      // равно защищает текущую сессию, а ошибка остаётся видимой в логах.
      appLog.warn('chat', 'server block @$peer failed: $e');
    }
  }

  Future<void> unblockPeer(String username) async {
    final peer = username.trim().toLowerCase();
    _blockedPeers.remove(peer);
    try {
      final prefs = await SharedPreferences.getInstance();
      final me = _myUsername ?? await AuthService.username();
      if (me != null) {
        await prefs.setStringList(_blockedPeersKey(me), _blockedPeers.toList());
      }
    } catch (e) {
      appLog.warn('storage', '[ChatRepo] blocked peers save failed: $e');
    }
    try {
      await _api.chatDelete('/block/${Uri.encodeComponent(peer)}');
      appLog.info('chat', 'peer unblocked: @$peer');
    } catch (e) {
      appLog.warn('chat', 'server unblock @$peer failed: $e');
    }
  }

  /// true если @username — бот-аккаунт (у него нет E2E-ключей вообще, это
  /// осознанно, не ошибка). Дёргает /keys/{username} один раз и кэширует.
  Future<bool> isPeerBot(String username) async {
    final fetchedAt = _peerInfoFetchedAt[username];
    if (_peerIsBotCache.containsKey(username) &&
        fetchedAt != null &&
        DateTime.now().difference(fetchedAt) < _peerInfoCacheTtl) {
      return _peerIsBotCache[username]!;
    }
    await _loadPeerKeys(username);
    return _peerIsBotCache[username] ?? false;
  }

  /// Синхронная версия для рендера списков (без await на каждый row) —
  /// вернёт false, пока кэш ещё не прогрет реальным send/receive с этим
  /// пиром. Достаточно для бейджа "бот" в UI, не блокирует список.
  bool isPeerBotCached(String username) => _peerIsBotCache[username] ?? false;

  bool _isPeerBotKnown(String username) {
    final normalized = username.trim().toLowerCase();
    return _peerIsBotCache[username] ?? _peerIsBotCache[normalized] ?? false;
  }

  void _scheduleBotHistoryReplay(String peer, {required int generation}) {
    final normalized = peer.trim().toLowerCase();
    if (normalized.isEmpty || !_botHistoryReplayScheduled.add(normalized)) {
      return;
    }
    unawaited(() async {
      try {
        // Allow the server to finish publishing the durable row first.
        await Future<void>.delayed(const Duration(milliseconds: 300));
        if (!_isCurrentSession(generation)) return;
        await fetchHistory(generation: generation);
        if (_isCurrentSession(generation)) {
          await fetchPending(generation: generation);
        }
      } finally {
        _botHistoryReplayScheduled.remove(normalized);
      }
    }());
  }

  String? peerBotStatusCached(String username) => _peerBotStatusCache[username];

  ValueListenable<String?> watchBotStatus(String username) =>
      _peerBotStatusNotifiers.putIfAbsent(
        username,
        () => ValueNotifier<String?>(_peerBotStatusCache[username]),
      );

  void _setPeerBotStatus(String username, String? status) {
    final normalized = status == 'online' || status == 'offline'
        ? status
        : null;
    _peerBotStatusCache[username] = normalized;
    final notifier = _peerBotStatusNotifiers[username];
    if (notifier != null && notifier.value != normalized) {
      notifier.value = normalized;
    }
  }

  /// Refresh only the server-maintained bot connection status. The bot API
  /// owns heartbeat expiry; the client never guesses online from a username.
  Future<void> refreshPeerBotStatus(String username) async {
    if (!isPeerBotCached(username)) return;
    try {
      final raw = await _api.chatGet('/keys/${Uri.encodeComponent(username)}');
      if (raw is Map && (raw['is_bot'] == true || raw['is_bot'] == 1)) {
        _setPeerBotStatus(username, raw['bot_status'] as String?);
      }
    } catch (e) {
      appLog.debug('chat', 'Bot status refresh failed for @$username: $e');
    }
  }

  String _notificationSenderName(String username) {
    final dialog = dialogsNotifier.value.where((d) => d.username == username);
    if (dialog.isNotEmpty && dialog.first.displayName.trim().isNotEmpty) {
      return dialog.first.displayName;
    }
    final profile = ProfileCache.instance.getProfileSync(username);
    final displayName = profile?['display_name'] as String?;
    return displayName?.trim().isNotEmpty == true ? displayName! : username;
  }

  /// Аватарка пира (относительный путь, "/media/avatars/xxx.jpg" или null) —
  /// сервер уже отдаёт avatar_url в /keys/{username}, заполняется в
  /// _loadPeerKeys вместе с ключами/is_bot.
  final Map<String, String?> _peerAvatarCache = {};

  /// Синхронная версия для списков. Проверяет ОБА кэша — свой (из
  /// /keys/{username}, прогревается при открытии чата/списка чатов) и
  /// ProfileCache (из /prof/{username}, прогревается визитом на профиль) —
  /// чей бы визит ни прогрел аватарку первым, она сразу видна везде, а не
  /// только там, где именно этот кэш был заполнен.
  String? getPeerAvatarCached(String username) =>
      _nonEmptyAvatar(_peerAvatarCache[username.trim().toLowerCase()]) ??
      _nonEmptyAvatar(_peerAvatarCache[username]) ??
      _nonEmptyAvatar(
        ProfileCache.instance.getProfileSync(
          username.trim().toLowerCase(),
        )?['avatar_url'],
      ) ??
      _nonEmptyAvatar(
        ProfileCache.instance.getProfileSync(username)?['avatar_url'],
      );

  /// Replace the cached avatar after an owner updates a bot's public profile.
  /// Chat-list rows prefer this directory cache over their stale profile copy.
  Future<void> cachePeerAvatar(String username, String? avatarUrl) async {
    final normalizedUsername = username.trim().toLowerCase();
    if (normalizedUsername.isEmpty) return;
    _peerAvatarCache[normalizedUsername] = _nonEmptyAvatar(avatarUrl);
    await _savePeerInfoToDisk();
  }

  static String? _nonEmptyAvatar(Object? value) {
    final text = value?.toString().trim();
    return text == null || text.isEmpty ? null : text;
  }

  /// Прогреть кэш аватарки/бот-флага для пира, если ещё не грели.
  Future<void> warmPeerInfo(String username) async {
    final fetchedAt = _peerInfoFetchedAt[username];
    if (_peerIsBotCache.containsKey(username) &&
        fetchedAt != null &&
        DateTime.now().difference(fetchedAt) < _peerInfoCacheTtl) {
      return;
    }
    await _loadPeerKeys(username);
  }

  static const _kPeerAvatarPrefsKey = 'peer_avatar_cache_v1';
  static const _kPeerIsBotPrefsKey = 'peer_isbot_cache_v1';

  /// Диск-персист _peerAvatarCache/_peerIsBotCache — раньше жили только в
  /// RAM процесса: без сети после холодного старта (перезапуск приложения,
  /// не просто возврат на вкладку) аватарки/бейджи ботов исчезали, хотя уже
  /// были один раз успешно получены с сервера. Офлайн-first требует, чтобы
  /// однажды увиденные данные не пропадали без сети.
  Future<void> _loadPeerInfoFromDisk() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final avaRaw = prefs.getString(_kPeerAvatarPrefsKey);
      if (avaRaw != null) {
        final m = jsonDecode(avaRaw) as Map;
        m.forEach((k, v) => _peerAvatarCache[k as String] = v as String?);
      }
      final botRaw = prefs.getString(_kPeerIsBotPrefsKey);
      if (botRaw != null) {
        final m = jsonDecode(botRaw) as Map;
        m.forEach((k, v) => _peerIsBotCache[k as String] = v as bool);
      }
    } catch (_) {}
  }

  Future<void> _savePeerInfoToDisk() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kPeerAvatarPrefsKey, jsonEncode(_peerAvatarCache));
      await prefs.setString(_kPeerIsBotPrefsKey, jsonEncode(_peerIsBotCache));
    } catch (_) {}
  }

  /// Вызывать при выходе из аккаунта — эти два кэша НЕ per-username (в
  /// отличие от ProfileCache), общий ключ на всё устройство, поэтому на
  /// общем устройстве следующий залогинившийся иначе видел бы список
  /// пиров/ботов предыдущего аккаунта (найдено ревью 2026-07-20).
  Future<void> clearPeerInfoCache() async {
    _peerAvatarCache.clear();
    _peerIsBotCache.clear();
    _peerBotStatusCache.clear();
    for (final notifier in _peerBotStatusNotifiers.values) {
      notifier.value = null;
    }
    _peerInfoFetchedAt.clear();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_kPeerAvatarPrefsKey);
      await prefs.remove(_kPeerIsBotPrefsKey);
    } catch (_) {}
  }

  /// TDA-4: кэш ВСЕХ device-pubkey'ев пира. При peer.devices_changed WS-event
  /// сбрасываем для конкретного юзера.
  final Map<String, List<Uint8List>> _peerDevicePubsCache = {};

  // /pending_sealed вызывается из bootstrap, retry после KeyGate и каждого
  // реконнекта WS. Не допускаем параллельной обработки одного буфера.
  Future<void>? _fetchPendingSealedInFlight;

  // Один и тот же неподдающийся расшифровке sid не должен засыпать лог при
  // каждом реконнекте. Сообщение остаётся на сервере и будет повторено после
  // успешной синхронизации ключей.
  final Set<int> _sealedDecryptFailuresLogged = <int>{};

  /// Кэш моих other-device pubkey'ев (self-echo на свои устройства).
  List<Uint8List> _myOtherDevicePubs = const [];

  /// Подписки WS — для cancel при logout.
  final List<dynamic> _subs = [];
  StreamSubscription<bool>? _wsConnSub; // реконнект WS → догнать pending
  bool _wsSkipFirstConn = true; // первый connect не дублируем (init фетчит сам)

  String? _myUsername;

  bool _initialized = false;
  // Инкрементируется при каждой новой авторизованной сессии. Фоновые fetch
  // могут завершиться уже после logout, поэтому им нельзя позволять записать
  // данные старого аккаунта в notifier нового аккаунта.
  int _sessionGeneration = 0;

  bool _isCurrentSession(int generation) =>
      _initialized && generation == _sessionGeneration;

  /// Синхронный флаг готовности — чтобы ChatListScreen мог на ПЕРВОМ build()
  /// (в field-initializer, до await) понять, нужен ли skeleton, вместо
  /// гарантированного кадра мигания при каждом возврате на вкладку Чатов
  /// (await init(), даже с ранним `if (_initialized) return`, всё равно
  /// уходит минимум на микротаск дальше текущего кадра).
  bool get isInitialized => _initialized;

  Future<String?> currentUsername() async =>
      _myUsername ?? AuthService.username();

  /// Разрешить вход в приложение без завершения проверки ключа. Это только
  /// текущая сессия: при следующем явном восстановлении/настройке проверка
  /// снова включается, а при выходе флаг сбрасывается вместе с сессией.
  void skipKeySyncForSession() {
    _keySyncSkippedForSession = true;
    keySyncNotifier.value = KeySyncOutcome.skipped;
    appLog.info('security', 'key sync skipped for current session');
  }

  /// Вызвать ОДИН раз после login, когда DbService и CryptoService готовы.
  ///
  /// Офлайн-first: список диалогов живёт в SQLite и НЕ должен ждать сеть.
  /// Раньше синхронизация ключей (сетевая, до ~4 последовательных запросов по
  /// 30с таймаут = до ~2 минут) стояла ПЕРЕД загрузкой локальных диалогов —
  /// без интернета UI висел в вечном спиннере. Теперь локальные данные
  /// показываются сразу, а сеть (ключи + pending) синкается в фоне.
  Future<void> init() async {
    if (_initialized) return;
    final generation = ++_sessionGeneration;
    _initialized = true;
    _myUsername = await AuthService.username();
    if (!_isCurrentSession(generation)) return;
    appLog.info('chat', 'ChatRepo init for current session');
    await _loadPeerInfoFromDisk();
    if (_myUsername != null) await _loadBlockedPeers(_myUsername!);
    if (_myUsername != null) {
      await _loadDeletedChatCutoffs(_myUsername!);
    }
    if (!_isCurrentSession(generation)) return;

    // Локальный список диалогов — СРАЗУ, без сети.
    final dialogs = await _db.getDialogs();
    if (!_isCurrentSession(generation)) return;
    dialogsNotifier.value = dialogs;

    // WS подписки — регистрация не требует сети (сама коннекция асинхронна
    // и ретраится в WsClient).
    _subs.addAll([
      _ws.on('chat.new', (d) => _onChatNew(d, generation: generation)),
      _ws.on('chat.echo', (d) => _onChatEcho(d, generation: generation)),
      _ws.on(
        'chat.sealed_new',
        (d) => _onChatSealedNew(d, generation: generation),
      ),
      _ws.on(
        'chat.delivered',
        (d) => _onChatDelivered(d, generation: generation),
      ),
      _ws.on('chat.read', (d) => _onChatRead(d, generation: generation)),
      _ws.on(
        'chat.cleared_by_peer',
        (d) => _onChatClearedByPeer(d, generation: generation),
      ),
      _ws.on('presence', (d) => _onPresence(d, generation: generation)),
      _ws.on(
        'peer.devices_changed',
        (d) => _onPeerDevicesChanged(d, generation: generation),
      ),
      _ws.on('chat.v2.new', (d) => _onChatV2New(d, generation: generation)),
    ]);

    // На КАЖДЫЙ реконнект WS догоняем pending: сообщения, пришедшие пока WS был
    // мёртв (фон/Doze/обрыв сети), иначе теряются → нет уведомления. Первый
    // connect пропускаем — фоновая синхронизация ниже уже фетчит. Идемпотентно
    // (dedup по sid).
    _wsConnSub = _ws.onConnectionChange.listen((connected) {
      if (!connected) {
        // Нельзя оставлять зелёные статусы от старого сокета: до следующего
        // ответа сервера они уже не подтверждены.
        _presenceRequestedAt.clear();
        for (final notif in _presenceByPeer.values) {
          if (notif.value) notif.value = false;
        }
        return;
      }
      // Запросы, отправленные до соединения, были отброшены WsClient. После
      // каждого reconnect заново получаем состояние всех наблюдаемых пиров.
      _refreshWatchedPresence();
      unawaited(_drainDmOutbox(generation));
      if (_wsSkipFirstConn) {
        _wsSkipFirstConn = false;
        return;
      }
      unawaited(fetchPending(generation: generation));
      unawaited(fetchPendingSealed(generation: generation));
      unawaited(fetchPendingV2(generation: generation));
    });

    _outboxRetryTimer ??= Timer.periodic(const Duration(seconds: 5), (_) {
      if (_isCurrentSession(generation)) unawaited(_drainDmOutbox(generation));
    });
    unawaited(_drainDmOutbox(generation));

    // Сеть — ФОНОВО, не блокирует UI. Если офлайн — просто не выполнится,
    // спишет ошибку и не мешает открытому списку локальных чатов.
    _startOwnKeyWatcher(generation);
    unawaited(_syncKeysAndFetchPending(generation));
    appLog.debug(
      'chat',
      'ChatRepo local dialogs loaded; sync started in background',
    );
  }

  /// Сетевая часть bootstrap'а: синхронизация E2E-ключей + догон pending.
  /// Вызывается фоново из init() — не блокирует показ локальных диалогов.
  Future<void> _syncKeysAndFetchPending(int generation) async {
    if (_keySyncSkippedForSession) {
      keySyncNotifier.value = KeySyncOutcome.skipped;
      return;
    }
    // Синхронизация E2E-ключей. Пароль логина (одноразово из AuthService) нужен
    // server-режиму, чтобы ВОССТАНОВИТЬ приватник с сервера, а не сгенерить
    // новый (иначе старая переписка не расшифруется). Режим (server/local) —
    // выбор пользователя из онбординга (pref key_storage_mode).
    // peek, не take — если этот первый автоматический синк не выйдет ok
    // (например транзиентная сетевая ошибка, а не реально неверный пароль),
    // пароль остаётся доступен для одной тихой автопопытки в KeyGate, вместо
    // того чтобы сразу заставлять юзера вводить его заново.
    // The explicit post-login key screen owns password entry. Never silently
    // reuse the login password for server-key recovery from a background task.
    const String? pwd = null;
    final prefs = await SharedPreferences.getInstance();
    final chosenMode = prefs.getString('key_storage_mode');
    final outcome = await syncKeys(password: pwd, chosenMode: chosenMode);
    if (!_isCurrentSession(generation)) return;
    if (_keySyncSkippedForSession) {
      keySyncNotifier.value = KeySyncOutcome.skipped;
      return;
    }
    keySyncNotifier.value = outcome;
    if (keySyncNotifier.value == KeySyncOutcome.ok)
      AuthService.clearPendingPwd();
    appLog.warn('chat', '[ChatRepo] init keySync → ${keySyncNotifier.value}');
    // НЕ откатываемся в local автоматически — раньше это ЗАТИРАЛО настоящий
    // серверный ключ throwaway-ключом. needPassword / needChooseMode теперь
    // перехватывает KeyGate (в MainShell) и дозапрашивает пароль / режим.

    // Догнать накопленное — оба канала.
    unawaited(fetchPending(generation: generation));
    unawaited(fetchPendingSealed(generation: generation));
    // v2: опубликовать identity+device, затем догнать v2-входящие.
    unawaited(
      ensureV2Published(generation: generation).then((_) {
        // The first broken 1.1.25/1.1.26 builds could leave local
        // decrypt_failed placeholders while the ciphertext stayed pending on
        // the server. Run one complete replay after both v1 and v2 key
        // recovery has finished, so old messages are repaired automatically.
        return retryFailedMessages(generation: generation);
      }),
    );
    // TDA-4: подгрузить мои other-device pubkey'и (для self-echo).
    unawaited(_refreshMyOtherDevicePubs());
  }

  Future<void> dispose() async {
    _sessionGeneration++;
    _initialized = false;
    _v2Published = false;
    for (final s in _subs) {
      try {
        await s.cancel();
      } catch (_) {}
    }
    _subs.clear();
    _wsConnSub?.cancel();
    _wsConnSub = null;
    _outboxRetryTimer?.cancel();
    _outboxRetryTimer = null;
    _outboxDrain = null;
    _wsSkipFirstConn = true;
    _peerPubCache.clear();
    _peerDevicePubsCache.clear();
    _peerDecryptPubsCache.clear();
    _peerDecryptRefreshInFlight.clear();
    _lastPeerDecryptRecoveryAt.clear();
    _botHistoryReplayScheduled.clear();
    _botReplyCatchUpAfterSid.clear();
    _botReplyCatchUpRunning.clear();
    _peerKeysInFlight.clear();
    _peerInfoFetchedAt.clear();
    _fetchPendingSealedInFlight = null;
    _fetchHistoryInFlight = null;
    _fetchHistorySealedInFlight = null;
    _sealedDecryptFailuresLogged.clear();
    _v2KeysCache.clear();
    _v2KeysFetchedAt.clear();
    _v2WhoisCache.clear();
    _openChatKeyCheckInFlight = null;
    _lastOwnKeyCheckState = null;
    _lastOwnV2IdentityMismatch = null;
    _lastV2DeviceRepairAt = null;
    _peerIsBotCache.clear();
    _peerBotStatusCache.clear();
    for (final notifier in _peerBotStatusNotifiers.values) {
      notifier.value = null;
    }
    _peerAvatarCache.clear();
    _blockedPeers.clear();
    _deletedChatCutoffs.clear();
    _myOtherDevicePubs = const [];
    _myUsername = null;
    _msgsByPeer.clear();
    _msgsLoadedFromDb.clear();
    _presenceByPeer.clear();
    _presenceRequestedAt.clear();
    _uploadProgress.clear();
    _pendingMediaTempKeys.clear();
    _ownKeyCheckTimer?.cancel();
    _ownKeyCheckTimer = null;
    _keySyncSkippedForSession = false;
    keySyncNotifier.value = KeySyncOutcome.ok;
    dialogsNotifier.value = [];
    appLog.info('chat', 'ChatRepo session state cleared');
  }

  /// Спрашивает у сервера, УЖЕ выбран ли режим хранения ключа для этого
  /// аккаунта — используется на онбординге (main.dart _Router), чтобы не
  /// показывать KeyChoiceScreen заново тому, кто уже выбирал (пусть даже на
  /// другом устройстве — режим общий для аккаунта, не per-device).
  /// null = сервер не ответил ИЛИ режим правда ещё не выбран — в обоих
  /// случаях безопасно (fail-safe) продолжить показывать выбор как раньше.
  Future<String?> fetchServerKeyMode() async {
    try {
      final sm = await _api.chatGet('/keys/storage_mode');
      if (sm is Map) return sm['mode'] as String?;
    } catch (_) {}
    return null;
  }

  void _startOwnKeyWatcher(int generation) {
    _ownKeyCheckTimer?.cancel();
    _ownKeyCheckTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      if (_isCurrentSession(generation)) {
        unawaited(checkOwnKeysForOpenChat('', generation: generation));
      }
    });
    // Do not wait ten seconds for the first consistency check.
    unawaited(checkOwnKeysForOpenChat('', generation: generation));
  }

  /// Получить состояние серверной копии для явного сценария входа. В отличие
  /// от фоновой проверки этот вызов может вернуть зашифрованный blob.
  Future<KeyServerState> fetchServerKeyState() async {
    final raw = await _api.chatGet('/keys/me');
    if (raw is! Map) throw StateError('Некорректный ответ состояния ключа');
    return KeyServerState.fromMap(Map<String, dynamic>.from(raw));
  }

  /// Metadata-only проверка для фонового watcher'а. Старый сервер не имеет
  /// /keys/status, поэтому до его обновления есть совместимый fallback.
  Future<KeyServerState> fetchServerKeyStatus() async {
    try {
      final raw = await _api.chatGet('/keys/status');
      if (raw is Map) {
        return KeyServerState.fromMap(Map<String, dynamic>.from(raw));
      }
    } catch (_) {
      // Legacy server fallback; monitoring must not break the chat.
    }
    return fetchServerKeyState();
  }

  /// Подготовить account-scoped состояние перед новым входом.
  /// Серверный режим не должен обходить повторный запрос пароля, если на
  /// сервере уже есть зашифрованная копия. Локальный ключ до успешного
  /// восстановления не удаляем: ошибочный пароль не должен лишать его.
  Future<KeyServerState> prepareKeySetupForLogin() async {
    final account = _myUsername ?? await AuthService.username();
    if (account == null || account.trim().isEmpty) {
      throw StateError('Аккаунт не найден');
    }
    final state = await fetchServerKeyState();
    return state;
  }

  Future<void> _saveKeySetupMode(String mode) async {
    final normalized = mode.trim().toLowerCase();
    if (normalized != 'local' && normalized != 'server') {
      throw ArgumentError('Unsupported key storage mode');
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('key_storage_mode', normalized);
    await prefs.setBool('keychoice_done', true);
  }

  /// Upload the complete server-mode state and read it back immediately.
  /// This catches a backend that silently discards key-format metadata.
  Future<void> _uploadServerKey({
    required String account,
    required String password,
    required String publicKey,
  }) async {
    final blob = await _crypto.exportEncryptedPrivForServer(
      password,
      account: account,
    );
    await _api.chatPost('/keys/upload', {
      'x25519_pub': publicKey,
      'encrypted_private_key': blob['encrypted_private_key'],
      'key_salt': blob['key_salt'],
      'key_kdf': blob['key_kdf'],
      'key_format': blob['key_format'],
      'storage_mode': 'server',
    });
    final saved = await fetchServerKeyState();
    if (!saved.hasServerCopy ||
        saved.publicKey != publicKey ||
        saved.keyKdf != blob['key_kdf'] ||
        saved.keyFormat != blob['key_format']) {
      throw StateError(
        'Сервер не подтвердил сохранение ключа в полном формате',
      );
    }
  }

  /// Завершить явный сценарий после входа.
  /// При [createNew] вызывающий экран обязан показать предупреждение о старой
  /// зашифрованной истории до вызова этого метода.
  Future<KeySyncOutcome> completeKeySetup({
    required String mode,
    required bool createNew,
    String? password,
    KeyServerState? knownState,
  }) async {
    _keySyncSkippedForSession = false;
    final account = _myUsername ?? await AuthService.username();
    if (account == null || account.trim().isEmpty) return KeySyncOutcome.error;
    final normalizedMode = mode.trim().toLowerCase();
    if (normalizedMode != 'local' && normalizedMode != 'server') {
      return KeySyncOutcome.error;
    }
    try {
      if (!createNew && normalizedMode == 'server') {
        final state = knownState ?? await fetchServerKeyState();
        if (!state.hasServerCopy) {
          if (password == null || password.isEmpty) {
            return KeySyncOutcome.serverCopyMissing;
          }
          final publicKey = base64Encode(
            await _crypto.myPublicKeyRaw(account: account),
          );
          if (state.publicKey != null &&
              state.publicKey!.isNotEmpty &&
              state.publicKey != publicKey) {
            return KeySyncOutcome.keyMismatch;
          }
          await _uploadServerKey(
            account: account,
            password: password,
            publicKey: publicKey,
          );
        } else {
          if (state.publicKey == null || state.publicKey!.isEmpty) {
            return KeySyncOutcome.error;
          }
          if (password == null || password.isEmpty) {
            return KeySyncOutcome.needPassword;
          }
          late final String recovered;
          try {
            recovered = base64Encode(
              await _crypto.importServerPriv(
                state.encryptedPrivateKey!,
                state.keySalt!,
                password,
                account: account,
                keyKdf: state.keyKdf,
                keyFormat: state.keyFormat,
              ),
            );
          } catch (e) {
            appLog.warn('security', 'server key recovery failed: $e');
            return KeySyncOutcome.needPassword;
          }
          if (recovered != state.publicKey) {
            await _crypto.deleteStoredKeys(account: account);
            appLog.warn(
              'security',
              'server key recovery public-key verification failed',
            );
            return KeySyncOutcome.keyMismatch;
          }
          // Старые production-записи могли сохранить blob без metadata.
          // После успешной проверки пароля безопасно перезаписываем копию в
          // актуальном формате, не меняя сам приватный ключ.
          if (state.keyKdf != CryptoService.serverKeyKdfArgon2id ||
              state.keyFormat != CryptoService.serverKeyFormatV2) {
            await _uploadServerKey(
              account: account,
              password: password,
              publicKey: state.publicKey!,
            );
          }
        }
      } else {
        if (createNew) await _crypto.deleteStoredKeys(account: account);
        final pubB64 = base64Encode(
          await _crypto.myPublicKeyRaw(account: account),
        );
        if (normalizedMode == 'server') {
          if (password == null || password.isEmpty)
            return KeySyncOutcome.needPassword;
          await _uploadServerKey(
            account: account,
            password: password,
            publicKey: pubB64,
          );
        } else {
          await _api.chatPost('/keys/upload', {
            'x25519_pub': pubB64,
            'storage_mode': 'local',
          });
        }
      }
      await _saveKeySetupMode(normalizedMode);
      AuthService.clearPendingPwd();
      keySyncNotifier.value = KeySyncOutcome.ok;
      _peerPubCache.clear();
      return KeySyncOutcome.ok;
    } catch (e) {
      appLog.warn('security', 'explicit key setup failed: $e');
      return KeySyncOutcome.error;
    }
  }

  /// Явная смена места хранения из настроек. Ни один шаг не удаляет старую
  /// серверную копию до успешной верификации нового состояния.
  Future<KeySyncOutcome> changeKeyStorageMode({
    required String targetMode,
    required String password,
  }) async {
    _keySyncSkippedForSession = false;
    final account = _myUsername ?? await AuthService.username();
    if (account == null || account.trim().isEmpty || password.isEmpty) {
      return KeySyncOutcome.needPassword;
    }
    final normalized = targetMode.trim().toLowerCase();
    if (normalized != 'local' && normalized != 'server') {
      return KeySyncOutcome.error;
    }
    try {
      final state = await fetchServerKeyState();
      if (normalized == 'local' && state.hasServerCopy) {
        final serverPub = state.publicKey;
        if (serverPub == null || serverPub.isEmpty) return KeySyncOutcome.error;
        final recovered = base64Encode(
          await _crypto.importServerPriv(
            state.encryptedPrivateKey!,
            state.keySalt!,
            password,
            account: account,
            keyKdf: state.keyKdf,
            keyFormat: state.keyFormat,
          ),
        );
        if (recovered != serverPub) {
          await _crypto.deleteStoredKeys(account: account);
          return KeySyncOutcome.needPassword;
        }
      } else if (normalized == 'server' && state.hasServerCopy) {
        final serverPub = state.publicKey;
        if (serverPub == null || serverPub.isEmpty) return KeySyncOutcome.error;
        final recovered = base64Encode(
          await _crypto.importServerPriv(
            state.encryptedPrivateKey!,
            state.keySalt!,
            password,
            account: account,
            keyKdf: state.keyKdf,
            keyFormat: state.keyFormat,
          ),
        );
        if (recovered != serverPub) {
          await _crypto.deleteStoredKeys(account: account);
          return KeySyncOutcome.needPassword;
        }
      } else {
        // In local mode this loads existing secure-storage material; if none
        // exists, ensureKeys creates a new pair explicitly at this point.
        await _crypto.myPublicKeyRaw(account: account);
      }

      final pubB64 = base64Encode(
        await _crypto.myPublicKeyRaw(account: account),
      );
      if (normalized == 'server') {
        await _uploadServerKey(
          account: account,
          password: password,
          publicKey: pubB64,
        );
      } else {
        await _api.chatPost('/keys/upload', {
          'x25519_pub': pubB64,
          'storage_mode': 'local',
        });
      }
      await _saveKeySetupMode(normalized);
      keySyncNotifier.value = KeySyncOutcome.ok;
      return KeySyncOutcome.ok;
    } catch (e) {
      appLog.warn('security', 'key storage mode change failed: $e');
      return KeySyncOutcome.error;
    }
  }

  /// KeyGate → пользователь ввёл пароль / выбрал режим. Повторяем синхронизацию;
  /// при успехе догоняем входящие (которые могли не расшифроваться без ключа).
  Future<KeySyncOutcome> retryKeySync({
    String? password,
    String? chosenMode,
  }) async {
    _keySyncSkippedForSession = false;
    final outcome = await syncKeys(password: password, chosenMode: chosenMode);
    if (chosenMode != null && outcome == KeySyncOutcome.ok) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('key_storage_mode', chosenMode);
      await prefs.setBool('keychoice_done', true);
    }
    keySyncNotifier.value = outcome;
    if (outcome == KeySyncOutcome.ok) {
      // v1 recovery alone does not unlock the current v2 message path.
      final v2Ready = await ensureV2Published(password: password);
      if (!v2Ready) {
        appLog.warn(
          'security',
          'v2 identity/device recovery is still pending after key sync',
        );
      }
      await fetchHistory();
      await fetchHistorySealed();
      unawaited(fetchPending());
      unawaited(fetchPendingSealed());
      unawaited(fetchPendingV2());
    }
    return outcome;
  }

  /// Проверить ключ текущего аккаунта, пока открыт личный чат.
  ///
  /// Это read/repair-проверка, а не ротация: локальный private key никогда не
  /// удаляется и новая пара автоматически не генерируется. В server-режиме,
  /// если сервер сообщает другую identity и пароль логина ещё доступен в RAM,
  /// безопасно восстанавливаем серверную пару и повторяем pending. Если
  /// пароля нет, KeyGate попросит его у пользователя.
  Future<void> checkOwnKeysForOpenChat(String peer, {int? generation}) {
    final session = generation ?? _sessionGeneration;
    final normalizedPeer = peer.trim().toLowerCase();
    if (!_isCurrentSession(session) || normalizedPeer.startsWith('g:')) {
      return Future.value();
    }
    final existing = _openChatKeyCheckInFlight;
    if (existing != null) return existing;

    late final Future<void> tracked;
    tracked = _checkOwnKeysForOpenChatOnce(normalizedPeer, session)
        .whenComplete(() {
          if (identical(_openChatKeyCheckInFlight, tracked)) {
            _openChatKeyCheckInFlight = null;
          }
        });
    _openChatKeyCheckInFlight = tracked;
    return tracked;
  }

  Future<void> _checkOwnKeysForOpenChatOnce(String peer, int session) async {
    if (_keySyncSkippedForSession) return;
    if (!_isCurrentSession(session)) return;
    final account = _myUsername ?? await AuthService.username();
    if (account == null || account.trim().isEmpty) return;

    Map<String, dynamic> me;
    try {
      final state = await fetchServerKeyStatus();
      if (!_isCurrentSession(session)) return;
      me = {
        'storage_mode': state.mode,
        'x25519_pub': state.publicKey,
        'has_server_key': state.hasServerCopy,
        'key_kdf': state.keyKdf,
        'key_format': state.keyFormat,
      };
    } catch (e) {
      appLog.warn('crypto', '[ChatRepo] own key check failed in @$peer: $e');
      return;
    }

    final mode = (me['storage_mode'] as String?)?.trim().toLowerCase();
    final serverPub = (me['x25519_pub'] as String?)?.trim();
    final hasServerCopy = me['has_server_key'] == true;
    final localPub = await _crypto.privateKeyPublicRaw(account: account);
    if (!_isCurrentSession(session)) return;
    if (_keySyncSkippedForSession) return;

    // In local mode a secondary device is intentionally allowed to have a
    // different device pub than users.x25519_pub (the owner pub). Comparing
    // those two values would report a false mismatch on every tick.
    if (mode == 'server') {
      final localPubB64 = localPub == null ? null : base64Encode(localPub);
      final matches =
          localPubB64 != null &&
          serverPub != null &&
          serverPub.isNotEmpty &&
          localPubB64 == serverPub;
      if (!matches) {
        final mismatchState = localPubB64 == null
            ? 'local-private-missing'
            : serverPub == null || serverPub.isEmpty
            ? 'server-public-missing'
            : 'server-public-differs';
        final fingerprint =
            '$mismatchState|$serverPub|${me['has_server_key']}|'
            '${me['key_kdf']}|${me['key_format']}';
        if (_lastOwnKeyCheckState != fingerprint) {
          _lastOwnKeyCheckState = fingerprint;
          appLog.warn(
            'security',
            'own E2E key mismatch while in @$peer ($mismatchState)',
          );
        }

        // A changed public key is never accepted silently. The user must first
        // confirm the update; only then does KeyGate ask for the password.
        keySyncNotifier.value = hasServerCopy
            ? KeySyncOutcome.needUpdateConfirm
            : KeySyncOutcome.keyMismatch;
      } else {
        if (_lastOwnKeyCheckState != null) {
          appLog.info('security', 'own E2E key matches server again');
          _lastOwnKeyCheckState = null;
        }
        if (keySyncNotifier.value == KeySyncOutcome.needPassword ||
            keySyncNotifier.value == KeySyncOutcome.needUpdateConfirm ||
            keySyncNotifier.value == KeySyncOutcome.keyMismatch) {
          keySyncNotifier.value = KeySyncOutcome.ok;
        }
      }
    }

    await _checkOwnV2KeyForOpenChat(account, peer, session);
  }

  Future<void> _checkOwnV2KeyForOpenChat(
    String account,
    String peer,
    int session,
  ) async {
    if (!_isCurrentSession(session)) return;
    try {
      // После смены аккаунта CryptoV2 может ещё держать identity предыдущего
      // аккаунта в памяти. Грузим account-scoped bundle перед сравнением.
      await CryptoV2.instance.ensureKeys(account: account);
      if (!CryptoV2.instance.ready || !_isCurrentSession(session)) return;
      final raw = await _api.chatGet(
        '/v2/keys/${Uri.encodeComponent(account.trim().toLowerCase())}',
      );
      if (!_isCurrentSession(session) || raw is! Map) return;
      final m = Map<String, dynamic>.from(raw);
      final serverIdentity = m['identity_pub'] as String?;
      if (serverIdentity == null || serverIdentity.isEmpty) {
        _lastOwnV2IdentityMismatch = null;
        // Existing local identity is safe to publish; this is not a key
        // rotation and does not replace any private material.
        await ensureV2Published(generation: session);
        return;
      }
      bool identityMatches = false;
      try {
        // Сравниваем байты, а не текст base64: это не даёт ложного mismatch
        // из-за padding/варианта представления строки от старого клиента.
        identityMatches = listEquals(
          base64Decode(serverIdentity),
          CryptoV2.instance.identityPub,
        );
      } catch (_) {}
      if (!identityMatches) {
        // The account-scoped namespace was introduced after the first v2
        // client. If this phone still has the original global bundle, adopt
        // it only after the server confirms the identity belongs to this
        // account. Otherwise the watcher would stop here and never republish
        // the missing device, so v2 messages from other users would have no
        // delivery target.
        identityMatches = await CryptoV2.instance.adoptLegacyKeysIfMatching(
          account: account,
          expectedIdentityB64: serverIdentity,
        );
      }
      if (!identityMatches) {
        final mismatch =
            '$account|$serverIdentity|${CryptoV2.instance.identityPubB64}';
        if (_lastOwnV2IdentityMismatch != mismatch) {
          _lastOwnV2IdentityMismatch = mismatch;
          appLog.warn(
            'security',
            'own v2 identity differs from server while in @$peer; recovery required',
          );
        }
        return;
      }
      _lastOwnV2IdentityMismatch = null;
      final devices = (m['devices'] as List?) ?? const [];
      final hasCurrentDevice = devices.any((rawDevice) {
        if (rawDevice is! Map) return false;
        return rawDevice['device_pub'] == CryptoV2.instance.devicePubB64;
      });
      if (!hasCurrentDevice) {
        final now = DateTime.now();
        if (_lastV2DeviceRepairAt == null ||
            now.difference(_lastV2DeviceRepairAt!) >=
                const Duration(seconds: 30)) {
          _lastV2DeviceRepairAt = now;
          await _api.chatPost('/v2/device/publish', {
            'device_pub': CryptoV2.instance.devicePubB64,
            'signed_prekey_sig': base64.encode(
              await CryptoV2.instance.signedPrekeySig(),
            ),
          });
          _v2Published = true;
          appLog.info('security', 'own v2 device key republished');
        }
      }
    } catch (e) {
      appLog.warn('crypto', '[ChatRepo] own v2 key check failed in @$peer: $e');
    }
  }

  /// Перегенерировать E2E-пару заново (новый приват + новый паблик), залить
  /// на сервер именно через V2. Все ранее зашифрованные сообщения от пиров
  /// СТАНУТ нечитаемыми — это nuclear option для случая когда ничего больше
  /// не помогает.
  Future<String> regenerateKeys({String? password}) async {
    try {
      final account = _myUsername ?? await AuthService.username();
      if (account == null || account.trim().isEmpty) {
        return 'Не найден аккаунт для ротации V2-ключей.';
      }
      await CryptoV2.instance.regenerateKeys(account: account);
      await CryptoV2.instance.ensureKeys(account: account);
      await _api.chatPost('/v2/identity/rotate', {
        'identity_pub': CryptoV2.instance.identityPubB64,
        'proof_signature': base64.encode(
          await CryptoV2.instance.proofSignature(),
        ),
      });
      await _api.chatPost('/v2/device/publish', {
        'device_pub': CryptoV2.instance.devicePubB64,
        'signed_prekey_sig': base64.encode(
          await CryptoV2.instance.signedPrekeySig(),
        ),
      });
      _v2Published = true;
      _v2KeysFetchedAt.clear();
      _peerPubCache.clear();
      return 'Новая V2-пара ключей опубликована.';
    } catch (e) {
      return 'Не удалось перегенерить: $e';
    }
  }

  // ─── Синхронизация E2E-ключей (storage_mode-aware, зеркало web ensureKeys) ──
  /// Безопасная замена старого _publishMyPubKey. Порядок (как договорились):
  ///   1) ПУБЛИЧНЫЙ: локальный pub ↔ серверный — НЕ затираем сервер своим в чужом
  ///      режиме и НЕ шлём заглушку-приватник;
  ///   2) ПРИВАТНЫЙ: трогаем только в server-режиме (там приватник под паролем
  ///      лежит на сервере) — сверяем / восстанавливаем / публикуем.
  ///
  /// [password]   — пароль аккаунта (нужен только server-режиму).
  /// [chosenMode] — выбор из модалки, если режим ещё не выбран.
  Future<KeySyncOutcome> syncKeys({
    String? password,
    String? chosenMode,
  }) async {
    if (_keySyncSkippedForSession && password == null && chosenMode == null) {
      return KeySyncOutcome.skipped;
    }
    try {
      final account = _myUsername ?? await AuthService.username();
      var myPubB64 = base64Encode(
        await _crypto.myPublicKeyRaw(account: account),
      );

      // Режим хранения приватника.
      String? mode;
      bool serverReachable = true;
      try {
        final sm = await _api.chatGet('/keys/storage_mode');
        if (sm is Map) mode = sm['mode'] as String?;
      } catch (_) {
        serverReachable = false;
      }
      // Не используем голый POST /keys/storage_mode: старый endpoint мог
      // очистить серверную копию без проверки пароля. Переход выполняется
      // атомарным /keys/upload в completeKeySetup/settings flow.
      if (chosenMode != null && chosenMode != mode && serverReachable) {
        mode = chosenMode;
      }
      // БАГ-ФИКС: транзиентная сетевая ошибка (сервер недоступен) — это НЕ то
      // же самое, что "режим не выбран". Раньше любой сбой GET/POST на этом
      // шаге заставлял снова показывать KeyChoiceScreen, что на нестабильной
      // сети превращалось в "спрашивает каждый час". Доверяем локально
      // сохранённому выбору (SharedPreferences key_storage_mode), пока сервер
      // не подтвердит/не опровергнет его явно (ответом, а не ошибкой).
      if (mode == null && !serverReachable && chosenMode != null) {
        mode = chosenMode;
      }
      if (mode == null) return KeySyncOutcome.needChooseMode;

      // Текущее состояние ключей на сервере.
      String? serverPub, encPriv, keySalt, keyKdf, keyFormat;
      try {
        final me = await _api.chatGet('/keys/me');
        if (me is Map) {
          serverPub = me['x25519_pub'] as String?;
          encPriv = me['encrypted_private_key'] as String?;
          keySalt = me['key_salt'] as String?;
          keyKdf = me['key_kdf'] as String?;
          keyFormat = me['key_format'] as String?;
        }
      } catch (_) {}

      // Recover a pre-v4 global key only when the server confirms that this
      // exact public key belongs to the current account. Never migrate based
      // on login order.
      if (serverPub != null && serverPub.isNotEmpty) {
        final account = _myUsername;
        final currentPub = base64Encode(
          await _crypto.myPublicKeyRaw(account: account),
        );
        if (currentPub != serverPub &&
            account != null &&
            await _crypto.adoptLegacyKeysIfMatching(
              account: account,
              expectedPubB64: serverPub,
            )) {
          myPubB64 = serverPub;
        }
      }

      return mode == 'server'
          ? await _syncServerMode(
              myPubB64,
              serverPub,
              encPriv,
              keySalt,
              password,
              keyKdf,
              keyFormat,
            )
          : await _syncLocalMode(myPubB64, serverPub);
    } catch (e) {
      appLog.warn('chat', '[ChatRepo] syncKeys error: $e');
      return KeySyncOutcome.error;
    }
  }

  /// server-режим: одна identity на всех устройствах, приватник под паролем
  /// лежит на сервере. Сверяем pub → восстанавливаем/публикуем приватник.
  Future<KeySyncOutcome> _syncServerMode(
    String myPubB64,
    String? serverPub,
    String? encPriv,
    String? keySalt,
    String? password,
    String? keyKdf,
    String? keyFormat,
  ) async {
    final hasServerPub = serverPub != null && serverPub.isNotEmpty;
    final hasServerCopy =
        encPriv != null &&
        encPriv.isNotEmpty &&
        keySalt != null &&
        keySalt.isNotEmpty;

    // Совпадающий pub без encrypted blob — рассинхрон состояния, а не успех.
    if (hasServerPub && serverPub == myPubB64) {
      if (hasServerCopy) return KeySyncOutcome.ok;
      if (password == null) return KeySyncOutcome.serverCopyMissing;
      await _uploadServerKey(
        account: _myUsername!,
        password: password,
        publicKey: myPubB64,
      );
      _peerPubCache.clear();
      return KeySyncOutcome.ok;
    }

    // Другой pub без серверной копии нельзя принимать или перезаписывать
    // автоматически: сначала нужен явный выбор пользователя.
    if (hasServerPub && !hasServerCopy) return KeySyncOutcome.keyMismatch;

    // На сервере ДРУГАЯ identity с восстановимым приватником → принимаем серверную.
    if (hasServerPub && hasServerCopy) {
      if (password == null) return KeySyncOutcome.needPassword;
      try {
        final recovered = base64Encode(
          await _crypto.importServerPriv(
            encPriv,
            keySalt,
            password,
            account: _myUsername,
            keyKdf: keyKdf,
            keyFormat: keyFormat,
          ),
        );
        _peerPubCache.clear();
        if (recovered != serverPub) {
          // Восстановленный приватник не даёт серверный pub — битый блоб
          // (например наша же старая заглушка). Нужен ручной перезалив.
          appLog.warn('chat', 'recovered pub != server pub (битый блоб?)');
          return KeySyncOutcome.needPassword;
        }
        if (keyKdf != CryptoService.serverKeyKdfArgon2id ||
            keyFormat != CryptoService.serverKeyFormatV2) {
          await _uploadServerKey(
            account: _myUsername!,
            password: password,
            publicKey: serverPub,
          );
        }
        appLog.info('chat', 'server-режим: приватник восстановлен с сервера');
        return KeySyncOutcome.ok;
      } catch (e) {
        appLog.warn('chat', 'importServerPriv failed (пароль?): $e');
        return KeySyncOutcome.needPassword;
      }
    }

    // Сервер пуст / без приватника → публикуем НАШ приватник зашифрованным паролем.
    if (password == null) return KeySyncOutcome.needPassword;
    await _uploadServerKey(
      account: _myUsername!,
      password: password,
      publicKey: myPubB64,
    );
    _peerPubCache.clear();
    appLog.info('chat', 'server-режим: приватник опубликован на сервер');
    return KeySyncOutcome.ok;
  }

  /// local-режим: приватник НИКОГДА не уходит с устройства. На сервер — только
  /// pub. Бэкенд сам решает: owner-device обновит users.x25519_pub, доп.устройство
  /// зарегистрирует свой device-pub, НЕ трогая owner-pub. Заглушек нет.
  Future<KeySyncOutcome> _syncLocalMode(
    String myPubB64,
    String? serverPub,
  ) async {
    if (serverPub == myPubB64) return KeySyncOutcome.ok; // уже в синхроне
    await _api.chatPost('/keys/upload', {
      'x25519_pub': myPubB64,
      'storage_mode': 'local',
    });
    _peerPubCache.clear();
    appLog.info('chat', 'local-режим: pub опубликован (без приватника)');
    return KeySyncOutcome.ok;
  }

  /// При получении envelope, которую не можем расшифровать (InvalidCipherText),
  /// возможно у пира сменился pubkey. Сбрасываем кэш, но не блокируем обработку
  /// входящего сообщения сетевым таймаутом: повторная загрузка выполняется
  /// одним запросом на peer, а pending будет догнан после его завершения.
  Future<void> _refreshPeerPubAfterDecryptFail(String username) {
    final normalized = username.trim().toLowerCase();
    final existing = _peerDecryptRefreshInFlight[normalized];
    if (existing != null) return existing;

    late final Future<void> tracked;
    tracked = _refreshPeerPubAfterDecryptFailOnce(normalized).whenComplete(() {
      if (identical(_peerDecryptRefreshInFlight[normalized], tracked)) {
        _peerDecryptRefreshInFlight.remove(normalized);
      }
    });
    _peerDecryptRefreshInFlight[normalized] = tracked;
    return tracked;
  }

  Future<void> _refreshPeerPubAfterDecryptFailOnce(String username) async {
    _peerPubCache.remove(username);
    _peerDevicePubsCache.remove(username);
    _peerDecryptPubsCache.remove(username);
    _v2KeysCache.remove(username);
    _v2KeysFetchedAt.remove(username);
    try {
      // Перетягиваем состояние с сервера, но не переписываем TOFU pin молча.
      final r = await _api.chatGet('/keys/$username');
      final pubB64 = (r as Map)['x25519_pub'] as String?;
      if (pubB64 != null && pubB64.isNotEmpty) {
        final pinned = await _db.getPinnedPub(username);
        if (pinned != null && pinned != pubB64) {
          // A changed peer key is not an automatic recovery path: a malicious
          // or compromised server could otherwise redirect new ciphertext to
          // an attacker. Keep the previously trusted key until the user or a
          // separately authenticated v2 identity confirms a rotation.
          final oldRaw = Uint8List.fromList(base64Decode(pinned));
          _peerPubCache[username] = oldRaw;
          _peerDevicePubsCache[username] = [oldRaw];
          _peerDecryptPubsCache[username] = [oldRaw];
          appLog.warn(
            'security',
            'peer public key changed for @$username; old TOFU pin retained',
          );
          return;
        }
        if (pinned == null) {
          await _db.pinPub(username, pubB64, accepted: true);
        }
        final ownerRaw = Uint8List.fromList(base64Decode(pubB64));
        _peerPubCache[username] = ownerRaw;
        _peerDevicePubsCache[username] = [ownerRaw];
        appLog.info(
          'chat',
          pinned == null
              ? 'закрепили первый ключ @$username'
              : 'ключ @$username совпал с TOFU pin',
        );
      }
    } catch (e) {
      appLog.warn('chat', '[ChatRepo] re-pin failed: $e');
    }
  }

  void _schedulePeerDecryptRecovery(String username, {int? generation}) {
    final session = generation ?? _sessionGeneration;
    final normalized = username.trim().toLowerCase();
    if (!_isCurrentSession(session) || normalized.isEmpty) return;
    if (_peerDecryptRefreshInFlight.containsKey(normalized)) return;

    final now = DateTime.now();
    final last = _lastPeerDecryptRecoveryAt[normalized];
    if (last != null && now.difference(last) < _peerDecryptRecoveryCooldown) {
      return;
    }
    _lastPeerDecryptRecoveryAt[normalized] = now;

    // Не задерживаем появление сообщения сетевым запросом /keys. После
    // успешного refresh один раз догоняем pending; повторные ошибки в течение
    // cooldown не запускают цепочку запросов по одному на каждое сообщение.
    unawaited(
      _refreshPeerPubAfterDecryptFail(normalized)
          .then((_) {
            if (_isCurrentSession(session)) {
              return fetchPending(generation: session);
            }
          })
          .catchError((Object e, StackTrace _) {
            appLog.warn(
              'chat',
              '[decrypt recovery] key refresh failed for @$normalized: $e',
            );
          }),
    );
  }

  // ─── Получение чужого pubkey (с кэшем) ───────────────────────────────
  Future<Uint8List> getPeerPub(String username) async {
    if (_peerPubCache.containsKey(username)) return _peerPubCache[username]!;
    await _loadPeerKeys(username);
    return _peerPubCache[username]!;
  }

  /// Получить доверенные v1-pubkey'и пира. В legacy v1 это только закреплённый
  /// owner-ключ: список устройств без подписи не используется для fan-out.
  /// Подписанные v2-устройства идут отдельным Signal-style путём.
  Future<List<Uint8List>> getPeerDevicePubs(String username) async {
    if (_peerDevicePubsCache.containsKey(username)) {
      return _peerDevicePubsCache[username]!;
    }
    await _loadPeerKeys(username);
    return _peerDevicePubsCache[username] ?? [_peerPubCache[username]!];
  }

  /// Ключи только для входящей legacy-расшифровки. Сервер может прислать
  /// несколько активных device-pubkey'ев, а сообщение могло быть зашифровано
  /// под устройством, которое не является owner. Эти ключи не используются
  /// для отправки и не заменяют TOFU owner-ключ.
  Future<List<Uint8List>> _getPeerDecryptPubs(String username) async {
    final cached = _peerDecryptPubsCache[username];
    if (cached != null && cached.isNotEmpty) return cached;
    await _loadPeerKeys(username);
    return _peerDecryptPubsCache[username] ?? getPeerDevicePubs(username);
  }

  /// Пробует расшифровать конверт ВСЕМИ известными ключами отправителя
  /// (device_pubkeys + owner). У мульти-девайс отправителя сообщение
  /// зашифровано приватником ОДНОГО устройства — подходит ровно один pub,
  /// поэтому одного owner-ключа (getPeerPub) мало. Возвращает plaintext JSON
  /// или null, если не подошёл ни один ключ.
  Future<String?> _tryDecryptAnyPub(String peerUsername, String cipher) async {
    final pubs = <Uint8List>[];
    try {
      pubs.addAll(await _getPeerDecryptPubs(peerUsername));
    } catch (_) {}
    try {
      final owner = await getPeerPub(peerUsername);
      if (!pubs.any((pub) => listEquals(pub, owner))) pubs.add(owner);
    } catch (_) {}
    final stopwatch = Stopwatch()..start();
    for (var index = 0; index < pubs.length; index++) {
      final pub = pubs[index];
      try {
        final plain = await _crypto.decryptFrom(
          theirPubRaw: pub,
          envelopeB64: cipher,
        );
        appLog.debug(
          'crypto',
          'legacy decrypt @$peerUsername succeeded in '
              '${stopwatch.elapsedMilliseconds}ms with key ${index + 1}/${pubs.length}',
        );
        return plain;
      } catch (_) {
        // не тот ключ — пробуем следующий
      }
    }
    appLog.warn(
      'crypto',
      'legacy decrypt @$peerUsername failed in '
          '${stopwatch.elapsedMilliseconds}ms after ${pubs.length} key(s)',
    );
    return null;
  }

  Future<void> _loadPeerKeys(String username) {
    final existing = _peerKeysInFlight[username];
    if (existing != null) return existing;

    late final Future<void> tracked;
    tracked = _loadPeerKeysOnce(username).whenComplete(() {
      if (identical(_peerKeysInFlight[username], tracked)) {
        _peerKeysInFlight.remove(username);
      }
    });
    _peerKeysInFlight[username] = tracked;
    return tracked;
  }

  Future<void> _loadPeerKeysOnce(String username) async {
    final r = await _api.chatGet('/keys/$username');
    final m = r is Map ? r : const {};
    final isBot = (m['is_bot'] as bool?) ?? false;
    _peerIsBotCache[username] = isBot;
    _setPeerBotStatus(username, isBot ? m['bot_status'] as String? : null);
    _peerAvatarCache[username] = m['avatar_url'] as String?;
    _peerInfoFetchedAt[username] = DateTime.now();
    unawaited(_savePeerInfoToDisk());
    if (isBot) return; // боты не публикуют E2E-ключи — это ожидаемо, не ошибка.
    final ownerPubB64 = m['x25519_pub'] as String?;
    final devicesRaw = (m['device_pubkeys'] as List?) ?? const [];
    if ((ownerPubB64 == null || ownerPubB64.isEmpty) && devicesRaw.isEmpty) {
      throw Exception('У @$username нет E2E-ключей');
    }
    // Owner-pubkey — для legacy compat и TOFU pinning.
    Uint8List ownerRaw;
    if (ownerPubB64 != null && ownerPubB64.isNotEmpty) {
      ownerRaw = Uint8List.fromList(base64Decode(ownerPubB64));
    } else {
      ownerRaw = Uint8List.fromList(base64Decode(devicesRaw.first as String));
    }
    final pinnedOwner = ownerPubB64 == null
        ? null
        : await _db.getPinnedPub(username);
    if (ownerPubB64 != null &&
        pinnedOwner != null &&
        pinnedOwner != ownerPubB64) {
      // Do not put an untrusted server-supplied replacement into the active
      // decryption/send cache. The old pin remains the only legacy v1 key.
      try {
        final pinnedRaw = Uint8List.fromList(base64Decode(pinnedOwner));
        _peerPubCache[username] = pinnedRaw;
        _peerDevicePubsCache[username] = [pinnedRaw];
      } catch (_) {
        _peerPubCache.remove(username);
        _peerDevicePubsCache.remove(username);
      }
      appLog.warn(
        'security',
        'server returned a changed TOFU key for @$username; replacement rejected',
      );
      return;
    }
    _peerPubCache[username] = ownerRaw;
    // Legacy v1 device keys have no authenticated signature. Trusting a new
    // device key from the same directory would let a compromised server
    // redirect fan-out ciphertext to a MITM. Signed v2 device keys are handled
    // separately by getPeerV2Keys(); v1 stays on the pinned owner key only.
    final devList = <Uint8List>[ownerRaw];
    _peerDevicePubsCache[username] = devList;
    final decryptPubs = <Uint8List>[ownerRaw];
    for (final rawValue in devicesRaw.whereType<String>()) {
      try {
        final raw = Uint8List.fromList(base64Decode(rawValue));
        // Legacy CryptoService uses uncompressed P-256 public keys (65 bytes).
        // Ignore malformed/v2 values here; v2 devices are verified separately.
        if (raw.length != 65 ||
            decryptPubs.any((pub) => listEquals(pub, raw))) {
          continue;
        }
        decryptPubs.add(raw);
      } catch (_) {
        // A malformed directory entry must not prevent other messages from
        // being tried with the valid owner/device keys.
      }
    }
    _peerDecryptPubsCache[username] = decryptPubs;
    // TOFU pin owner-pub (используем для индикации смены ключа в чат-bubble).
    if (ownerPubB64 != null) {
      if (pinnedOwner == null) {
        await _db.pinPub(username, ownerPubB64, accepted: true);
      }
    }
  }

  /// TDA-4: подгрузить мои other-device pubkey'и (для self-echo).
  Future<void> _refreshMyOtherDevicePubs() async {
    try {
      final r = await _api.chatGet('/keys/me');
      if (r is Map) {
        final list = (r['other_device_pubkeys'] as List?) ?? const [];
        _myOtherDevicePubs = list
            .whereType<String>()
            .where((s) => s.isNotEmpty)
            .map((s) => Uint8List.fromList(base64Decode(s)))
            .toList();
      }
    } catch (e) {
      appLog.warn('chat', '[ChatRepo] refresh self-pubs: $e');
    }
  }

  // ─── Догон pending с сервера (legacy /pending) ────────────────────────
  Future<void> fetchPending({int? generation}) async {
    final session = generation ?? _sessionGeneration;
    if (!_isCurrentSession(session)) return;
    try {
      final r = await _api.chatGet('/pending');
      if (!_isCurrentSession(session)) return;
      final msgs = ((r as Map)['messages'] as List?) ?? const [];
      final ackIds = <int>[];
      for (final raw in msgs) {
        if (!_isCurrentSession(session)) return;
        final m = Map<String, dynamic>.from(raw as Map);
        try {
          final ingested = await _ingestIncoming(
            m,
            fromPending: true,
            generation: session,
          );
          if (ingested) ackIds.add(m['id'] as int);
        } catch (e) {
          appLog.warn('chat', '[fetchPending] ingest failed: $e');
        }
      }
      if (ackIds.isNotEmpty && _isCurrentSession(session)) {
        try {
          await _api.chatPost('/ack', {'ids': ackIds});
        } catch (e) {
          appLog.warn('chat', '[fetchPending] ack failed: $e');
        }
      }
    } catch (e) {
      appLog.warn('chat', '[fetchPending] $e');
    }
  }

  Future<void>? _fetchHistoryInFlight;
  Future<void>? _fetchHistorySealedInFlight;

  /// Replays retained encrypted DM history after a key restore.  Pending is
  /// device-scoped, so it is empty when another device already acknowledged
  /// the message; history remains ciphertext and is still decrypted locally.
  Future<void> fetchHistory({int? generation}) {
    final session = generation ?? _sessionGeneration;
    if (!_isCurrentSession(session)) return Future.value();
    final existing = _fetchHistoryInFlight;
    if (existing != null) return existing;
    late final Future<void> tracked;
    tracked = _fetchHistoryOnce(session).whenComplete(() {
      if (identical(_fetchHistoryInFlight, tracked)) {
        _fetchHistoryInFlight = null;
      }
    });
    _fetchHistoryInFlight = tracked;
    return tracked;
  }

  Future<void> _fetchHistoryOnce(int session) async {
    try {
      final r = await _api.chatGet('/history?after_id=0&limit=500');
      if (!_isCurrentSession(session) || r is! Map) return;
      final msgs = (r['messages'] as List?) ?? const [];
      for (final raw in msgs) {
        if (!_isCurrentSession(session) || raw is! Map) return;
        try {
          await _ingestIncoming(
            Map<String, dynamic>.from(raw),
            fromPending: true,
            generation: session,
          );
        } catch (e) {
          appLog.warn('chat', '[fetchHistory] ingest failed: $e');
        }
      }
    } catch (e) {
      appLog.warn('chat', '[fetchHistory] $e');
    }
  }

  /// Replays retained sealed ciphertext.  The sender stays hidden inside the
  /// envelope; successful decryption extracts it on the client.
  Future<void> fetchHistorySealed({int? generation}) {
    final session = generation ?? _sessionGeneration;
    if (!_isCurrentSession(session)) return Future.value();
    final existing = _fetchHistorySealedInFlight;
    if (existing != null) return existing;
    late final Future<void> tracked;
    tracked = _fetchHistorySealedOnce(session).whenComplete(() {
      if (identical(_fetchHistorySealedInFlight, tracked)) {
        _fetchHistorySealedInFlight = null;
      }
    });
    _fetchHistorySealedInFlight = tracked;
    return tracked;
  }

  Future<void> _fetchHistorySealedOnce(int session) async {
    try {
      final r = await _api.chatGet('/history_sealed?after_id=0&limit=500');
      if (!_isCurrentSession(session) || r is! Map) return;
      final msgs = (r['messages'] as List?) ?? const [];
      for (final raw in msgs) {
        if (!_isCurrentSession(session) || raw is! Map) return;
        final m = Map<String, dynamic>.from(raw);
        final id = m['id'];
        final cipher = m['ciphertext'];
        if (id is! int || cipher is! String || cipher.isEmpty) continue;
        try {
          await _ingestSealed(
            id: id,
            cipher: cipher,
            createdAt: m['created_at'],
            senderUsername: m['sender_username'] as String?,
            senderIdentityPub: m['sender_identity_pub'] as String?,
            signature: m['signature'] as String?,
            generation: session,
          );
        } catch (e) {
          appLog.warn('chat', '[fetchHistorySealed] ingest failed: $e');
        }
      }
    } catch (e) {
      appLog.warn('chat', '[fetchHistorySealed] $e');
    }
  }

  // ─── v2 (Signal-style): identity Ed25519 + device X25519, per-device sealed ──

  /// Сгенерировать (при первом запуске) и опубликовать v2 identity + device.
  Future<bool> ensureV2Published({int? generation, String? password}) async {
    final account = _myUsername;
    if (account == null || account.trim().isEmpty) return false;
    try {
      await CryptoV2.instance.ensureKeys(account: account);
    } catch (e) {
      appLog.warn('chat', '[v2 ensureKeys] $e');
      return false;
    }
    if (generation != null && !_isCurrentSession(generation)) return false;
    if (_myUsername?.trim().toLowerCase() != account.trim().toLowerCase()) {
      return false;
    }
    // 1.1.25+ uses account-scoped v2 storage, while 1.1.24 used global
    // storage. Before publishing anything, ask the server which identity is
    // already bound to this account and recover the old local bundle when it
    // matches. Publishing a newly generated identity here would strand all
    // old v2/sealed messages and is rejected by the server anyway.
    Map<String, dynamic>? current;
    var devicePresent = false;
    var serverIdentityKnown = false;
    try {
      final rawCurrent = await _api.chatGet(
        '/v2/keys/${Uri.encodeComponent(account.trim().toLowerCase())}',
      );
      if (rawCurrent is! Map) {
        throw StateError('Invalid v2 keys response');
      }
      current = Map<String, dynamic>.from(rawCurrent);
      final serverIdentity = current['identity_pub'] as String?;
      if (serverIdentity != null && serverIdentity.isNotEmpty) {
        serverIdentityKnown = true;
        var identityMatches = false;
        try {
          identityMatches = listEquals(
            base64Decode(serverIdentity),
            CryptoV2.instance.identityPub,
          );
        } catch (_) {}
        if (!identityMatches) {
          try {
            identityMatches = await CryptoV2.instance.adoptLegacyKeysIfMatching(
              account: account,
              expectedIdentityB64: serverIdentity,
            );
          } catch (e) {
            appLog.warn('security', 'legacy v2 identity recovery failed: $e');
          }
          final recoveryPassword = password?.trim() ?? '';
          if (!identityMatches && recoveryPassword.isNotEmpty) {
            try {
              final rawIdentity = await _api.chatGet('/v2/identity/me');
              final identity = rawIdentity is Map
                  ? Map<String, dynamic>.from(rawIdentity)
                  : const <String, dynamic>{};
              final encrypted = identity['identity_priv_encrypted'] as String?;
              final salt = identity['identity_salt'] as String?;
              if (encrypted == null ||
                  encrypted.isEmpty ||
                  salt == null ||
                  salt.isEmpty) {
                throw StateError('Server has no encrypted v2 identity copy');
              }
              await CryptoV2.instance.importEncryptedIdentityFromServer(
                encryptedB64: encrypted,
                saltB64: salt,
                password: recoveryPassword,
                account: account,
              );
              identityMatches = listEquals(
                base64Decode(serverIdentity),
                CryptoV2.instance.identityPub,
              );
            } catch (e) {
              appLog.warn(
                'security',
                'v2 identity recovery failed for @$account: $e',
              );
            }
          }
          if (!identityMatches) {
            appLog.warn(
              'security',
              'v2 identity mismatch for @$account; publish skipped until key recovery',
            );
            return false;
          }
        }
      }

      // Do not skip repair merely because this session already published a
      // device earlier. The server may have lost the device row (or the
      // previous publish may have failed during maintenance). Reuse the
      // current device when it is already present; otherwise republish it.
      final devices = current['devices'] as List?;
      devicePresent =
          devices?.any((rawDevice) {
            if (rawDevice is! Map) return false;
            return rawDevice['device_pub'] == CryptoV2.instance.devicePubB64;
          }) ??
          false;
      if (devicePresent && (password == null || password.trim().isEmpty)) {
        _v2Published = true;
        return true;
      }
    } catch (e) {
      if (serverIdentityKnown) {
        appLog.warn(
          'security',
          '[v2 identity lookup] refusing replacement: $e',
        );
        return false;
      }
      // A legacy backend may not expose the identity lookup. Keep the normal
      // publish path for that backend; a real mismatch is handled above.
      appLog.debug('crypto', '[v2 identity lookup] $e');
    }
    // If the server already owns another v2 identity for this account, do not
    // continue with a local replacement. The v1 path remains available after
    // its account-scoped key sync and still identifies the current account.
    try {
      final identityBody = <String, dynamic>{
        'identity_pub': CryptoV2.instance.identityPubB64,
        'proof_signature': base64.encode(
          await CryptoV2.instance.proofSignature(),
        ),
      };
      final recoveryPassword = password?.trim() ?? '';
      if (recoveryPassword.isNotEmpty) {
        identityBody.addAll(
          await CryptoV2.instance.exportEncryptedIdentityForServer(
            recoveryPassword,
          ),
        );
      }
      await _api.chatPost('/v2/identity/publish', identityBody);
    } catch (e) {
      // 409 = уже опубликован тот же identity → не страшно.
      appLog.warn('chat', '[v2 identity publish] $e');
      return false;
    }
    if (generation != null && !_isCurrentSession(generation)) return false;
    if (_myUsername?.trim().toLowerCase() != account.trim().toLowerCase()) {
      return false;
    }
    if (!devicePresent) {
      try {
        await _api.chatPost('/v2/device/publish', {
          'device_pub': CryptoV2.instance.devicePubB64,
          'signed_prekey_sig': base64.encode(
            await CryptoV2.instance.signedPrekeySig(),
          ),
        });
      } catch (e) {
        appLog.warn('chat', '[v2 device publish] $e');
        return false;
      }
    }
    _v2Published = true;
    return true;
  }

  /// Seed-фраза v2 (12 слов) — бэкап личности + привязка других устройств (веба).
  Future<String?> v2Mnemonic() async {
    final account = _myUsername ?? await AuthService.username();
    if (account == null || account.trim().isEmpty) return null;
    await CryptoV2.instance.ensureKeys(account: account);
    return CryptoV2.instance.mnemonic;
  }

  /// Ключи пира в формате для Треугольника (см. меню "⋮" шапки чата) — та же
  /// проверка identity+device, что перед P2P-отправкой в _sendDmTextV2, но
  /// вызывается сразу по выбору режима, не дожидаясь следующего сообщения.
  Future<TrianglePeerKeys?> triangleKeysFor(String username) async {
    final keys = await getPeerV2Keys(username);
    if (keys == null) return null;
    final identityPubB64 = keys['identity_pub'] as String?;
    final devices = (keys['devices'] as List);
    final firstDevicePubB64 = devices.isNotEmpty
        ? (Map<String, dynamic>.from(devices.first as Map)['device_pub']
              as String?)
        : null;
    if (identityPubB64 == null || firstDevicePubB64 == null) return null;
    return TrianglePeerKeys(
      username: username,
      devicePubB64: firstDevicePubB64,
      identityPubB64: identityPubB64,
    );
  }

  /// v2-ключи пира (identity + список device-pub). null если пир не на v2.
  Future<Map<String, dynamic>?> getPeerV2Keys(
    String username, {
    bool forceRefresh = false,
  }) async {
    final normalized = username.trim().toLowerCase();
    final fetchedAt = _v2KeysFetchedAt[normalized];
    final fresh =
        fetchedAt != null &&
        DateTime.now().difference(fetchedAt) < _v2PeerKeysTtl;
    if (!forceRefresh && fresh && _v2KeysCache.containsKey(normalized)) {
      final c = _v2KeysCache[normalized]!;
      return c.isEmpty ? null : c; // пустая = «нет v2» (кэш отрицательного)
    }
    try {
      final r = await _api.chatGet('/v2/keys/$normalized');
      final m = Map<String, dynamic>.from(r as Map);
      final returnedUsername = (m['username'] as String?)?.trim().toLowerCase();
      if (returnedUsername != normalized) {
        throw V2IdentitySecurityException(
          'Сервер вернул ключи не для @$normalized; отправка заблокирована',
        );
      }
      final avatar = _nonEmptyAvatar(m['avatar_url']);
      if (avatar != null) {
        _peerAvatarCache[normalized] = avatar;
        unawaited(_savePeerInfoToDisk());
      }
      final idPubB64 = m['identity_pub'] as String?;
      final devs = (m['devices'] as List?) ?? const [];
      if (idPubB64 != null && devs.isNotEmpty) {
        final idPub = Uint8List.fromList(base64.decode(idPubB64));
        if (idPub.length != 32) {
          throw V2IdentitySecurityException(
            'У @$normalized некорректный identity-ключ; отправка заблокирована',
          );
        }
        // SECURITY: верифицируем signed_prekey_sig КАЖДОГО device через
        // identity_pub. Без этого злой сервер подменит device_pub и прочитает
        // v2-трафик (MITM). Используем только подтверждённые устройства.
        final verified = <Map<String, dynamic>>[];
        for (final d in devs) {
          final dm = Map<String, dynamic>.from(d as Map);
          final dPub = dm['device_pub'] as String?;
          final sig = dm['signed_prekey_sig'] as String?;
          if (dPub == null || sig == null) continue;
          final ok = await CryptoV2.instance.verifySignedPrekey(
            identityPub: idPub,
            devicePub: Uint8List.fromList(base64.decode(dPub)),
            signature: Uint8List.fromList(base64.decode(sig)),
          );
          if (ok) {
            verified.add(dm);
          } else {
            appLog.warn(
              'security',
              'getPeerV2Keys: device ${dm['device_id']} sig INVALID — '
                  'пропуск (возможна подмена сервером)',
            );
          }
        }
        if (verified.isNotEmpty) {
          await _pinV2Identity(normalized, idPubB64);
          final out = {'identity_pub': idPubB64, 'devices': verified};
          _v2KeysCache[normalized] = out;
          _v2KeysFetchedAt[normalized] = DateTime.now();
          return out;
        }
        throw V2IdentitySecurityException(
          'Не удалось проверить ни одного ключа устройства @$normalized',
        );
      }
      _v2KeysCache[normalized] = {};
      _v2KeysFetchedAt[normalized] = DateTime.now();
    } on V2IdentitySecurityException {
      rethrow;
    } catch (e) {
      appLog.warn('chat', '[getPeerV2Keys] $e');
      rethrow;
    }
    return null;
  }

  Future<void> _pinV2Identity(String username, String identityPubB64) async {
    final normalized = username.trim().toLowerCase();
    final bytes = ChatMessageAuth.tryDecodeBase64(identityPubB64);
    if (bytes == null || bytes.length != 32) {
      throw V2IdentitySecurityException(
        'У @$normalized некорректный identity-ключ; отправка заблокирована',
      );
    }
    final existing = await _db.getPinnedV2Identity(normalized);
    if (existing != null && existing != identityPubB64) {
      appLog.error(
        'security',
        'V2 identity changed for @$normalized; refusing key replacement',
      );
      throw V2IdentitySecurityException(
        'Identity-ключ @$normalized изменился. Отправка и приём заблокированы до ручной проверки.',
      );
    }
    final saved = await _db.pinV2IdentityIfAbsent(normalized, identityPubB64);
    if (saved != identityPubB64) {
      throw V2IdentitySecurityException(
        'Identity-ключ @$normalized изменился во время проверки. Отправка заблокирована.',
      );
    }
  }

  Future<bool> _verifyServerSignedEnvelope({
    required String senderUsername,
    required String senderIdentityPub,
    required String signatureB64,
    required List<int> signedBytes,
  }) async {
    final normalized = senderUsername.trim().toLowerCase();
    if (normalized.isEmpty) return false;
    final identity = ChatMessageAuth.tryDecodeBase64(senderIdentityPub);
    final signature = ChatMessageAuth.tryDecodeBase64(signatureB64);
    if (identity == null ||
        identity.length != 32 ||
        signature == null ||
        signature.length != 64) {
      return false;
    }
    final valid = await CryptoV2.instance.verifyIdentitySignature(
      identityPub: Uint8List.fromList(identity),
      signature: Uint8List.fromList(signature),
      message: signedBytes,
    );
    if (!valid) return false;
    await _pinV2Identity(normalized, senderIdentityPub);
    return true;
  }

  /// identity_pub (base64) → username. Своё распознаём локально.
  Future<String?> _whoisV2(String identityPubB64) async {
    if (CryptoV2.instance.ready &&
        identityPubB64 == CryptoV2.instance.identityPubB64) {
      return _myUsername ?? await AuthService.username();
    }
    if (_v2WhoisCache.containsKey(identityPubB64)) {
      return _v2WhoisCache[identityPubB64];
    }
    try {
      final r = await _api.chatGet('/v2/whois', {
        'identity_pub': identityPubB64,
      });
      final u = (r as Map)['username'] as String?;
      if (u != null) _v2WhoisCache[identityPubB64] = u;
      return u;
    } catch (e) {
      appLog.warn('chat', '[whoisV2] $e');
      return null;
    }
  }

  /// Отправить любое DM-событие через v2. Сервер получает отдельный envelope
  /// для каждого актуального устройства адресата. Если между загрузкой
  /// ключей и отправкой произошла ротация, сервер отклоняет устаревший
  /// device_pub, после чего один раз перечитываем bundle и шифруем заново.
  Future<int> _sendV2Payload({
    required String toUsername,
    required Map<String, dynamic> payload,
    Map<String, dynamic>? keys,
    bool includeOwnDevices = true,
    String? clientMessageId,
    Map<String, dynamic>? preparedRequest,
    Future<void> Function(Map<String, dynamic>)? onPreparedRequest,
  }) async {
    if (!CryptoV2.instance.ready || !_v2Published) {
      throw StateError('V2-ключи этого устройства ещё не опубликованы');
    }

    final sid = payload['sid'] is int
        ? payload['sid'] as int
        : DateTime.now().microsecondsSinceEpoch;
    final body = <String, dynamic>{
      ...payload,
      'v': 2,
      'from_id': CryptoV2.instance.identityPubB64,
      'sid': sid,
      'ts': DateTime.now().millisecondsSinceEpoch ~/ 1000,
    };

    var fixedRequest = preparedRequest;
    Future<void> sendWithKeys(Map<String, dynamic> bundle) async {
      final rawDevices = (bundle['devices'] as List?) ?? const [];
      if (rawDevices.isEmpty) {
        throw StateError('У @$toUsername нет активных V2-устройств');
      }
      final plaintext = Uint8List.fromList(utf8.encode(jsonEncode(body)));
      final envelopes = <Map<String, dynamic>>[];
      for (final rawDevice in rawDevices) {
        final device = Map<String, dynamic>.from(rawDevice as Map);
        final devicePubB64 = device['device_pub'] as String?;
        final deviceId = device['device_id'];
        if (devicePubB64 == null || deviceId is! int) continue;
        final devicePub = Uint8List.fromList(base64.decode(devicePubB64));
        final envelope = await CryptoV2.instance.encryptV2(
          devicePub,
          plaintext,
        );
        final signatureBytes = ChatMessageAuth.v2EnvelopeBytes(
          senderIdentityPub: CryptoV2.instance.identityPubB64,
          toUsername: toUsername,
          targetDeviceId: deviceId,
          envelope: envelope,
        );
        final signature = await CryptoV2.instance.signWithIdentity(
          signatureBytes,
        );
        envelopes.add({
          'target_device_id': deviceId,
          'target_device_pub': devicePubB64,
          'envelope': envelope,
          'signature': base64.encode(signature),
        });
      }
      if (envelopes.isEmpty) {
        throw StateError('Не найдено ни одного корректного V2-устройства');
      }
      final request =
          fixedRequest ??
          <String, dynamic>{
            'to_username': toUsername,
            'sender_identity_pub': CryptoV2.instance.identityPubB64,
            'envelopes': envelopes,
            if (clientMessageId != null) 'client_message_id': clientMessageId,
          };
      if (fixedRequest == null) {
        fixedRequest = request;
        await onPreparedRequest?.call(request);
      }
      await _api.chatPost('/v2/send', request);
    }

    var bundle = keys;
    if (bundle == null) {
      bundle = await getPeerV2Keys(toUsername, forceRefresh: true);
    }
    if (bundle == null) {
      throw StateError('У @$toUsername нет V2-ключей');
    }
    try {
      await sendWithKeys(bundle);
    } on ApiException catch (e) {
      final stale =
          e.status == 409 &&
          (e.message.contains('v2_device_key_stale') ||
              e.message.contains('ключ устройства устарел'));
      if (!stale) rethrow;
      final normalized = toUsername.trim().toLowerCase();
      _v2KeysCache.remove(normalized);
      _v2KeysFetchedAt.remove(normalized);
      final refreshed = await getPeerV2Keys(toUsername, forceRefresh: true);
      if (refreshed == null) rethrow;
      // A stale-device response is rejected before persistence. Re-encrypt
      // once against the refreshed bundle and replace the saved replay body.
      fixedRequest = null;
      await sendWithKeys(refreshed);
    }

    // v2 does not echo a sender's message back to the sender. Synchronize
    // other active devices in the background so their extra round-trip never
    // delays the send result shown by this device.
    if (includeOwnDevices) {
      unawaited(
        _sendV2SelfEcho(peerUsername: toUsername, payload: payload, sid: sid),
      );
    }
    return sid;
  }

  Future<void> _sendV2SelfEcho({
    required String peerUsername,
    required Map<String, dynamic> payload,
    required int sid,
  }) async {
    try {
      final me = _myUsername ?? await AuthService.username();
      if (me == null || me.trim().isEmpty) return;
      if (me.trim().toLowerCase() == peerUsername.trim().toLowerCase()) {
        return;
      }
      final ownKeys = await getPeerV2Keys(me, forceRefresh: false);
      if (ownKeys == null) return;
      await _sendV2Payload(
        toUsername: me,
        payload: {
          ...payload,
          'sid': sid,
          'self_echo': true,
          'peer_hint': peerUsername,
        },
        keys: ownKeys,
        includeOwnDevices: false,
      );
    } catch (e) {
      // The recipient message is already accepted. A missing self-echo must
      // not turn a successful send into a visible failure.
      appLog.warn('chat', '[v2 self-echo] $e');
    }
  }

  /// Отправка текста по v2 (per-device sealed). sid генерим сами (серверного нет).
  Future<void> _sendDmTextV2({
    required String toUsername,
    required String text,
    required Map<String, dynamic> keys,
    required int tempSid,
    required String tmpKey,
    required String clientMessageId,
    required int clientSid,
    Map<String, dynamic>? preparedRequest,
    Future<void> Function(Map<String, dynamic>)? onPreparedRequest,
    int? replyTo,
    String? replyPreview,
    String? forwardedFrom,
    List<MessageButton> userButtons = const [],
  }) async {
    // Оптимистичный пузырь уже создан в sendDmText (мгновенно). Здесь только
    // шифрование/отправка и промоут temp → клиентский v2 sid.
    final sid = clientSid;

    // Треугольник (см. triangle_service.dart): если с этим контактом уже
    // есть подтверждённая P2P-сессия — шлём напрямую, минуя сервер. Нет
    // сессии — пробуем установить её В ФОНЕ для следующих сообщений (не
    // блокируем ЭТО отправкой через punch, у него таймаут ~10с).
    final identityPubB64 = keys['identity_pub'] as String?;
    final devices = (keys['devices'] as List);
    final firstDevicePubB64 = devices.isNotEmpty
        ? (Map<String, dynamic>.from(devices.first as Map)['device_pub']
              as String?)
        : null;
    TrianglePeerKeys? peerKeys;
    if (identityPubB64 != null && firstDevicePubB64 != null) {
      peerKeys = TrianglePeerKeys(
        username: toUsername,
        devicePubB64: firstDevicePubB64,
        identityPubB64: identityPubB64,
      );
    }
    // Режим соединения (см. меню "⋮" в шапке чата) — "через сервер" глушит
    // Треугольник для этого контакта совсем, ни отправки, ни фоновых попыток.
    final connMode = await ConnectionModeStore.get(toUsername);
    if (connMode == ConnectionMode.server) peerKeys = null;

    if (userButtons.isEmpty &&
        peerKeys != null &&
        triangleService.hasSession(toUsername)) {
      final sentViaP2p = await triangleService.sendText(
        toUsername,
        sid.toString(),
        text,
      );
      if (sentViaP2p) {
        await _db.promoteOptimistic(
          peer: toUsername,
          tempSid: tmpKey,
          realSid: sid,
          createdAt: DateTime.now().toUtc().toIso8601String(),
        );
        await _db.updateMessageFlags(toUsername, sid, {
          'pending': 0,
          'delivered': 1,
        });
        await _refreshMessages(toUsername);
        await _refreshDialogs();
        return;
      }
      // sendText вернул false (сокет не готов/ошибка) — падаем в обычную
      // отправку через сервер ниже, юзер не должен заметить разницу.
    } else if (peerKeys != null) {
      unawaited(triangleService.attemptConnect(peerKeys));
    }

    try {
      final sidPayload = <String, dynamic>{
        'type': 'msg',
        'text': text,
        'sid': sid,
        if (replyTo != null) 'reply_to': replyTo,
        if (replyPreview != null && replyPreview.isNotEmpty)
          'reply_preview': replyPreview,
        if (forwardedFrom != null && forwardedFrom.isNotEmpty)
          'forwarded_from': forwardedFrom,
        if (userButtons.isNotEmpty)
          'user_buttons': MessageButton.encodeList(userButtons),
      };
      await _sendV2Payload(
        toUsername: toUsername,
        payload: sidPayload,
        keys: keys,
        clientMessageId: clientMessageId,
        preparedRequest: preparedRequest,
        onPreparedRequest: onPreparedRequest,
      );
      // Промоут оптимистичного пузыря temp → клиентский v2 sid + delivered.
      await _db.promoteOptimistic(
        peer: toUsername,
        tempSid: tmpKey,
        realSid: sid,
        createdAt: DateTime.now().toUtc().toIso8601String(),
      );
      await _db.updateMessageFlags(toUsername, sid, {
        'pending': 0,
        'delivered': 1,
      });
      await _refreshMessages(toUsername);
      await _refreshDialogs();
    } catch (e) {
      appLog.warn('chat', '[sendDmTextV2] $e');
      rethrow;
    }
  }

  /// Догон входящих v2: /v2/pending → decryptForMe → ingest → ack.
  Future<void> fetchPendingV2({int? generation}) async {
    final session = generation ?? _sessionGeneration;
    if (!_isCurrentSession(session)) return;
    if (!CryptoV2.instance.ready) return;
    try {
      final r = await _api.chatGet('/v2/pending');
      if (!_isCurrentSession(session)) return;
      final msgs = ((r as Map)['messages'] as List?) ?? const [];
      final ackIds = <int>[];
      for (final raw in msgs) {
        if (!_isCurrentSession(session)) return;
        final m = Map<String, dynamic>.from(raw as Map);
        final id = m['id'];
        try {
          final senderUsername = m['sender_username'] as String?;
          final senderIdentityPub = m['sender_identity_pub'] as String?;
          final signature = m['signature'] as String?;
          if (senderUsername == null ||
              senderIdentityPub == null ||
              signature == null) {
            appLog.warn(
              'security',
              '[fetchPendingV2] rejected unsigned/legacy envelope id=$id',
            );
            if (id is int) ackIds.add(id);
            continue;
          }
          final signatureOk = await _verifyServerSignedEnvelope(
            senderUsername: senderUsername,
            senderIdentityPub: senderIdentityPub,
            signatureB64: signature,
            signedBytes: ChatMessageAuth.v2EnvelopeBytes(
              senderIdentityPub: senderIdentityPub,
              toUsername: _myUsername ?? await AuthService.username() ?? '',
              targetDeviceId: m['target_device_id'] as int,
              envelope: m['envelope'] as String,
            ),
          );
          if (!signatureOk) {
            appLog.warn(
              'security',
              '[fetchPendingV2] invalid envelope signature id=$id',
            );
            if (id is int) ackIds.add(id);
            continue;
          }
          final plain = await CryptoV2.instance.decryptForMe(
            m['envelope'] as String,
          );
          if (plain != null) {
            final payload =
                jsonDecode(utf8.decode(plain)) as Map<String, dynamic>;
            if (payload['from_id'] != senderIdentityPub) {
              appLog.warn(
                'security',
                '[fetchPendingV2] encrypted sender key mismatch id=$id',
              );
              if (id is int) ackIds.add(id);
              continue;
            }
            final ingested = await _ingestV2(
              payload,
              m['created_at'],
              authenticatedFromUsername: senderUsername,
              generation: session,
            );
            if (ingested && id is int) ackIds.add(id);
          }
        } catch (e) {
          appLog.warn('chat', '[fetchPendingV2] ingest $e');
        }
      }
      if (ackIds.isNotEmpty && _isCurrentSession(session)) {
        try {
          await _api.chatPost('/v2/ack', {'ids': ackIds});
        } catch (_) {}
      }
    } catch (e) {
      appLog.warn('chat', '[fetchPendingV2] $e');
    }
  }

  Future<void> _onChatV2New(Map<String, dynamic> d, {int? generation}) async {
    await fetchPendingV2(generation: generation);
  }

  String _v2CreatedAt(dynamic createdAt) {
    if (createdAt is int) {
      return DateTime.fromMillisecondsSinceEpoch(
        createdAt * 1000,
        isUtc: true,
      ).toIso8601String();
    }
    return DateTime.now().toUtc().toIso8601String();
  }

  // Детерминированный 31-битный sid из строки (FNV-1a) — для v2-сообщений без
  // sid (python-мост), чтобы повторная доставка не плодила дубли.
  int _stableSid(String s) {
    var h = 0x811c9dc5;
    for (final c in s.codeUnits) {
      h = (h ^ c) & 0xFFFFFFFF;
      h = (h * 0x01000193) & 0xFFFFFFFF;
    }
    return h & 0x7FFFFFFF;
  }

  Future<bool> _ingestV2(
    Map<String, dynamic> payload,
    dynamic createdAt, {
    String? authenticatedFromUsername,
    int? generation,
  }) async {
    if (generation != null && !_isCurrentSession(generation)) return false;
    final type = payload['type'] as String? ?? 'msg';
    // Отправитель: либо from_id (identity_pub → whois, формат веба), либо
    // from_username (имя — так шлёт python-клиент). sid: если нет — генерим
    // локальный, чтобы plain-сообщение всё равно сохранилось.
    final fromId = payload['from_id'] as String?;
    final fromUsername = payload['from_username'] as String?;
    final selfEcho = payload['self_echo'] == true;
    final peerHint = payload['peer_hint'] as String?;
    String? fromUser;
    if (selfEcho && peerHint != null && peerHint.trim().isNotEmpty) {
      final me = (_myUsername ?? await AuthService.username())
          ?.trim()
          .toLowerCase();
      if (authenticatedFromUsername != null &&
          authenticatedFromUsername.trim().toLowerCase() != me) {
        appLog.warn('security', 'rejected self-echo from non-self sender');
        return false;
      }
      fromUser = peerHint.trim().toLowerCase();
    } else if (authenticatedFromUsername != null &&
        authenticatedFromUsername.trim().isNotEmpty) {
      fromUser = authenticatedFromUsername.trim().toLowerCase();
    } else if (fromId != null) {
      fromUser = await _whoisV2(fromId);
    } else if (fromUsername != null) {
      fromUser = fromUsername;
    }
    if (generation != null && !_isCurrentSession(generation)) return false;
    if (fromUser == null) return false;
    if (_isOlderThanChatDelete(fromUser, createdAt)) {
      appLog.info(
        'chat',
        'discarding old v2 message from @$fromUser after chat deletion',
      );
      return true;
    }
    final rawSid = payload['sid'];
    // sid: если прислан (веб/мой клиент) — берём. Если нет (python-мост шлёт без
    // sid) — генерим ДЕТЕРМИНИРОВАННЫЙ из (отправитель|время|текст|file_id).
    // Иначе при повторной доставке (ack не дошёл) каждый ингест давал НОВЫЙ sid
    // → дубли сообщений и раздутый счётчик непрочитанных.
    final sid = rawSid is int
        ? rawSid
        : _stableSid(
            '$fromUser|${_v2CreatedAt(createdAt)}|'
            '${payload['text'] ?? ''}|${payload['file_id'] ?? ''}',
          );
    final me = _myUsername ?? await AuthService.username();
    final isMine = selfEcho || fromUser == me;

    // Управляющие типы (edit/delete/react): веб адресует ЦЕЛЬ через target_sid,
    // мой формат — через sid. Берём target_sid с fallback на sid.
    final targetSid = payload['target_sid'] is int
        ? payload['target_sid'] as int
        : (payload['sid'] is int ? payload['sid'] as int : null);

    if (type == 'edit') {
      if (targetSid == null) return false;
      await _db.updateMessageFlags(fromUser, targetSid, {
        'text': payload['new_text'] ?? payload['text'] ?? '',
        'edited': 1,
      });
      await _refreshMessages(fromUser);
      return true;
    }
    if (type == 'user_buttons_remove') {
      final targetSid = payload['target_sid'] is int
          ? payload['target_sid'] as int
          : (payload['sid'] is int ? payload['sid'] as int : null);
      final owner = payload['owner_username']?.toString().trim().toLowerCase();
      if (targetSid != null && owner == fromUser.toLowerCase()) {
        await _clearDmMessageButtonsIfOwned(
          peer: fromUser,
          targetSid: targetSid,
          senderIsMe: isMine,
          includeSealedSid: true,
        );
      }
      return true;
    }
    if (type == 'delete') {
      if (targetSid == null) return false;
      await _db.updateMessageFlags(fromUser, targetSid, {
        'deleted': 1,
        'text': '',
        'file_payload': null,
      });
      await _refreshMessages(fromUser);
      return true;
    }
    if (type == 'react') {
      if (targetSid == null) return false;
      final emoji = payload['emoji'] as String?;
      final on = payload['on'];
      final actor = isMine ? me : fromUser;
      if (emoji != null && actor != null) {
        if (on is bool) {
          await _setReactionLocal(fromUser, targetSid, emoji, actor, on: on);
        } else {
          await _toggleReactionLocal(fromUser, targetSid, emoji, actor);
        }
        await _refreshMessages(fromUser);
      }
      return true;
    }
    // обычное сообщение (text / file / voice)
    final existing = await _db.getMessage(fromUser, sid);
    if (existing != null && !existing.decryptFailed) return true;
    // БАГ-ФИКС: v2-ингест раньше НЕ строил filePayload → файл/голос приходил
    // «огрызком» (пустой текст, без file-UI). Зеркалим v1 sealed/incoming.
    final isFile = type == 'file' || type == 'voice';
    final durationSec = _mediaDurationSeconds(payload['duration']);
    final stored = StoredMessage(
      sid: sid,
      peer: fromUser,
      fromMe: isMine,
      text: payload['text'] as String? ?? '',
      createdAt: _v2CreatedAt(createdAt),
      replyTo: payload['reply_to'] as int?,
      replyPreview: payload['reply_preview'] as String?,
      forwardedFrom: payload['forwarded_from'] as String?,
      userButtons: MessageButton.parseList(payload['user_buttons']),
      filePayload: isFile
          ? {
              'file_id': payload['file_id'],
              'file_name': payload['file_name'] ?? '',
              'mime': payload['mime'] ?? 'application/octet-stream',
              'size': payload['size'] ?? 0,
              'key': payload['key'],
              'iv': payload['iv'],
              if (payload['thumb'] != null) 'thumb': payload['thumb'],
              if (type == 'voice') 'voice': true,
              if (durationSec != null) 'duration': durationSec,
              if (type == 'voice' && payload['waveform'] != null)
                'waveform': payload['waveform'],
            }
          : null,
    );
    await _db.upsertMessage(stored);
    await _refreshMessages(fromUser);
    final preview = isFile
        ? _filePreview(
            mime: payload['mime'] as String?,
            fileName: payload['file_name'] as String?,
            voice: type == 'voice',
          )
        : stored.text;
    await _bumpDialog(
      fromUser,
      lastText: preview,
      fromMe: isMine,
      lastAt: stored.createdAt,
      incUnread: !isMine,
    );
    // Уведомление о входящем v2-файле/сообщении (если этот чат не открыт).
    if (!isMine) {
      NotificationService.instance.onIncoming(
        peer: fromUser,
        preview: preview,
        senderName: _notificationSenderName(fromUser),
        kind: classifyNotificationKind(
          mime: payload['mime'] as String?,
          voice: type == 'voice',
        ),
        thumbnailBase64: stored.filePayload?['thumb'] as String?,
      );
    }
    return true;
  }

  /// Повторить расшифровку не подтверждённых сообщений после обновления
  /// ключей. Ciphertext остаётся на сервере; локально хранится только sid.
  /// Если [peer] не задан, повторяем все три очереди — это нужно после
  /// восстановления старой пары ключей, чтобы старые сообщения сами
  /// заменили локальные decrypt_failed-заглушки.
  Future<void> retryFailedMessages({String? peer, int? generation}) async {
    final session = generation ?? _sessionGeneration;
    if (!_isCurrentSession(session)) return;
    final normalized = peer?.trim().toLowerCase();
    if (normalized != null && normalized.isNotEmpty) {
      _peerPubCache.remove(normalized);
      _peerDevicePubsCache.remove(normalized);
      _peerDecryptPubsCache.remove(normalized);
      _v2KeysCache.remove(normalized);
      _v2KeysFetchedAt.remove(normalized);
      await _refreshPeerPubAfterDecryptFail(normalized);
    }
    if (!_isCurrentSession(session)) return;
    await fetchHistory(generation: session);
    await fetchHistorySealed(generation: session);
    await fetchPending(generation: session);
    await fetchPendingSealed(generation: session);
    await fetchPendingV2(generation: session);
  }

  Future<void> retryFailedMessage(StoredMessage message) {
    final peer = message.peer.trim().toLowerCase();
    if (peer.isEmpty || message.sid < 0) return Future.value();
    return retryFailedMessages(peer: peer);
  }

  /// Входящее P2P-сообщение (режим «Треугольник», см. triangle_service.dart)
  /// — заводим в ТОТ ЖЕ пайплайн, что обычные v2-сообщения с сервера, чтобы
  /// оно легло в общую историю чата (апгрейд существующего чата, а не
  /// отдельный список, как у LAN). sid не передаём — _ingestV2 сам выведет
  /// детерминированный из (отправитель|время|текст), как для python-моста.
  Future<void> ingestTriangleMessage({
    required String fromUsername,
    required String text,
    required int sentAtMs,
  }) async {
    await _ingestV2(
      {'type': 'msg', 'from_username': fromUsername, 'text': text},
      sentAtMs ~/ 1000,
      authenticatedFromUsername: fromUsername,
    );
  }

  Future<void> _postSignedSealed({
    required String toUsername,
    required String ciphertext,
  }) async {
    if (!CryptoV2.instance.ready || !_v2Published) {
      throw StateError('Для sealed-сообщения не опубликован identity v2');
    }
    final senderIdentityPub = CryptoV2.instance.identityPubB64;
    final signatureBytes = ChatMessageAuth.sealedEnvelopeBytes(
      senderIdentityPub: senderIdentityPub,
      toUsername: toUsername,
      ciphertext: ciphertext,
    );
    final signature = await CryptoV2.instance.signWithIdentity(signatureBytes);
    await _api.chatPost('/send_sealed', {
      'to_username': toUsername,
      'ciphertext': ciphertext,
      'sender_identity_pub': senderIdentityPub,
      'signature': base64.encode(signature),
    });
  }

  /// Sealed-сообщения хранятся в отдельной таблице на сервере (chat_dm_sealed),
  /// со своим auto-increment ID. Чтобы он не пересекался с legacy chat_dm.id
  /// в нашей единой messages-таблице — добавляем смещение.
  static const _sealedSidOffset = 1 << 40; // 1_099_511_627_776

  int _sealedSid(int rawId) => _sealedSidOffset + rawId;

  // ─── Real-time sealed event ──────────────────────────────────────────
  Future<void> _onChatSealedNew(
    Map<String, dynamic> d, {
    int? generation,
  }) async {
    final session = generation ?? _sessionGeneration;
    if (!_isCurrentSession(session)) return;
    final id = d['id'];
    final cipher = d['ciphertext'] as String?;
    final createdAt = d['created_at'];
    if (id is! int || cipher == null) return;
    final ok = await _ingestSealed(
      id: id,
      cipher: cipher,
      createdAt: createdAt,
      senderUsername: d['sender_username'] as String?,
      senderIdentityPub: d['sender_identity_pub'] as String?,
      signature: d['signature'] as String?,
      generation: session,
    );
    if (ok && _isCurrentSession(session)) {
      try {
        await _api.chatPost('/ack_sealed', {
          'ids': [id],
        });
      } catch (_) {}
    }
  }

  // ─── Догон pending_sealed (Sealed Sender 2.0) ────────────────────────
  /// Тянет /pending_sealed, расшифровывает каждый envelope своим приват-ключом,
  /// инжектит как обычное входящее сообщение, ack-ает на сервер.
  Future<void> fetchPendingSealed({int? generation}) {
    final session = generation ?? _sessionGeneration;
    if (!_isCurrentSession(session)) return Future.value();
    final existing = _fetchPendingSealedInFlight;
    if (existing != null) return existing;

    late final Future<void> tracked;
    tracked = _fetchPendingSealedOnce(session).whenComplete(() {
      if (identical(_fetchPendingSealedInFlight, tracked)) {
        _fetchPendingSealedInFlight = null;
      }
    });
    _fetchPendingSealedInFlight = tracked;
    return tracked;
  }

  Future<void> _fetchPendingSealedOnce(int session) async {
    try {
      final r = await _api.chatGet('/pending_sealed');
      if (!_isCurrentSession(session)) return;
      final msgs = ((r as Map)['messages'] as List?) ?? const [];
      final ackIds = <int>[];
      for (final raw in msgs) {
        if (!_isCurrentSession(session)) return;
        final m = Map<String, dynamic>.from(raw as Map);
        final id = m['id'] as int?;
        final cipher = m['ciphertext'] as String?;
        if (id == null || cipher == null) continue;
        try {
          final ok = await _ingestSealed(
            id: id,
            cipher: cipher,
            createdAt: m['created_at'],
            senderUsername: m['sender_username'] as String?,
            senderIdentityPub: m['sender_identity_pub'] as String?,
            signature: m['signature'] as String?,
            generation: session,
          );
          if (ok) ackIds.add(id);
        } catch (e) {
          appLog.warn('chat', '[fetchPendingSealed] decrypt fail $id: $e');
        }
      }
      if (ackIds.isNotEmpty && _isCurrentSession(session)) {
        try {
          await _api.chatPost('/ack_sealed', {'ids': ackIds});
        } catch (e) {
          appLog.warn('chat', '[fetchPendingSealed] ack fail: $e');
        }
      }
    } catch (e) {
      appLog.warn('chat', '[fetchPendingSealed] $e');
    }
  }

  /// Inject sealed-сообщение в локальное состояние.
  Future<bool> _ingestSealed({
    required int id,
    required String cipher,
    required String? senderUsername,
    required String? senderIdentityPub,
    required String? signature,
    dynamic createdAt,
    int? generation,
  }) async {
    if (generation != null && !_isCurrentSession(generation)) return false;
    if (senderUsername == null ||
        senderIdentityPub == null ||
        signature == null) {
      appLog.warn(
        'security',
        '[sealed] rejected unsigned/legacy envelope id=$id',
      );
      return false;
    }
    final signatureOk = await _verifyServerSignedEnvelope(
      senderUsername: senderUsername,
      senderIdentityPub: senderIdentityPub,
      signatureB64: signature,
      signedBytes: ChatMessageAuth.sealedEnvelopeBytes(
        senderIdentityPub: senderIdentityPub,
        toUsername: _myUsername ?? await AuthService.username() ?? '',
        ciphertext: cipher,
      ),
    );
    if (!signatureOk) {
      appLog.warn('security', '[sealed] invalid envelope signature id=$id');
      return false;
    }
    Map<String, dynamic> env;
    try {
      env = await _crypto.decryptSealed(cipher);
    } catch (e) {
      if (_sealedDecryptFailuresLogged.add(id)) {
        appLog.warn('chat', '[sealed decrypt fail id=$id]: $e');
      }
      return false;
    }
    if (generation != null && !_isCurrentSession(generation)) return false;
    final fromUsername = env['from_username'] as String?;
    if (fromUsername == null ||
        fromUsername.trim().toLowerCase() !=
            senderUsername.trim().toLowerCase()) {
      appLog.warn(
        'security',
        '[sealed] encrypted sender does not match signer id=$id',
      );
      return false;
    }
    if (_isOlderThanChatDelete(fromUsername, createdAt)) {
      appLog.info(
        'chat',
        'discarding old sealed message from @$fromUsername after chat deletion',
      );
      return true;
    }

    // TDA-4 self-echo: я отправлял с другого устройства → here I'm receiver,
    // но peer диалога — это `peer_hint` (с кем шла реальная переписка), а
    // fromMe=true. Кладём в БД с peer=peer_hint, fromMe=true.
    final isSelfEcho =
        (env['self_echo'] == true) && (fromUsername == _myUsername);
    final peerHint = env['peer_hint'] as String?;
    if (isSelfEcho && peerHint != null) {
      final t = env['type'] as String? ?? 'msg';
      if (t == 'msg') {
        final localSid = _sealedSid(id);
        if (await _db.messageExists(peerHint, localSid)) return true;
        await _db.upsertMessage(
          StoredMessage(
            sid: localSid,
            peer: peerHint,
            fromMe: true,
            text: (env['text'] as String?) ?? '',
            createdAt: createdAt,
          ),
        );
        await _refreshMessages(peerHint);
        await _bumpDialog(
          peerHint,
          lastText: (env['text'] as String?) ?? '',
          fromMe: true,
          lastAt: createdAt,
        );
        return true;
      }
    }

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
          await _refreshDialogs();
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
    if (type == 'user_buttons_remove') {
      final rawTarget = env['target_sid'] is int
          ? env['target_sid'] as int
          : (env['sid'] is int ? env['sid'] as int : null);
      final owner = env['owner_username']?.toString().trim().toLowerCase();
      if (rawTarget != null && owner == fromUsername.toLowerCase()) {
        await _clearDmMessageButtonsIfOwned(
          peer: fromUsername,
          targetSid: rawTarget,
          senderIsMe: false,
          includeSealedSid: true,
        );
      }
      return true;
    }
    if (type == 'delete') {
      final sid = env['sid'];
      if (sid is int) {
        await _db.updateMessageFlags(fromUsername, _sealedSid(sid), {
          'deleted': 1,
          'text': '',
          'file_payload': null,
        });
        await _refreshMessages(fromUsername);
      }
      return true;
    }
    if (type == 'react') {
      final sid = env['sid'];
      final emoji = env['emoji'] as String?;
      final on = env['on'];
      if (sid is int && emoji != null) {
        if (on is bool) {
          await _setReactionLocal(
            fromUsername,
            _sealedSid(sid),
            emoji,
            fromUsername,
            on: on,
          );
        } else {
          await _toggleReactionLocal(
            fromUsername,
            _sealedSid(sid),
            emoji,
            fromUsername,
          );
        }
        await _refreshMessages(fromUsername);
      }
      return true;
    }

    // Обычное text / file / voice
    final isFile = type == 'file' || type == 'voice';
    final durationSec = _mediaDurationSeconds(env['duration']);
    final localSid = _sealedSid(id);
    final existing = await _db.getMessage(fromUsername, localSid);
    if (existing != null && !existing.decryptFailed) return true;
    final stored = StoredMessage(
      sid: localSid,
      peer: fromUsername,
      fromMe: false,
      text: (env['text'] as String?) ?? '',
      createdAt: createdAt,
      replyTo: env['reply_to'] is int ? env['reply_to'] as int : null,
      replyPreview: env['reply_preview'] as String?,
      forwardedFrom: env['forwarded_from'] as String?,
      userButtons: MessageButton.parseList(env['user_buttons']),
      filePayload: isFile
          ? {
              'file_id': env['file_id'],
              'file_name': env['file_name'] ?? '',
              'mime': env['mime'] ?? 'application/octet-stream',
              'size': env['size'] ?? 0,
              'key': env['key'],
              'iv': env['iv'],
              if (env['thumb'] != null) 'thumb': env['thumb'],
              if (type == 'voice') 'voice': true,
              if (durationSec != null) 'duration': durationSec,
              if (type == 'voice' && env['waveform'] != null)
                'waveform': env['waveform'],
            }
          : null,
    );
    // Failed placeholders contain only the server id. Once the old private
    // key is restored, replace that placeholder with the recovered plaintext;
    // a plain "message exists" check used to leave old sealed messages stuck
    // forever as "Не удалось расшифровать".
    await _db.upsertMessage(stored);
    await _refreshMessages(fromUsername);
    final preview = isFile
        ? _filePreview(
            mime: env['mime'] as String?,
            fileName: env['file_name'] as String?,
            voice: type == 'voice',
          )
        : stored.text;
    await _bumpDialog(
      fromUsername,
      lastText: preview,
      fromMe: false,
      lastAt: createdAt,
      incUnread: true,
    );

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
        await _postSignedSealed(toUsername: fromUsername, ciphertext: reply);
      } catch (e) {
        appLog.warn('chat', '[sealed delivered echo] $e');
      }
    }
    return true;
  }

  // ─── Файлы: encrypted blob cache (parity с веб filecache) ────────────
  /// Cache-first скачивание файла. Возвращает encrypted blob или null.
  Future<Uint8List?> fetchEncryptedFile(
    int fileId, {
    bool forceRefresh = false,
  }) async {
    if (!forceRefresh) {
      final cached = await _db.getCachedFile(fileId.toString());
      if (cached != null) return cached;
    } else {
      await _db.deleteCachedFile(fileId.toString());
    }
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
    List<double>? waveform,
    String? sourcePath, // путь к видео для сжатия (video_compress)
    Uint8List? thumbnail, // первый кадр (png) — показываем ДО загрузки
    String? localPath, // локальный файл — превью/проигрывание ПОКА грузится
  }) async {
    if (isPeerBlocked(toUsername)) {
      throw StateError('Пользователь заблокирован');
    }
    try {
      if (await isPeerBot(toUsername)) {
        throw StateError(
          'Вложения для ботов пока не поддерживаются — отправь сообщение текстом',
        );
      }
    } catch (e) {
      if (_isMissingPeerKeysError(e)) {
        throw StateError('У @$toUsername нет E2E-ключей');
      }
      rethrow;
    }
    await _forgetChatDeleted(toUsername);
    final isVideo = mime.toLowerCase().startsWith('video/');
    final mediaDuration = duration > 0 && (voice || isVideo) ? duration : null;
    appLog.info(
      'file',
      'outgoing ${voice ? 'voice' : 'file'} to @$toUsername: $fileName (${bytes.length} bytes)',
    );
    final tempSidId = -DateTime.now().microsecondsSinceEpoch;
    final tmpKey = 'tmp-$tempSidId';
    final thumbB64 = thumbnail != null ? base64Encode(thumbnail) : null;
    // Оптимистично показываем в чате СРАЗУ (с превью-кадром, ещё без file_id).
    await _db.upsertMessage(
      StoredMessage(
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
          if (thumbB64 != null) 'thumb': thumbB64,
          if (localPath != null) '_local': localPath,
          if (voice) 'voice': true,
          if (mediaDuration != null) 'duration': mediaDuration,
          if (voice && waveform != null) 'waveform': waveform,
        },
      ),
    );
    await _refreshMessages(toUsername);
    await _bumpDialog(
      toUsername,
      lastText: _filePreview(mime: mime, fileName: fileName, voice: voice),
      fromMe: true,
    );

    try {
      // 0. Сжатие видео на устройстве (если дан путь и файл крупный) — единый
      // прогресс: сжатие = 0..0.5, аплоад = base..1.0.
      var data = bytes;
      var base = 0.0;
      if (sourcePath != null && bytes.length > 6 * 1024 * 1024) {
        base = 0.5;
        final sub = VideoCompress.compressProgress$.subscribe((p) {
          uploadProgress(tmpKey).value = (p / 100) * 0.5;
        });
        try {
          // LowQuality = самый быстрый энкод (video_compress не даёт FFmpeg-
          // пресетов; Low ≈ 3-5x быстрее Medium). Для чат-видео качество ок.
          final info = await VideoCompress.compressVideo(
            sourcePath,
            quality: VideoQuality.LowQuality,
            deleteOrigin: false,
          ).timeout(const Duration(minutes: 4));
          if (info?.file != null) data = await info!.file!.readAsBytes();
        } finally {
          sub.unsubscribe();
        }
        uploadProgress(tmpKey).value = 0.5;
      }
      // 1. Шифруем (уже сжатый) blob AES-256. Крупные — в ИЗОЛЯТЕ.
      final aesKey = _randomBytes(32);
      final iv = _randomBytes(12);
      final encBytes = data.length < 220 * 1024
          ? _aesGcmEncryptBytes(aesKey, iv, data)
          : await compute(_gcmEncryptIso, <String, dynamic>{
              'key': aesKey,
              'iv': iv,
              'plain': data,
            });
      // 2. Аплоадим encrypted blob — прогресс base..1.0.
      final up = await _api.uploadFile(
        toUsername: toUsername,
        encryptedBytes: encBytes,
        name: voice ? 'voice' : fileName,
        onSendProgress: (sent, total) {
          if (total > 0) {
            uploadProgress(tmpKey).value = base + (sent / total) * (1 - base);
          }
        },
      );
      final fileId = up['file_id'] as int;
      _pendingMediaTempKeys[fileId] = tmpKey;
      // 3. Кэшируем у себя (parity с веб) + ПЛЕЙНТЕКСТ в RAM-кэш → своё медиа
      // открывается мгновенно, без скачивания и расшифровки.
      await _db.cacheFile(fileId.toString(), encBytes, mime);
      await _db.cachePlainFile(fileId.toString(), data, mime);
      _plainCachePut(fileId, data);
      // 4. Передаём ключ AES и metadata только внутри v2-envelope'ов. Сам
      // blob уже зашифрован AES и сервер никогда не получает ключ от payload.
      final payload = <String, dynamic>{
        'type': voice ? 'voice' : 'file',
        'file_id': fileId,
        'file_name': fileName,
        'mime': mime,
        'size': data.length,
        'key': base64Encode(aesKey),
        'iv': base64Encode(iv),
        if (thumbB64 != null) 'thumb': thumbB64,
        if (voice) 'voice': true,
        if (mediaDuration != null) 'duration': mediaDuration,
        if (voice && waveform != null) 'waveform': waveform,
      };
      // Thumbnail/waveform are UX-only metadata; keep the actual attachment
      // usable even when their v2 envelope would exceed the API limit.
      if (jsonEncode(payload).length > 6_000 && payload.containsKey('thumb')) {
        payload.remove('thumb');
        appLog.warn(
          'file',
          'media v2 envelope was large; thumbnail omitted before /v2/send',
        );
      }
      if (jsonEncode(payload).length > 6_000 &&
          payload.containsKey('waveform')) {
        payload.remove('waveform');
        appLog.warn(
          'file',
          'media v2 envelope was large; waveform omitted before /v2/send',
        );
      }
      final v2keys = await getPeerV2Keys(toUsername, forceRefresh: true);
      if (v2keys == null) {
        throw StateError('У @$toUsername нет V2-ключей');
      }
      final realSid = await _sendV2Payload(
        toUsername: toUsername,
        payload: payload,
        keys: v2keys,
      );
      final createdAt = DateTime.now().toUtc().toIso8601String();
      await _db.promoteOptimistic(
        peer: toUsername,
        tempSid: tmpKey,
        realSid: realSid,
        createdAt: createdAt,
      );
      // Заполним file_payload реальным file_id
      await _db.updateMessageFlags(toUsername, realSid, {
        'file_payload': jsonEncode({
          'file_id': fileId,
          'file_name': fileName,
          'mime': mime,
          'size': data.length,
          'key': base64Encode(aesKey),
          'iv': base64Encode(iv),
          // thumb СОХРАНЯЕМ — иначе у отправителя пропадает первый кадр видео.
          if (thumbB64 != null) 'thumb': thumbB64,
          // Для своих вложений сохраняем только исходный путь. Получатель
          // никогда его не видит и скачивает файл обычным E2E-путём.
          if (localPath != null) '_local': localPath,
          if (voice) 'voice': 1,
          if (mediaDuration != null) 'duration': mediaDuration,
          if (voice && waveform != null) 'waveform': waveform,
        }),
        'delivered': 1,
      });
      _pendingMediaTempKeys.remove(fileId);
      appLog.info(
        'file',
        'outgoing file accepted by server: @$toUsername sid=$realSid file=$fileId',
      );
      await _refreshMessages(toUsername);
      await _refreshDialogs();
    } catch (e) {
      final compactError = _compactMediaSendError(e);
      appLog.warn('chat', '[sendDmFile] $compactError');
      // The mapping is only useful until this send attempt finishes. If the
      // echo already consumed it, remove is an intentional no-op.
      _pendingMediaTempKeys.removeWhere((_, key) => key == tmpKey);
      await _markOptimisticSendFailed(peer: toUsername, sid: tempSidId);
      if (compactError != e.toString()) {
        throw StateError(compactError);
      }
      rethrow;
    } finally {
      _uploadProgress.remove(tmpKey);
    }
  }

  /// Расшифровать encrypted blob медиа-сообщения. Возвращает plaintext bytes.
  // RAM-кэш расшифрованных медиа (по file_id): повторный просмотр и СВОЁ медиа
  // открываются мгновенно — без скачивания и повторной расшифровки. Ограничен.
  static final Map<int, Uint8List> _plainCache = {};
  static const int _plainCacheMax = 16;
  static void _plainCachePut(int fileId, Uint8List bytes) {
    _plainCache.remove(fileId);
    _plainCache[fileId] = bytes;
    while (_plainCache.length > _plainCacheMax) {
      _plainCache.remove(_plainCache.keys.first);
    }
  }

  Future<Uint8List?> decryptMediaBlob(StoredMessage m) async {
    final fp = m.filePayload;
    if (fp == null) return null;
    final rawFileId = fp['file_id'];
    final fileId = rawFileId is num
        ? rawFileId.toInt()
        : int.tryParse(rawFileId?.toString() ?? '');
    final keyB64 = fp['key']?.toString();
    final ivB64 = fp['iv']?.toString();
    if (fileId == null || keyB64 == null || ivB64 == null) return null;
    // RAM-кэш расшифрованного → мгновенно при повторном/своём просмотре.
    final cachedPlain = _plainCache[fileId];
    if (cachedPlain != null) return cachedPlain;
    // Постоянный кэш переживает перезапуск приложения. Plaintext намеренно не
    // прогоняем через AES ещё раз: файл уже расшифрован и готов для показа.
    final persistedPlain = await _db.getCachedPlainFile(fileId.toString());
    if (persistedPlain != null) {
      _plainCachePut(fileId, persistedPlain);
      return persistedPlain;
    }

    Uint8List aesKey;
    Uint8List iv;
    try {
      aesKey = Uint8List.fromList(base64Decode(keyB64));
      iv = Uint8List.fromList(base64Decode(ivB64));
      if (aesKey.length != 32 || iv.length != 12) return null;
    } catch (e) {
      appLog.warn('chat', '[decryptMediaBlob] invalid media key: $e');
      return null;
    }

    Future<Uint8List> decryptBytes(Uint8List encBytes) async {
      final args = <String, dynamic>{'key': aesKey, 'iv': iv, 'ct': encBytes};
      // Мелкие файлы (голос/небольшие) — на главном потоке: изолят сам по себе
      // дороже их расшифровки. Большие фото — в ИЗОЛЯТЕ (иначе морозит UI).
      return encBytes.length < 220 * 1024
          ? _gcmDecryptIso(args)
          : await compute(_gcmDecryptIso, args);
    }

    Uint8List? encBytes;
    try {
      encBytes = await fetchEncryptedFile(fileId);
    } catch (e) {
      appLog.warn('chat', '[decryptMediaBlob] encrypted fetch failed: $e');
      return null;
    }
    if (encBytes == null) return null;
    try {
      final plain = await decryptBytes(encBytes);
      await _db.cachePlainFile(
        fileId.toString(),
        plain,
        fp['mime']?.toString(),
      );
      _plainCachePut(fileId, plain);
      return plain;
    } catch (e) {
      // Старые версии могли сохранить битый/неполный blob в filecache. Один
      // принудительный повтор загружает свежие байты и не ломает повторный
      // просмотр уже корректно закэшированного медиа.
      appLog.warn('chat', '[decryptMediaBlob] cached blob failed, retry: $e');
      try {
        final fresh = await fetchEncryptedFile(fileId, forceRefresh: true);
        if (fresh == null) return null;
        final plain = await decryptBytes(fresh);
        await _db.cachePlainFile(
          fileId.toString(),
          plain,
          fp['mime']?.toString(),
        );
        _plainCachePut(fileId, plain);
        return plain;
      } catch (retryError) {
        appLog.warn('chat', '[decryptMediaBlob] retry failed: $retryError');
        return null;
      }
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

  // Для compute(): GCM-расшифровка в фоновом изоляте, чтобы не морозить UI на
  // расшифровке многомегабайтного фото при открытии чата.
  static Uint8List _gcmDecryptIso(Map<String, dynamic> p) {
    final cipher = GCMBlockCipher(AESEngine())
      ..init(
        false,
        AEADParameters(
          KeyParameter(p['key'] as Uint8List),
          128,
          p['iv'] as Uint8List,
          Uint8List(0),
        ),
      );
    return cipher.process(p['ct'] as Uint8List);
  }

  // Для compute(): GCM-шифрование в фоновом изоляте — не морозит UI на
  // шифровании многомегабайтного фото/видео при отправке.
  static Uint8List _gcmEncryptIso(Map<String, dynamic> p) {
    final cipher = GCMBlockCipher(AESEngine())
      ..init(
        true,
        AEADParameters(
          KeyParameter(p['key'] as Uint8List),
          128,
          p['iv'] as Uint8List,
          Uint8List(0),
        ),
      );
    return cipher.process(p['plain'] as Uint8List);
  }

  Uint8List _randomBytes(int n) {
    final r = Random.secure();
    return Uint8List.fromList(List<int>.generate(n, (_) => r.nextInt(256)));
  }

  bool _isMissingPeerKeysError(Object error) {
    final message = error.toString().toLowerCase();
    return message.contains('нет e2e-ключ') ||
        message.contains('нет e2e') ||
        message.contains('no e2e key') ||
        message.contains('no e2e-key');
  }

  Future<int> _sendPlainTextDm({
    required String toUsername,
    required String text,
    required int tempSid,
    required String tmpKey,
    required String clientMessageId,
    Map<String, dynamic>? preparedRequest,
    Future<void> Function(Map<String, dynamic>)? onPreparedRequest,
  }) async {
    final request =
        preparedRequest ??
        <String, dynamic>{
          'to_username': toUsername,
          'plain_text': text,
          'client_message_id': clientMessageId,
        };
    if (preparedRequest == null) await onPreparedRequest?.call(request);
    final resp = await _api.chatPost('/send', request);
    final response = Map<String, dynamic>.from(resp as Map);
    final realSid = response['id'] as int;
    await _db.promoteOptimistic(
      peer: toUsername,
      tempSid: tmpKey,
      realSid: realSid,
      createdAt: response['created_at'],
    );
    var botAcknowledged = response['recipient_online'] == true;
    if (!botAcknowledged) {
      // A fast bot can reply before the HTTP send response promotes the
      // optimistic bubble. In that race, the reply itself confirms delivery.
      final messages = await _db.getMessages(toUsername);
      botAcknowledged = messages.any(
        (message) => !message.fromMe && message.sid > realSid,
      );
    }
    if (botAcknowledged) {
      await _db.updateMessageFlags(toUsername, realSid, {'delivered': 1});
    }
    await _refreshMessages(toUsername);
    await _refreshDialogs();
    return realSid;
  }

  /// Sends an inline keyboard action without exposing a bot's internal ID.
  /// The server resolves the bot from the original message and validates the
  /// callback against that message's stored markup.
  Future<void> sendBotButtonCallback({
    required int messageId,
    required String callbackData,
  }) async {
    if (messageId <= 0 ||
        callbackData.isEmpty ||
        utf8.encode(callbackData).length > 64) {
      throw ArgumentError('Invalid bot button callback');
    }
    final response = await _api.botsPost('/callback', {
      'message_id': messageId,
      'callback_data': callbackData,
    });
    if (response is Map && response['status'] == 'ok') return;
    final detail = response is Map ? response['detail'] : null;
    throw StateError(
      detail is String ? detail : 'Не удалось передать нажатие боту',
    );
  }

  Future<void> _markLatestBotCommandDelivered(
    String peer,
    int botReplySid, {
    int? generation,
  }) async {
    if (generation != null && !_isCurrentSession(generation)) return;
    final messages = await _db.getMessages(peer);
    StoredMessage? latestUnconfirmed;
    for (final message in messages) {
      if (!message.fromMe ||
          message.sid <= 0 ||
          message.sid >= botReplySid ||
          message.pending ||
          message.delivered ||
          message.read) {
        continue;
      }
      if (latestUnconfirmed == null || message.sid > latestUnconfirmed.sid) {
        latestUnconfirmed = message;
      }
    }
    if (latestUnconfirmed == null) return;
    await _db.updateMessageFlags(peer, latestUnconfirmed.sid, {'delivered': 1});
  }

  void _scheduleBotReplyCatchUp(
    String peer,
    int sentSid, {
    required int generation,
  }) {
    final key = '$generation:${peer.trim().toLowerCase()}';
    final currentTarget = _botReplyCatchUpAfterSid[key];
    if (currentTarget == null || sentSid > currentTarget) {
      _botReplyCatchUpAfterSid[key] = sentSid;
    }
    if (!_botReplyCatchUpRunning.add(key)) return;
    unawaited(_runBotReplyCatchUp(peer, key, generation));
  }

  Future<void> _runBotReplyCatchUp(
    String peer,
    String key,
    int generation,
  ) async {
    final firstTarget = _botReplyCatchUpAfterSid[key];
    if (firstTarget == null) {
      _botReplyCatchUpRunning.remove(key);
      return;
    }
    try {
      await catchUpBotReply(
        fetchPending: () => fetchPending(generation: generation),
        hasReply: () async {
          final target = _botReplyCatchUpAfterSid[key] ?? firstTarget;
          final messages = await _db.getMessages(peer);
          return messages.any(
            (message) => !message.fromMe && message.sid > target,
          );
        },
        isCurrentSession: () => _isCurrentSession(generation),
      );
    } catch (e) {
      appLog.warn('chat', '[bot reply catch-up] $e');
    }

    _botReplyCatchUpRunning.remove(key);
    if (!_isCurrentSession(generation)) {
      _botReplyCatchUpAfterSid.remove(key);
      return;
    }

    final latestTarget = _botReplyCatchUpAfterSid[key];
    if (latestTarget == null) return;
    try {
      final messages = await _db.getMessages(peer);
      final replyVisible = messages.any(
        (message) => !message.fromMe && message.sid > latestTarget,
      );
      if (replyVisible || latestTarget <= firstTarget) {
        _botReplyCatchUpAfterSid.remove(key);
      } else if (_botReplyCatchUpRunning.add(key)) {
        // A second command was sent while the first bounded replay was
        // running. Give that command its own short catch-up window.
        unawaited(_runBotReplyCatchUp(peer, key, generation));
      }
    } catch (e) {
      _botReplyCatchUpAfterSid.remove(key);
      appLog.warn('chat', '[bot reply catch-up state] $e');
    }
  }

  /// Основной legacy DM-путь.
  ///
  /// Legacy `/send` остаётся HTTP-путём: он уже является стабильным
  /// контрактом для мобильного клиента и возвращает серверный sid. WS RPC
  /// здесь не используем — при смешении версий клиента и сервера ошибка
  /// валидации общего поля `ciphertext` начинала ломать все типы сообщений,
  /// а повтор через HTTP мог создать дубль.
  Future<Map<String, dynamic>> _sendChatCiphertext({
    required String toUsername,
    required String ciphertext,
  }) async {
    final body = <String, dynamic>{
      'to_username': toUsername,
      'ciphertext': ciphertext,
    };
    final response = await _api.chatPost('/send', body);
    return Map<String, dynamic>.from(response as Map);
  }

  /// Temporary compatibility path for accounts/devices that still have the
  /// original v1 E2E key but have not completed v2 identity recovery yet.
  Future<void> _sendDmTextLegacy({
    required String toUsername,
    required String text,
    required String tmpKey,
    required Future<void> Function(Map<String, dynamic>) onPreparedRequest,
    int? replyTo,
    String? replyPreview,
    Map<String, dynamic>? preparedRequest,
    List<MessageButton> userButtons = const [],
  }) async {
    final request = preparedRequest ?? <String, dynamic>{};
    if (preparedRequest == null) {
      final peerPubs = await getPeerDevicePubs(toUsername);
      if (peerPubs.isEmpty) {
        throw StateError('У @$toUsername нет E2E-ключей');
      }
      final payload = jsonEncode({
        'type': 'msg',
        'text': text,
        if (replyTo != null) 'reply_to': replyTo,
        if (replyPreview != null && replyPreview.isNotEmpty)
          'reply_preview': replyPreview,
        if (userButtons.isNotEmpty)
          'user_buttons': MessageButton.encodeList(userButtons),
      });
      request.addAll({
        'to_username': toUsername,
        'ciphertext': await _crypto.encryptFor(
          theirPubRaw: peerPubs.first,
          plaintext: payload,
        ),
      });
      await onPreparedRequest(request);
    }
    final response = Map<String, dynamic>.from(
      await _api.chatPost('/send', request) as Map,
    );
    final realSid = response['id'] as int;
    await _db.promoteOptimistic(
      peer: toUsername,
      tempSid: tmpKey,
      realSid: realSid,
      createdAt: response['created_at'],
    );
    if (response['recipient_online'] == true) {
      await _db.updateMessageFlags(toUsername, realSid, {'delivered': 1});
    }
    await _refreshMessages(toUsername);
    await _refreshDialogs();
  }

  Future<void> _markOptimisticSendFailed({
    required String peer,
    required int sid,
  }) async {
    try {
      await _db.updateMessageFlags(peer, sid, {'pending': 0, 'delivered': 0});
      await _refreshMessages(peer);
      await _refreshDialogs();
    } catch (e) {
      // Ошибка обновления локального статуса не должна скрывать исходную
      // сетевую/криптографическую причину отказа отправки.
      appLog.warn('chat', '[mark send failed] $e');
    }
  }

  // ─── Отправка текста (через legacy /send — sealed-sender в вебе временно
  //     ОТКЛЮЧЁН: см. chat/index.html — для отправки используется /send,
  //     /send_sealed только для delivered-echo. Чтобы веб-получатель видел
  //     мои сообщения, шлём legacy способом.) ──────────────────────────────
  Future<void> sendDmText(
    String toUsername,
    String text, {
    int? replyTo,
    String? replyPreview,
    String? forwardedFrom,
    List<MessageButton> userButtons = const [],
  }) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    final sessionGeneration = _sessionGeneration;
    if (isPeerBlocked(toUsername)) {
      throw StateError('Пользователь заблокирован');
    }
    await _forgetChatDeleted(toUsername);
    appLog.info(
      'msg',
      'outgoing text to @$toUsername (${trimmed.length} chars)',
    );
    final tempSid = -DateTime.now().microsecondsSinceEpoch;
    final clientMessageId = const Uuid().v4();
    final tmpKey = 'outbox-$clientMessageId';
    final clientSid = DateTime.now().microsecondsSinceEpoch;
    final queuedAt = DateTime.now().toUtc().toIso8601String();
    await _db.enqueueDmText(
      id: clientMessageId,
      peer: toUsername,
      payload: {
        'peer': toUsername,
        'text': trimmed,
        'temp_sid': tempSid,
        'temp_key': tmpKey,
        'client_sid': clientSid,
        if (replyTo != null) 'reply_to': replyTo,
        if (replyPreview != null) 'reply_preview': replyPreview,
        if (forwardedFrom != null) 'forwarded_from': forwardedFrom,
        if (userButtons.isNotEmpty)
          'user_buttons': MessageButton.encodeList(userButtons),
      },
      optimisticMessage: StoredMessage(
        sid: tempSid,
        peer: toUsername,
        fromMe: true,
        text: trimmed,
        createdAt: queuedAt,
        pending: true,
        tempSid: tmpKey,
        replyTo: replyTo,
        replyPreview: replyPreview,
        forwardedFrom: forwardedFrom,
        userButtons: userButtons
            .where((button) => button.isValid)
            .take(MessageButton.maxCount)
            .toList(growable: false),
      ),
    );
    await _refreshMessages(toUsername);
    await _bumpDialog(toUsername, lastText: trimmed, fromMe: true);

    // The composer can clear as soon as the draft is durably stored. Network
    // work is serialized in the background and survives process restarts.
    unawaited(_drainDmOutbox(sessionGeneration));
  }

  Future<void> _drainDmOutbox(int generation) {
    if (!_isCurrentSession(generation)) return Future<void>.value();
    final running = _outboxDrain;
    if (running != null) return running;
    late final Future<void> drain;
    drain = _drainDmOutboxImpl(generation).whenComplete(() {
      if (identical(_outboxDrain, drain)) _outboxDrain = null;
    });
    _outboxDrain = drain;
    return drain;
  }

  Future<void> _drainDmOutboxImpl(int generation) async {
    if (!_isCurrentSession(generation)) return;
    try {
      final entries = await _db.dueOutboxEntries(limit: 100, kind: 'dm_text');
      for (final entry in entries) {
        if (!_isCurrentSession(generation)) return;
        final draft = entry.payload;
        final peer = draft['peer']?.toString() ?? entry.target;
        final tempSid = int.tryParse(draft['temp_sid']?.toString() ?? '');
        final clientSid = int.tryParse(draft['client_sid']?.toString() ?? '');
        final tmpKey = draft['temp_key']?.toString();
        final text = draft['text']?.toString() ?? '';
        final userButtons = MessageButton.parseList(draft['user_buttons']);
        if (tempSid == null ||
            clientSid == null ||
            tmpKey == null ||
            text.isEmpty) {
          await _db.deleteOutboxEntry(entry.id);
          continue;
        }
        try {
          await _sendDmTextNow(
            peer,
            text,
            tempSid: tempSid,
            tmpKey: tmpKey,
            clientMessageId: entry.id,
            clientSid: clientSid,
            preparedRequest: entry.requestPayload,
            replyTo: int.tryParse(draft['reply_to']?.toString() ?? ''),
            replyPreview: draft['reply_preview']?.toString(),
            forwardedFrom: draft['forwarded_from']?.toString(),
            userButtons: userButtons,
            generation: generation,
            savePreparedRequest: (request) =>
                _db.saveOutboxRequest(entry.id, request),
          );
          if (!_isCurrentSession(generation)) return;
          await _db.deleteOutboxEntry(entry.id);
        } catch (error) {
          if (!_isCurrentSession(generation)) return;
          if (!_isTransientOutboxError(error)) {
            await _markOptimisticSendFailed(peer: peer, sid: tempSid);
            await _db.deleteOutboxEntry(entry.id);
            appLog.warn('outbox', 'permanent DM send failure @$peer: $error');
            continue;
          }
          final attempts = entry.attempts + 1;
          final delaySeconds = (1 << attempts.clamp(0, 8)).clamp(2, 300);
          await _db.scheduleOutboxRetry(
            id: entry.id,
            attempts: attempts,
            nextAttemptAt: DateTime.now()
                .add(Duration(seconds: delaySeconds))
                .millisecondsSinceEpoch,
            error: error.toString(),
          );
          appLog.warn('outbox', 'queued DM retry in ${delaySeconds}s: $error');
          // Do not let later messages overtake the unsent text on weak links.
          return;
        }
      }
    } catch (error) {
      appLog.warn('outbox', 'DM queue scan failed: $error');
    }
  }

  bool _isTransientOutboxError(Object error) {
    if (error is ApiException) {
      return error.status == 408 || error.status == 429 || error.status >= 500;
    }
    final message = error.toString().toLowerCase();
    if (message.contains('forbidden') ||
        message.contains('заблокирован') ||
        message.contains('не найден') ||
        message.contains('invalid') ||
        message.contains('422')) {
      return false;
    }
    return true;
  }

  Future<void> _sendDmTextNow(
    String toUsername,
    String text, {
    required int tempSid,
    required String tmpKey,
    required String clientMessageId,
    required int clientSid,
    required int generation,
    required Future<void> Function(Map<String, dynamic>) savePreparedRequest,
    Map<String, dynamic>? preparedRequest,
    int? replyTo,
    String? replyPreview,
    String? forwardedFrom,
    List<MessageButton> userButtons = const [],
  }) async {
    if (!_isCurrentSession(generation)) return;
    final trimmed = text.trim();
    final sessionGeneration = generation;

    // If encryption and request construction already completed before a
    // timeout/app restart, replay those exact bytes. This is both cheaper on
    // 2G and independent of another keys round-trip; the server deduplicates
    // by this stable client_message_id.
    if (preparedRequest != null) {
      if (preparedRequest['plain_text'] is String) {
        final response = Map<String, dynamic>.from(
          await _api.chatPost('/send', preparedRequest) as Map,
        );
        final realSid = response['id'] as int;
        await _db.promoteOptimistic(
          peer: toUsername,
          tempSid: tmpKey,
          realSid: realSid,
          createdAt: response['created_at'],
        );
        if (response['recipient_online'] == true) {
          await _db.updateMessageFlags(toUsername, realSid, {'delivered': 1});
        }
        _scheduleBotReplyCatchUp(
          toUsername,
          realSid,
          generation: sessionGeneration,
        );
        await _refreshMessages(toUsername);
        await _refreshDialogs();
      } else if (preparedRequest['envelopes'] is List) {
        await _api.chatPost('/v2/send', preparedRequest);
        await _db.promoteOptimistic(
          peer: toUsername,
          tempSid: tmpKey,
          realSid: clientSid,
          createdAt: DateTime.now().toUtc().toIso8601String(),
        );
        await _db.updateMessageFlags(toUsername, clientSid, {
          'pending': 0,
          'delivered': 1,
        });
        await _refreshMessages(toUsername);
        await _refreshDialogs();
      } else {
        await _sendDmTextLegacy(
          toUsername: toUsername,
          text: trimmed,
          tmpKey: tmpKey,
          onPreparedRequest: savePreparedRequest,
          preparedRequest: preparedRequest,
          userButtons: userButtons,
        );
      }
      return;
    }

    // Боты не участвуют в E2E (см. isPeerBot/bot_api.py) — plain_text вместо
    // всей v1/v2-крипто-развилки ниже.
    bool peerIsBot;
    try {
      peerIsBot = await isPeerBot(toUsername);
    } catch (e) {
      // Старый сервер не возвращал is_bot, хотя его /send уже мог принимать
      // plain_text. Пробуем bot-режим только после явной ошибки отсутствия
      // ключей; обычный сервер отвергнет plain_text сам.
      if (!_isMissingPeerKeysError(e)) {
        rethrow;
      }
      if (userButtons.isNotEmpty) {
        throw StateError('Кнопки сообщений недоступны в чате с ботом');
      }
      try {
        final sentSid = await _sendPlainTextDm(
          toUsername: toUsername,
          text: trimmed,
          tempSid: tempSid,
          tmpKey: tmpKey,
          clientMessageId: clientMessageId,
          preparedRequest: preparedRequest,
          onPreparedRequest: savePreparedRequest,
        );
        // Сервис подтвердил plaintext-режим ответом /send. Запоминаем это,
        // иначе следующий текст в течение TTL снова пойдёт в E2E-ветку.
        _peerIsBotCache[toUsername] = true;
        _peerInfoFetchedAt[toUsername] = DateTime.now();
        unawaited(_savePeerInfoToDisk());
        _scheduleBotReplyCatchUp(
          toUsername,
          sentSid,
          generation: sessionGeneration,
        );
        return;
      } catch (plainError) {
        appLog.warn('chat', '[sendDmText→plain fallback] $plainError');
        rethrow;
      }
    }

    if (peerIsBot) {
      if (userButtons.isNotEmpty) {
        throw StateError('Кнопки сообщений недоступны в чате с ботом');
      }
      try {
        final sentSid = await _sendPlainTextDm(
          toUsername: toUsername,
          text: trimmed,
          tempSid: tempSid,
          tmpKey: tmpKey,
          clientMessageId: clientMessageId,
          preparedRequest: preparedRequest,
          onPreparedRequest: savePreparedRequest,
        );
        _scheduleBotReplyCatchUp(
          toUsername,
          sentSid,
          generation: sessionGeneration,
        );
      } catch (e) {
        appLog.warn('chat', '[sendDmText→bot] $e');
        rethrow;
      }
      return;
    }

    try {
      if (CryptoV2.instance.ready && _v2Published) {
        // Device bundles are cached briefly. _sendV2Payload still retries once
        // with a forced refresh if the server reports a rotated device key.
        final v2keys = await getPeerV2Keys(toUsername, forceRefresh: false);
        if (v2keys != null) {
          return _sendDmTextV2(
            toUsername: toUsername,
            text: trimmed,
            keys: v2keys,
            tempSid: tempSid,
            tmpKey: tmpKey,
            clientMessageId: clientMessageId,
            clientSid: clientSid,
            preparedRequest: preparedRequest,
            onPreparedRequest: savePreparedRequest,
            replyTo: replyTo,
            replyPreview: replyPreview,
            forwardedFrom: forwardedFrom,
            userButtons: userButtons,
          );
        }
      }
      return _sendDmTextLegacy(
        toUsername: toUsername,
        text: trimmed,
        tmpKey: tmpKey,
        onPreparedRequest: savePreparedRequest,
        replyTo: replyTo,
        replyPreview: replyPreview,
        userButtons: userButtons,
      );
    } catch (e) {
      appLog.warn('chat', '[sendDmText] $e');
      rethrow;
    }
  }

  /// TDA-4: отправка sealed envelope под конкретный pubkey. Используется
  /// для fanout-копий пира + self-echo на свои other-devices. Если
  /// selfEcho=true — отправляется НА свой username, payload содержит
  /// `peer_hint` (с кем реально шёл диалог), чтобы получающее устройство
  /// положило сообщение в правильный peer-чат.
  Future<void> _fanoutSealed({
    required String toUsername,
    required Uint8List pub,
    required String me,
    required String text,
    bool selfEcho = false,
    String? peerHint,
  }) async {
    try {
      final payload = <String, dynamic>{
        'type': 'msg',
        'text': text,
        if (selfEcho && peerHint != null) 'peer_hint': peerHint,
        if (selfEcho) 'self_echo': true,
      };
      final ct = await _crypto.encryptSealed(
        receiverPubRaw: pub,
        payload: payload,
        fromUsername: me,
      );
      await _postSignedSealed(toUsername: toUsername, ciphertext: ct);
    } catch (e) {
      appLog.warn('chat', '[ChatRepo._fanoutSealed] $e');
    }
  }

  /// Sealed-копия ПРОИЗВОЛЬНОГО payload (например файл: file_id+key+iv) на одно
  /// устройство пира. Получатель распакует через _ingestSealed (он умеет file).
  Future<void> _fanoutSealedPayload({
    required String toUsername,
    required Uint8List pub,
    required String me,
    required Map<String, dynamic> payload,
  }) async {
    try {
      final ct = await _crypto.encryptSealed(
        receiverPubRaw: pub,
        payload: payload,
        fromUsername: me,
      );
      await _postSignedSealed(toUsername: toUsername, ciphertext: ct);
    } catch (e) {
      appLog.warn('chat', '[ChatRepo._fanoutSealedPayload] $e');
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
  Future<void> _onChatNew(Map<String, dynamic> d, {int? generation}) async {
    final session = generation ?? _sessionGeneration;
    if (!_isCurrentSession(session)) return;
    final ingested = await _ingestIncoming(
      d,
      fromPending: false,
      generation: session,
    );
    final id = d['id'] as int?;
    if (ingested && id != null && _isCurrentSession(session)) {
      try {
        await _api.chatPost('/ack', {
          'ids': [id],
        });
      } catch (_) {}
    }
  }

  Future<void> _onChatEcho(Map<String, dynamic> d, {int? generation}) async {
    final session = generation ?? _sessionGeneration;
    if (!_isCurrentSession(session)) return;
    // Echo своего сообщения — дедуп по sid в БД. Если уже есть — игнорим.
    final id = d['id'] as int?;
    final fromUsername = d['from_username'] as String?;
    final toUsername = d['to_username'] as String?;
    if (id == null) return;
    final peer = (fromUsername == _myUsername) ? toUsername : fromUsername;
    if (peer == null) return;
    // A previous key mismatch may have left a decrypt_failed placeholder for
    // this sid. It is not a successfully delivered message: allow normal
    // ingest to replace it after the old key is recovered.
    final existing = await _db.getMessage(peer, id);
    if (existing != null && !existing.decryptFailed) return;
    // Другая вкладка/устройство — это новое сообщение от нас, добавим.
    await _ingestIncoming(d, fromPending: false, generation: session);
  }

  Future<void> _onChatDelivered(
    Map<String, dynamic> d, {
    int? generation,
  }) async {
    final session = generation ?? _sessionGeneration;
    if (!_isCurrentSession(session)) return;
    final ids = (d['ids'] as List?)?.cast<int>() ?? [];
    final peer = d['by_username'] as String?;
    if (peer == null || ids.isEmpty) return;
    for (final id in ids) {
      await _db.updateMessageFlags(peer, id, {'delivered': 1});
    }
    await _refreshMessages(peer, generation: session);
    await _refreshDialogs(generation: session);
  }

  Future<void> _onChatRead(Map<String, dynamic> d, {int? generation}) async {
    final session = generation ?? _sessionGeneration;
    if (!_isCurrentSession(session)) return;
    final ids = (d['ids'] as List?)?.cast<int>() ?? [];
    final peer = d['by_username'] as String?;
    if (peer == null || ids.isEmpty) return;
    for (final id in ids) {
      await _db.updateMessageFlags(peer, id, {'read': 1, 'delivered': 1});
    }
    await _refreshMessages(peer, generation: session);
    await _refreshDialogs(generation: session);
  }

  Future<void> _onPeerDevicesChanged(
    Map<String, dynamic> d, {
    int? generation,
  }) async {
    if (generation != null && !_isCurrentSession(generation)) return;
    final username = d['username'] as String?;
    if (username == null) return;
    _peerPubCache.remove(username);
    _peerDevicePubsCache.remove(username);
    // КРИТ: v2-кэш ТОЖЕ инвалидируем. Иначе после ротации/нового устройства
    // пира мы продолжаем слать его СТАРОМУ device → текущее устройство пира не
    // расшифрует («ошибка расшифровки»). Раньше чистили только v1-кэши.
    _v2KeysCache.remove(username);
    _v2KeysFetchedAt.remove(username);
    appLog.warn('chat', '[ChatRepo] key-cache (v1+v2) очищен для @$username');
  }

  Future<void> _onPresence(Map<String, dynamic> d, {int? generation}) async {
    if (generation != null && !_isCurrentSession(generation)) return;
    final rawUsername = d['username'] as String?;
    final online = (d['online'] as bool?) ?? false;
    if (rawUsername == null) return;
    final username = _normalizePresenceUsername(rawUsername);
    final notif = _presenceByPeer[username];
    if (notif != null) notif.value = online;
  }

  Future<void> _onChatClearedByPeer(
    Map<String, dynamic> d, {
    int? generation,
  }) async {
    final session = generation ?? _sessionGeneration;
    if (!_isCurrentSession(session)) return;
    final peer = d['by_username'] as String?;
    if (peer == null) return;
    await _rememberChatDeleted(peer);
    await _db.deleteMessagesByPeer(peer);
    await _db.deleteDialog(peer);
    if (!_isCurrentSession(session)) return;
    _msgsByPeer[peer]?.value = [];
    dialogsNotifier.value = await _db.getDialogs();
  }

  // ─── Расшифровка и сохранение входящего ───────────────────────────────
  Future<void> _storeDecryptFailure({
    required String peer,
    required int sid,
    required bool fromMe,
    dynamic createdAt,
    int? generation,
  }) async {
    if (generation != null && !_isCurrentSession(generation)) return;
    final existing = await _db.getMessage(peer, sid);
    if (existing != null && existing.decryptFailed) return;
    await _db.upsertMessage(
      StoredMessage(
        sid: sid,
        peer: peer,
        fromMe: fromMe,
        createdAt: createdAt ?? DateTime.now().toUtc().toIso8601String(),
        decryptFailed: true,
      ),
    );
    await _refreshMessages(peer, generation: generation);
    await _bumpDialog(
      peer,
      lastText: 'Не удалось расшифровать сообщение',
      fromMe: fromMe,
      lastAt: createdAt,
      incUnread: !fromMe,
      generation: generation,
    );
  }

  Future<bool> _ingestIncoming(
    Map<String, dynamic> m, {
    required bool fromPending,
    int? generation,
  }) async {
    if (generation != null && !_isCurrentSession(generation)) return false;
    final fromUsername = (m['from_username'] is String)
        ? (m['from_username'] as String).trim()
        : null;
    final toUsername = (m['to_username'] is String)
        ? (m['to_username'] as String).trim()
        : null;
    if (fromUsername == null || fromUsername.isEmpty) return false;
    final isMine = fromUsername == _myUsername;
    final peerUsername = isMine ? toUsername : fromUsername;
    if (peerUsername == null || peerUsername.isEmpty) return false;
    final sid = m['id'];
    if (sid is! int || sid <= 0) return false;
    if (_isOlderThanChatDelete(peerUsername, m['created_at'])) {
      appLog.info(
        'chat',
        'discarding old message from @$peerUsername after chat deletion',
      );
      return true;
    }
    if (isPeerBlocked(peerUsername)) {
      appLog.info('chat', 'incoming from blocked peer ignored: @$peerUsername');
      return true;
    }
    // Боты не участвуют в E2E — сервер отдаёт plain_text вместо ciphertext
    // (см. isPeerBot/sendDmText), расшифровывать нечего.
    final rawBotPlain = m['plain_text'];
    if (rawBotPlain != null && rawBotPlain is! String) return false;
    final botPlain = rawBotPlain as String?;
    final Map<String, dynamic> payload;
    if (botPlain != null) {
      _peerIsBotCache[peerUsername] = true;
      payload = {
        'type': 'msg',
        'text': botPlain,
        'reply_markup': ?m['reply_markup'],
      };
    } else {
      if (shouldDeferKnownBotMessage(
        isKnownBot: _isPeerBotKnown(peerUsername),
        plainText: botPlain,
      )) {
        appLog.warn(
          'chat',
          'bot event from @$peerUsername has no plain_text; replaying history',
        );
        if (!fromPending) {
          _scheduleBotHistoryReplay(
            peerUsername,
            generation: generation ?? _sessionGeneration,
          );
        }
        return false;
      }
      // Pubkey пира одинаков и для исходящего, и для входящего (DM один общий
      // ECDH с peer.static_pub). Раньше тут был баг с бессмысленным тернарником.
      final rawCipher = m['ciphertext'];
      if (rawCipher is! String ||
          rawCipher.isEmpty ||
          rawCipher.length > _maxChatCiphertextChars) {
        await _storeDecryptFailure(
          peer: peerUsername,
          sid: sid,
          fromMe: isMine,
          createdAt: m['created_at'],
          generation: generation,
        );
        return false;
      }
      final cipher = rawCipher;
      // Шаг 1: перебираем ВСЕ ключи отправителя (device_pubkeys + owner) — у
      // мульти-девайс отправителя сообщение зашифровано приватником одного
      // устройства, owner/primary часто ≠ device-ключам.
      String? plain = await _tryDecryptAnyPub(peerUsername, cipher);
      if (plain == null) {
        // Шаг 2: ни один известный ключ не подошёл — мог смениться. В старом
        // рабочем клиенте обновление ключей и повтор происходили в этом же
        // проходе. Фоновый-only retry оставлял пользователю сообщение
        // «не удалось расшифровать» до следующего pending-цикла.
        appLog.warn(
          'chat',
          '_ingestIncoming: decrypt fail (peer=$peerUsername) — '
              'refresh and retry now',
        );
        final normalizedPeer = peerUsername.trim().toLowerCase();
        final lastRecovery = _lastPeerDecryptRecoveryAt[normalizedPeer];
        final canRefreshNow =
            lastRecovery == null ||
            DateTime.now().difference(lastRecovery) >=
                _peerDecryptRecoveryCooldown;
        if (canRefreshNow) {
          _lastPeerDecryptRecoveryAt[normalizedPeer] = DateTime.now();
          try {
            await _refreshPeerPubAfterDecryptFail(normalizedPeer);
            if (generation == null || _isCurrentSession(generation)) {
              plain = await _tryDecryptAnyPub(peerUsername, cipher);
            }
          } catch (e) {
            appLog.warn(
              'chat',
              '[decrypt recovery] immediate retry failed for '
                  '@$normalizedPeer: $e',
            );
          }
        } else {
          // Один refresh на peer за cooldown: остальные сообщения используют
          // уже обновлённый кэш и не создают лавину HTTP-запросов.
          _schedulePeerDecryptRecovery(peerUsername, generation: generation);
        }
      }
      if (plain == null) {
        // Keep the server-side pending record. The open-chat key watcher can
        // repair/recover the local key and retry it on the next tick.
        appLog.warn(
          'security',
          'incoming decrypt still failed for @$peerUsername; not acking sid=${m['id']}',
        );
        await _storeDecryptFailure(
          peer: peerUsername,
          sid: sid,
          fromMe: isMine,
          createdAt: m['created_at'],
          generation: generation,
        );
        return false;
      }
      payload = _parsePayload(plain);
    }
    if (generation != null && !_isCurrentSession(generation)) return false;
    final type = payload['type'] is String ? payload['type'] as String : 'msg';
    appLog.info(
      type == 'file' || type == 'voice' ? 'file' : 'msg',
      'incoming ${fromPending ? 'pending' : 'realtime'} from @$peerUsername type=$type sid=${m['id']}',
    );

    // ─── Управляющие типы: правка/удаление/реакция/forward-ack ───
    if (type == 'edit') {
      final targetSid = payload['sid'] is int ? payload['sid'] as int : null;
      final newText = payload['text'] is String
          ? payload['text'] as String
          : '';
      if (targetSid != null) {
        await _db.updateMessageFlags(peerUsername, targetSid, {
          'text': newText,
          'edited': 1,
        });
        await _refreshMessages(peerUsername, generation: generation);
      }
      return true;
    }
    if (type == 'user_buttons_remove') {
      final targetSid = payload['target_sid'] is int
          ? payload['target_sid'] as int
          : (payload['sid'] is int ? payload['sid'] as int : null);
      final owner = payload['owner_username']?.toString().trim().toLowerCase();
      if (targetSid != null && owner == fromUsername.toLowerCase()) {
        await _clearDmMessageButtonsIfOwned(
          peer: peerUsername,
          targetSid: targetSid,
          senderIsMe: isMine,
          includeSealedSid: true,
        );
      }
      return true;
    }
    if (type == 'delete') {
      final targetSid = payload['sid'] is int ? payload['sid'] as int : null;
      if (targetSid != null) {
        await _db.updateMessageFlags(peerUsername, targetSid, {
          'deleted': 1,
          'text': '',
          'file_payload': null,
        });
        await _refreshMessages(peerUsername, generation: generation);
      }
      return true;
    }
    if (type == 'react') {
      final targetSid = payload['sid'] is int ? payload['sid'] as int : null;
      final emoji = payload['emoji'] is String
          ? payload['emoji'] as String
          : null;
      final actor = isMine ? _myUsername : peerUsername;
      final on = payload['on'];
      if (targetSid != null && emoji != null && actor != null) {
        if (on is bool) {
          await _setReactionLocal(
            peerUsername,
            targetSid,
            emoji,
            actor,
            on: on,
          );
        } else {
          await _toggleReactionLocal(peerUsername, targetSid, emoji, actor);
        }
        await _refreshMessages(peerUsername, generation: generation);
      }
      return true;
    }

    // ─── Обычное сообщение / файл / голосовое ───
    final isFile = type == 'file' || type == 'voice';
    final durationSec = _mediaDurationSeconds(payload['duration']);
    final stored = StoredMessage(
      sid: sid,
      peer: peerUsername,
      fromMe: isMine,
      text: payload['text'] is String ? payload['text'] as String : '',
      createdAt: m['created_at'],
      replyTo: payload['reply_to'] is int ? payload['reply_to'] as int : null,
      replyPreview: payload['reply_preview'] is String
          ? payload['reply_preview'] as String
          : null,
      forwardedFrom: payload['forwarded_from'] is String
          ? payload['forwarded_from'] as String
          : null,
      userButtons: MessageButton.parseList(payload['user_buttons']),
      replyMarkup: !isMine && botPlain != null
          ? BotReplyMarkup.tryParse(payload['reply_markup'])
          : null,
      filePayload: isFile
          ? {
              'file_id': payload['file_id'],
              'file_name': payload['file_name'] is String
                  ? payload['file_name'] as String
                  : '',
              'mime': payload['mime'] is String
                  ? payload['mime'] as String
                  : 'application/octet-stream',
              'size': payload['size'] is int ? payload['size'] as int : 0,
              'key': payload['key'] is String ? payload['key'] as String : '',
              'iv': payload['iv'] is String ? payload['iv'] as String : '',
              if (payload['thumb'] != null) 'thumb': payload['thumb'],
              if (type == 'voice') 'voice': true,
              if (durationSec != null) 'duration': durationSec,
              if (type == 'voice' && payload['waveform'] != null)
                'waveform': payload['waveform'],
            }
          : null,
    );
    if (isMine && !isFile && stored.text.isNotEmpty) {
      final tempSid = await _db.findPendingTextTempSid(
        peerUsername,
        stored.text,
      );
      if (tempSid != null) {
        await _db.promoteOptimistic(
          peer: peerUsername,
          tempSid: tempSid,
          realSid: stored.sid,
          createdAt: stored.createdAt,
        );
      }
    }
    if (isMine && isFile) {
      final rawFileId = payload['file_id'];
      final fileId = rawFileId is int
          ? rawFileId
          : int.tryParse(rawFileId?.toString() ?? '');
      final tempKey = fileId == null
          ? null
          : _pendingMediaTempKeys.remove(fileId);
      if (tempKey != null) {
        await _db.promoteOptimistic(
          peer: peerUsername,
          tempSid: tempKey,
          realSid: stored.sid,
          createdAt: stored.createdAt,
        );
      }
    }
    if (!isMine && botPlain != null) {
      await _markLatestBotCommandDelivered(
        peerUsername,
        sid,
        generation: generation,
      );
    }
    await _db.upsertMessage(stored);
    await _refreshMessages(peerUsername, generation: generation);
    final preview = isFile
        ? _filePreview(
            mime: payload['mime'] as String?,
            fileName: payload['file_name'] as String?,
            voice: type == 'voice',
          )
        : stored.text;
    await _bumpDialog(
      peerUsername,
      lastText: preview,
      fromMe: isMine,
      lastAt: m['created_at'],
      incUnread: !isMine && fromPending,
      generation: generation,
    );
    // Уведомление о входящем (не своём). Сервис сам не дёрнет, если открыт
    // именно этот чат. Работает пока приложение живо (WS-листенер активен).
    if (!isMine) {
      NotificationService.instance.onIncoming(
        peer: peerUsername,
        preview: preview,
        senderName: _notificationSenderName(peerUsername),
        kind: classifyNotificationKind(
          mime: payload['mime'] as String?,
          voice: type == 'voice',
        ),
        thumbnailBase64: stored.filePayload?['thumb'] as String?,
      );
    }
    return true;
  }

  /// Локально применить toggle реакции к сообщению.
  Future<void> _toggleReactionLocal(
    String peer,
    int sid,
    String emoji,
    String actor,
  ) async {
    final list = await _db.getMessages(peer);
    final m = list.firstWhere(
      (x) => x.sid == sid,
      orElse: () =>
          StoredMessage(sid: -1, peer: peer, fromMe: false, createdAt: ''),
    );
    if (m.sid == -1) return;
    final reactions = Map<String, List<String>>.from(
      m.reactions ?? <String, List<String>>{},
    );
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

  /// Идемпотентно ВЫСТАВИТЬ реакцию actor'а (on=true добавить, false убрать).
  /// В отличие от toggle — повтор с тем же состоянием = no-op, поэтому эхо
  /// своей реакции / мультидевайс / повторная доставка не вызывают «мигание».
  Future<void> _setReactionLocal(
    String peer,
    int sid,
    String emoji,
    String actor, {
    required bool on,
  }) async {
    final list = await _db.getMessages(peer);
    final m = list.firstWhere(
      (x) => x.sid == sid,
      orElse: () =>
          StoredMessage(sid: -1, peer: peer, fromMe: false, createdAt: ''),
    );
    if (m.sid == -1) return;
    final reactions = Map<String, List<String>>.from(
      m.reactions ?? <String, List<String>>{},
    );
    final users = List<String>.from(reactions[emoji] ?? const []);
    final has = users.contains(actor);
    if (on && !has) {
      users.add(actor);
    } else if (!on && has) {
      users.remove(actor);
    } else {
      return; // уже в нужном состоянии — ничего не меняем
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

  Future<void> _clearDmMessageButtonsIfOwned({
    required String peer,
    required int targetSid,
    required bool senderIsMe,
    bool includeSealedSid = false,
  }) async {
    final candidates = <int>{targetSid};
    if (includeSealedSid && targetSid > 0) {
      candidates.add(_sealedSid(targetSid));
    }
    for (final sid in candidates) {
      final message = await _db.getMessage(peer, sid);
      if (message == null || message.fromMe != senderIsMe) continue;
      await _db.updateMessageFlags(peer, sid, {'user_buttons_json': null});
      await _refreshMessages(peer);
      return;
    }
  }

  Future<void> removeDmMessageButtons({
    required String toUsername,
    required int sid,
  }) async {
    final message = await _db.getMessage(toUsername, sid);
    if (message == null ||
        !message.fromMe ||
        message.userButtons.isEmpty ||
        message.pending ||
        sid <= 0) {
      throw StateError('У этого сообщения нет ваших кнопок');
    }
    final owner = (_myUsername ?? await AuthService.username())
        ?.trim()
        .toLowerCase();
    if (owner == null || owner.isEmpty) {
      throw StateError('Нет активного аккаунта');
    }
    final targetSid = sid >= _sealedSidOffset ? sid - _sealedSidOffset : sid;
    final payload = {
      'type': 'user_buttons_remove',
      'target_sid': targetSid,
      'owner_username': owner,
    };
    final keys = await getPeerV2Keys(toUsername, forceRefresh: true);
    if (keys != null) {
      await _sendV2Payload(
        toUsername: toUsername,
        keys: keys,
        payload: payload,
      );
    } else {
      final peerPubs = await getPeerDevicePubs(toUsername);
      if (peerPubs.isEmpty) {
        throw StateError('У @$toUsername нет ключей для защищённой отправки');
      }
      final ciphertext = await _crypto.encryptFor(
        theirPubRaw: peerPubs.first,
        plaintext: jsonEncode(payload),
      );
      await _api.chatPost('/send', {
        'to_username': toUsername,
        'ciphertext': ciphertext,
      });
    }
    await _db.updateMessageFlags(toUsername, sid, {'user_buttons_json': null});
    await _refreshMessages(toUsername);
  }

  // ─── Edit / Delete / React / Forward (исходящие) ────────────────────────
  Future<void> editDmMessage({
    required String toUsername,
    required int sid,
    required String newText,
  }) async {
    final keys = await getPeerV2Keys(toUsername, forceRefresh: true);
    if (keys == null) throw StateError('У @$toUsername нет V2-ключей');
    await _sendV2Payload(
      toUsername: toUsername,
      keys: keys,
      payload: {'type': 'edit', 'target_sid': sid, 'new_text': newText},
    );
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
    final keys = await getPeerV2Keys(toUsername, forceRefresh: true);
    if (keys == null) throw StateError('У @$toUsername нет V2-ключей');
    await _sendV2Payload(
      toUsername: toUsername,
      keys: keys,
      payload: {'type': 'delete', 'target_sid': sid},
    );
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
    // Целевое состояние ПО ТЕКУЩЕМУ: если моя реакция уже стоит — снимаем.
    final msgs = await _db.getMessages(toUsername);
    final cur = msgs.firstWhere(
      (x) => x.sid == sid,
      orElse: () => StoredMessage(
        sid: -1,
        peer: toUsername,
        fromMe: false,
        createdAt: '',
      ),
    );
    final already = (cur.reactions?[emoji] ?? const <String>[]).contains(me);
    final willAdd = !already;
    // Оптимистично и ИДЕМПОТЕНТНО ставим/снимаем локально сразу.
    await _setReactionLocal(toUsername, sid, emoji, me, on: willAdd);
    await _refreshMessages(toUsername);
    // Доставка пиру — best-effort. НЕ откатываем локально при сбое: иначе
    // реакция «мигает» и пропадает через секунду. Шлём ЦЕЛЕВОЕ состояние
    // (поле `on`) → эхо/повтор идемпотентны (не переключают обратно).
    try {
      final keys = await getPeerV2Keys(toUsername, forceRefresh: true);
      if (keys == null) throw StateError('У @$toUsername нет V2-ключей');
      await _sendV2Payload(
        toUsername: toUsername,
        keys: keys,
        payload: {
          'type': 'react',
          'target_sid': sid,
          'emoji': emoji,
          'on': willAdd,
        },
      );
    } catch (e) {
      appLog.warn('chat', '[reactDmMessage] доставка реакции не удалась: $e');
    }
  }

  /// Чистое превью файла для списка чатов (БЕЗ квадратных скобок):
  /// «Фото» / «Видео» / «Голосовое сообщение» / «Файл: имя».
  static String _filePreview({
    String? mime,
    String? fileName,
    bool voice = false,
  }) {
    if (voice) return 'Голосовое сообщение';
    final m = mime ?? '';
    if (m.startsWith('image/')) return 'Фото';
    if (m.startsWith('video/')) return 'Видео';
    return (fileName != null && fileName.isNotEmpty)
        ? 'Файл: $fileName'
        : 'Файл';
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
    if (original.filePayload != null) {
      // Перешифровываем blob новым ключом для нового адресата
      final plainBytes = await decryptMediaBlob(original);
      if (plainBytes == null)
        throw Exception('Не удалось расшифровать оригинал');
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
    await sendDmText(toUsername, original.text, forwardedFrom: originalAuthor);
  }

  Map<String, dynamic> _parsePayload(String raw) {
    final t = raw.trimLeft();
    if (t.startsWith('{')) {
      try {
        return Map<String, dynamic>.from(jsonDecode(t) as Map);
      } catch (_) {}
    }
    return {'type': 'msg', 'text': raw};
  }

  Future<void> _refreshMessages(String peer, {int? generation}) async {
    if (generation != null && !_isCurrentSession(generation)) return;
    final list = await _db.getMessages(peer);
    if (generation != null && !_isCurrentSession(generation)) return;
    final notif = _msgsByPeer[peer];
    if (notif != null) notif.value = list;
  }

  Future<void> _refreshDialogs({int? generation}) async {
    if (generation != null && !_isCurrentSession(generation)) return;
    final dialogs = await _db.getDialogs();
    if (generation != null && !_isCurrentSession(generation)) return;
    dialogsNotifier.value = dialogs;
  }

  Future<void> _bumpDialog(
    String username, {
    required String lastText,
    required bool fromMe,
    dynamic lastAt,
    bool incUnread = false,
    int? generation,
  }) async {
    if (generation != null && !_isCurrentSession(generation)) return;
    final existing = await _db.getDialog(username);
    if (generation != null && !_isCurrentSession(generation)) return;
    final dlg = StoredDialog(
      username: username,
      displayName: existing?.displayName ?? username,
      lastText: lastText,
      lastAt: lastAt ?? DateTime.now().toUtc().toIso8601String(),
      lastFromMe: fromMe,
      // Считаем непрочитанные ИЗ сообщений (источник правды) — счётчик-инкремент
      // дрейфовал (двойные доставки/мультидевайс → badge врал). incUnread больше
      // не нужен для подсчёта, оставлен для совместимости вызовов.
      unread: await _db.unreadCount(username),
    );
    await _db.upsertDialog(dlg);
    if (generation != null && !_isCurrentSession(generation)) return;
    dialogsNotifier.value = await _db.getDialogs();
  }

  /// sid первого непрочитанного входящего — граница линии «Новое». Звать в
  /// _init ДО markChatRead (тот пометит всё прочитанным).
  Future<int?> firstUnreadSid(String peer) => _db.firstUnreadSid(peer);

  /// Пометка «прочитано» — когда сообщения пришли, пока чат открыт и юзер у
  /// дна (видит их). Помимо локального флага отправляем /read, иначе отправитель
  /// узнавал о прочтении только после повторного открытия чата.
  Future<void> markPeerSeen(String peer) async {
    final msgs = await _db.getMessages(peer);
    final theirIds = msgs
        .where((m) => !m.fromMe && !m.read)
        .map((m) => m.sid)
        .toList();
    await _db.markAllRead(peer);
    await _db.resetUnread(peer);
    await _refreshMessages(peer);
    dialogsNotifier.value = await _db.getDialogs();
    if (theirIds.isNotEmpty && PrivacySettings.instance.sendReadReceipts) {
      try {
        await _api.chatPost('/read', {'ids': theirIds, 'from_username': peer});
      } catch (e) {
        appLog.warn('chat', '[markPeerSeen] server /read: $e');
      }
    }
  }

  /// Очистить чат ЛОКАЛЬНО: удалить все сообщения + убрать диалог из списка.
  Future<void> clearChat(String peer) async {
    // Ставим tombstone ДО удаления: уже запущенный pending/realtime callback
    // не сможет вернуть старую переписку обратно.
    await _rememberChatDeleted(peer);
    await _clearChatLocal(peer);
  }

  Future<void> _clearChatLocal(String peer) async {
    await _db.deleteMessagesByPeer(peer);
    await _db.deleteDialog(peer);
    _msgsByPeer[peer]?.value = [];
    dialogsNotifier.value = await _db.getDialogs();
  }

  /// Удалить чат в стиле Telegram: локальная копия удаляется всегда, а
  /// серверный буфер чистится best-effort. При [both] сервер также просит
  /// вторую сторону удалить свою локальную копию по WS.
  Future<void> deleteChat(String peer, {required bool both}) async {
    // Локально блокируем старые входящие до сетевого delete: если сервер
    // временно недоступен, pending всё равно будет отброшен по cutoff.
    await _rememberChatDeleted(peer);
    try {
      await _api.chatDelete('/chat/with/${Uri.encodeComponent(peer)}', {
        'both': both,
      });
      appLog.info('chat', 'chat deleted on server: @$peer, both=$both');
    } catch (e) {
      appLog.warn('chat', 'server chat delete failed for @$peer: $e');
    }
    await _clearChatLocal(peer);
  }

  Future<void> markChatRead(String peer) async {
    // Гарантированно подгружаем историю из БД при открытии чата.
    _msgsLoadedFromDb.add(peer);
    await _refreshMessages(peer);
    // Помечаем входящие прочитанными ЛОКАЛЬНО СНАЧАЛА — не завися от сервера.
    // (Был баг: /read на сервер шёл ДО локального read=1; если серверный вызов
    //  падал, catch его глотал и сообщения оставались непрочитанными → бейдж
    //  непрочитанных не сбрасывался при открытии чата.)
    final msgs = await _db.getMessages(peer);
    final theirIds = msgs
        .where((m) => !m.fromMe && !m.read)
        .map((m) => m.sid)
        .toList();
    // Метим ВСЕ входящие прочитанными напрямую в БД (в т.ч. не отрисованные
    // строки — контрол-фреймы/дубликаты/релеи), чтобы бейдж точно обнулился.
    await _db.markAllRead(peer);
    await _db.resetUnread(peer);
    await _refreshMessages(peer);
    dialogsNotifier.value = await _db.getDialogs();
    // Сервер — best-effort (двойная галка отправителю); падение не мешает локалу.
    if (theirIds.isNotEmpty && PrivacySettings.instance.sendReadReceipts) {
      try {
        await _api.chatPost('/read', {'ids': theirIds, 'from_username': peer});
      } catch (e) {
        appLog.warn('chat', '[markChatRead] server /read: $e');
      }
    }
  }

  Future<void> markChatUnread(String peer) async {
    _msgsLoadedFromDb.add(peer);
    await _db.markAllUnread(peer);
    await _refreshMessages(peer);
    dialogsNotifier.value = await _db.getDialogs();
  }
}
