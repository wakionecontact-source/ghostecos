import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import 'api_client.dart';
import 'auth_service.dart';
import 'chat_repo.dart';
import 'crypto_v2.dart';
import 'db_service.dart';
import 'ws_client.dart';
import '../core/local/app_logger.dart';
import '../widgets/profile_banner.dart';

const roomDialogPrefix = 'room:';

String roomDialogKey(RoomSummary room) =>
    '$roomDialogPrefix${room.roomType}:${room.id}';

class RoomSummary {
  final String roomType;
  final int id;
  final String? username;
  final String title;
  final String about;
  final int ownerId;
  final String visibility;
  final String historyMode;
  final String encryptionMode;
  final int keyEpoch;
  final int membersCount;
  final String? role;
  final int? createdAt;
  final int? updatedAt;
  final String? avatarUrl;
  final ProfileBannerConfig? banner;
  final int? lastMessageId;
  final int? lastMessageAt;
  final String? lastMessageSenderUsername;
  final String? lastMessageText;
  final bool lastMessageFromMe;
  final int lastMessageDeliveredCount;
  final int lastMessageReadCount;

  const RoomSummary({
    required this.roomType,
    required this.id,
    required this.username,
    required this.title,
    required this.about,
    required this.ownerId,
    required this.visibility,
    required this.historyMode,
    required this.encryptionMode,
    required this.keyEpoch,
    required this.membersCount,
    required this.role,
    required this.createdAt,
    required this.updatedAt,
    this.avatarUrl,
    this.banner,
    this.lastMessageId,
    this.lastMessageAt,
    this.lastMessageSenderUsername,
    this.lastMessageText,
    this.lastMessageFromMe = false,
    this.lastMessageDeliveredCount = 0,
    this.lastMessageReadCount = 0,
  });

  bool get isChannel => roomType == 'channel';
  bool get isGroup => roomType == 'group';
  bool get isPublic => visibility == 'public';
  bool get isPrivate => visibility == 'private';
  // Public rooms are plaintext by contract. The visibility check also keeps
  // older rows (where encryption_mode could be stale) out of the key path.
  bool get isEncrypted => isPrivate && encryptionMode == 'e2ee_v2';
  bool get canManage => role == 'owner' || role == 'admin';

  factory RoomSummary.fromMap(Map<String, dynamic> map) {
    int asInt(Object? value, [int fallback = 0]) {
      if (value is int) return value;
      if (value is num) return value.toInt();
      return int.tryParse(value?.toString() ?? '') ?? fallback;
    }

    final roomType = map['room_type']?.toString() ?? 'group';
    final rawVisibility = map['visibility']?.toString().toLowerCase();
    final isPublicFlag =
        map['is_public'] == true ||
        map['is_public'] == 1 ||
        map['is_public']?.toString().toLowerCase() == 'true';
    final visibility = rawVisibility == 'public' || isPublicFlag
        ? 'public'
        : 'private';
    final rawLastMessage = map['last_message'];
    final lastMessage = rawLastMessage is Map
        ? Map<String, dynamic>.from(rawLastMessage)
        : const <String, dynamic>{};
    final rawFromMe = lastMessage['from_me'];
    String? lastText;
    final directText = lastMessage['text'] ?? lastMessage['content'];
    if (directText != null && directText.toString().trim().isNotEmpty) {
      lastText = directText.toString().trim();
    } else {
      final payload = lastMessage['payload']?.toString();
      if (payload != null && payload.isNotEmpty) {
        try {
          final decoded = jsonDecode(payload);
          if (decoded is Map && decoded['type'] == 'msg') {
            final text = decoded['text']?.toString().trim() ?? '';
            if (text.isNotEmpty) lastText = text;
          }
        } catch (_) {}
      }
    }
    return RoomSummary(
      roomType: roomType,
      id: asInt(map['id']),
      username: map['username']?.toString(),
      title: map['title']?.toString() ?? '',
      about: map['about']?.toString() ?? '',
      ownerId: asInt(map['owner_id']),
      visibility: visibility,
      historyMode: map['history_mode']?.toString() ?? 'new_only',
      // Public rooms are plaintext even when an older server row still has
      // the old encryption marker.
      encryptionMode: visibility == 'public'
          ? 'none'
          : (map['encryption_mode']?.toString() ?? 'e2ee_v2'),
      keyEpoch: asInt(map['key_epoch'], 1),
      membersCount: asInt(map['members_count']),
      role: map['role']?.toString(),
      createdAt: map['created_at'] == null ? null : asInt(map['created_at']),
      updatedAt: map['updated_at'] == null ? null : asInt(map['updated_at']),
      avatarUrl: map['avatar_url']?.toString(),
      banner: ProfileBannerConfig.fromDynamic(map['banner']),
      lastMessageId: lastMessage['id'] == null
          ? null
          : asInt(lastMessage['id']),
      lastMessageAt: lastMessage['created_at'] == null
          ? null
          : asInt(lastMessage['created_at']),
      lastMessageSenderUsername: lastMessage['sender_username']?.toString(),
      lastMessageText: lastText,
      lastMessageFromMe:
          rawFromMe == true || rawFromMe == 1 || rawFromMe?.toString() == '1',
      lastMessageDeliveredCount: asInt(lastMessage['delivered_count']),
      lastMessageReadCount: asInt(lastMessage['read_count']),
    );
  }
}

class RoomLimits {
  static const channelsPerUser = 10;
  static const groupsPerUser = 15;

  static int limitFor(String roomType) =>
      roomType == 'channel' ? channelsPerUser : groupsPerUser;

  static int ownedCount(
    Iterable<RoomSummary> rooms, {
    required String roomType,
  }) => rooms
      .where((room) => room.roomType == roomType && room.role == 'owner')
      .length;

  static bool canCreate(
    Iterable<RoomSummary> rooms, {
    required String roomType,
  }) => ownedCount(rooms, roomType: roomType) < limitFor(roomType);
}

class RoomLimitExceededException implements Exception {
  final String roomType;
  final int limit;

  const RoomLimitExceededException(this.roomType, this.limit);

  @override
  String toString() => roomType == 'channel'
      ? 'Достигнут лимит: не более $limit каналов на пользователя'
      : 'Достигнут лимит: не более $limit групп на пользователя';
}

class RoomMessage {
  final int id;
  final String senderUsername;
  final String senderDisplayName;
  final String? senderAvatarUrl;
  final String text;
  final Map<String, dynamic>? attachment;
  final String? forwardedFrom;
  final int createdAt;
  final bool fromMe;
  final int deliveredCount;
  final int readCount;
  final bool pending;
  final bool sendFailed;

  const RoomMessage({
    required this.id,
    required this.senderUsername,
    required this.senderDisplayName,
    required this.senderAvatarUrl,
    required this.text,
    this.attachment,
    required this.forwardedFrom,
    required this.createdAt,
    this.fromMe = false,
    this.deliveredCount = 0,
    this.readCount = 0,
    this.pending = false,
    this.sendFailed = false,
  });
}

class RoomPinnedMessage {
  final int messageId;
  final String text;
  final String senderUsername;
  final String senderDisplayName;
  final String? senderAvatarUrl;
  final int createdAt;
  final int pinnedAt;
  final bool notify;

  const RoomPinnedMessage({
    required this.messageId,
    required this.text,
    required this.senderUsername,
    required this.senderDisplayName,
    required this.senderAvatarUrl,
    required this.createdAt,
    required this.pinnedAt,
    required this.notify,
  });
}

class RoomDialogMeta {
  final int? timestampSeconds;
  final bool fromMe;
  final int deliveredCount;
  final int readCount;

  const RoomDialogMeta({
    required this.timestampSeconds,
    required this.fromMe,
    required this.deliveredCount,
    required this.readCount,
  });
}

RoomDialogMeta roomDialogMetaFor(RoomSummary room, RoomMessage? cached) {
  final cachedIsNewer =
      cached != null &&
      (room.lastMessageId == null || cached.id > room.lastMessageId!);
  return RoomDialogMeta(
    timestampSeconds: cachedIsNewer
        ? cached.createdAt
        : (room.lastMessageAt ?? room.updatedAt ?? room.createdAt),
    fromMe: cachedIsNewer ? cached.fromMe : room.lastMessageFromMe,
    deliveredCount: cachedIsNewer
        ? cached.deliveredCount
        : room.lastMessageDeliveredCount,
    readCount: cachedIsNewer ? cached.readCount : room.lastMessageReadCount,
  );
}

enum RoomReceiptState { saved, delivered, read }

RoomReceiptState roomReceiptState({
  required int deliveredCount,
  required int readCount,
}) => readCount > 0
    ? RoomReceiptState.read
    : deliveredCount > 0
    ? RoomReceiptState.delivered
    : RoomReceiptState.saved;

class RoomMessagesPage {
  final List<RoomMessage> messages;
  final int nextAfterId;
  final List<int> receivedMessageIds;
  final bool hasMore;

  const RoomMessagesPage({
    required this.messages,
    required this.nextAfterId,
    required this.receivedMessageIds,
    required this.hasMore,
  });
}

class RoomPreview {
  final RoomSummary room;
  final List<RoomMessage> messages;
  final bool isMember;
  final bool requestJoin;
  final String? inviteToken;
  final int? expiresAt;

  const RoomPreview({
    required this.room,
    required this.messages,
    required this.isMember,
    this.requestJoin = false,
    this.inviteToken,
    this.expiresAt,
  });

  factory RoomPreview.fromMap(Map<String, dynamic> map) {
    final roomMap = map['room'] is Map
        ? Map<String, dynamic>.from(map['room'] as Map)
        : map;
    final room = RoomSummary.fromMap(roomMap);
    final rawMessages = map['messages'] is List
        ? map['messages'] as List
        : const [];
    final messages = <RoomMessage>[];
    for (final raw in rawMessages.whereType<Map>()) {
      final item = Map<String, dynamic>.from(raw);
      var text = '';
      final payload = item['payload']?.toString();
      if (payload != null && payload.isNotEmpty) {
        try {
          final decoded = jsonDecode(payload);
          if (decoded is Map && decoded['type'] == 'msg') {
            text = decoded['text']?.toString() ?? '';
          }
        } catch (_) {}
      }
      if (text.isEmpty) continue;
      messages.add(
        RoomMessage(
          id: _roomMapInt(item['id']),
          senderUsername: item['sender_username']?.toString() ?? '',
          senderDisplayName: item['sender_display_name']?.toString() ?? '',
          senderAvatarUrl: item['sender_avatar_url']?.toString(),
          text: text,
          forwardedFrom: null,
          createdAt: _roomMapInt(item['created_at']),
        ),
      );
    }
    return RoomPreview(
      room: room,
      messages: messages,
      isMember: map['is_member'] == true || map['is_member'] == 1,
      requestJoin: map['request_join'] == true || map['request_join'] == 1,
      inviteToken: map['token']?.toString(),
      expiresAt: _roomMapIntNullable(map['expires_at']),
    );
  }
}

int _roomMapInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '') ?? 0;
}

int? _roomMapIntNullable(Object? value) {
  if (value == null) return null;
  final parsed = _roomMapInt(value);
  return parsed == 0 ? null : parsed;
}

class RoomSearchResult {
  final RoomSummary room;
  final bool isMember;

  const RoomSearchResult({required this.room, required this.isMember});
}

class RoomInviteLink {
  final String link;
  final String? token;
  final bool permanent;
  final int? expiresAt;
  final int? maxUses;
  final int uses;
  final bool requestJoin;

  const RoomInviteLink({
    required this.link,
    required this.token,
    required this.permanent,
    required this.expiresAt,
    required this.maxUses,
    required this.uses,
    required this.requestJoin,
  });

  factory RoomInviteLink.fromMap(Map<String, dynamic> map) {
    int? asInt(Object? value) {
      if (value is int) return value;
      if (value is num) return value.toInt();
      return int.tryParse(value?.toString() ?? '');
    }

    final token = map['token']?.toString();
    return RoomInviteLink(
      link:
          map['link']?.toString() ??
          (token == null || token.isEmpty ? '' : '/invite/$token'),
      token: token,
      permanent: map['permanent'] == true,
      expiresAt: asInt(map['expires_at']),
      maxUses: asInt(map['max_uses']),
      uses: asInt(map['uses']) ?? 0,
      requestJoin: map['request_join'] == true || map['request_join'] == 1,
    );
  }
}

class RoomForwardTarget {
  final String? username;
  final RoomSummary? room;

  const RoomForwardTarget._({this.username, this.room});

  const RoomForwardTarget.user(String value) : this._(username: value);

  const RoomForwardTarget.room(RoomSummary value) : this._(room: value);

  bool get isRoom => room != null;
  String get label => isRoom ? room!.title : '@$username';
}

class RoomEvent {
  final String roomType;
  final int roomId;
  final int? messageId;

  const RoomEvent({
    required this.roomType,
    required this.roomId,
    this.messageId,
  });

  factory RoomEvent.fromMap(Map<String, dynamic> map) {
    final rawId = map['room_id'];
    final roomId = rawId is int
        ? rawId
        : rawId is num
        ? rawId.toInt()
        : int.tryParse(rawId?.toString() ?? '') ?? 0;
    final rawMessageId = map['message_id'];
    final messageId = rawMessageId is int
        ? rawMessageId
        : rawMessageId is num
        ? rawMessageId.toInt()
        : int.tryParse(rawMessageId?.toString() ?? '');
    return RoomEvent(
      roomType: map['room_type']?.toString() ?? '',
      roomId: roomId,
      messageId: messageId,
    );
  }
}

class RoomService {
  RoomService._() {
    // Rooms have a separate transport/storage contract from DM messages.
    WsClient.instance.on('room.v2.new', _onRoomEvent);
    WsClient.instance.on('room.v2.pin', _onRoomPinEvent);
    WsClient.instance.on('room.v2.receipt', _onRoomReceipt);
    WsClient.instance.onConnectionChange.listen((connected) {
      if (connected) {
        unawaited(_drainRoomOutbox());
        unawaited(syncAllRooms());
      }
    });
  }
  static final RoomService instance = RoomService._();

  final ApiClient _api = ApiClient();
  final ValueNotifier<List<RoomSummary>> rooms = ValueNotifier(const []);
  final ValueNotifier<int> activityRevision = ValueNotifier(0);
  final Map<String, DateTime> _lastActivity = {};
  final Map<String, RoomMessage> _lastMessages = {};
  final Map<String, Future<void>> _roomSyncs = {};
  final StreamController<RoomEvent> _roomEvents =
      StreamController<RoomEvent>.broadcast();
  Future<void>? _dbInitFuture;
  Future<void>? _syncAllFuture;
  Future<void>? _outboxDrain;
  Timer? _outboxRetryTimer;
  String? _dbInitUser;

  Stream<RoomEvent> get onRoomEvent => _roomEvents.stream;

  RoomMessage? lastMessageFor(RoomSummary room) =>
      _lastMessages[roomDialogKey(room)];

  Future<String?> _ensureAccountDatabase() async {
    final username = (await AuthService.username())?.trim();
    if (username == null || username.isEmpty) return null;
    if (_dbInitUser != username) {
      _dbInitUser = username;
      _lastActivity.clear();
      _lastMessages.clear();
      rooms.value = const [];
      activityRevision.value++;
      final previous = _dbInitFuture;
      final init = (previous ?? Future<void>.value()).then(
        (_) => DbService.instance.init(username),
      );
      _dbInitFuture = init;
    }
    await _dbInitFuture;
    return _dbInitUser == username ? username : null;
  }

  Future<void> startSessionSync() => syncAllRooms();

  Future<void> syncAllRooms() async {
    final existing = _syncAllFuture;
    if (existing != null) return existing;
    final future = _syncAllRoomsImpl();
    _syncAllFuture = future;
    try {
      await future;
    } finally {
      if (identical(_syncAllFuture, future)) _syncAllFuture = null;
    }
  }

  Future<void> _syncAllRoomsImpl() async {
    final username = await _ensureAccountDatabase();
    if (username == null) return;
    final loaded = await loadMy();
    if (_dbInitUser != username) return;
    _outboxRetryTimer ??= Timer.periodic(const Duration(seconds: 5), (_) {
      unawaited(_drainRoomOutbox());
    });
    unawaited(_drainRoomOutbox());
    // Bound concurrent history downloads while still bringing every joined
    // channel/group up to date after login or a network restoration.
    for (var offset = 0; offset < loaded.length; offset += 3) {
      if (_dbInitUser != username) return;
      final batch = loaded.skip(offset).take(3);
      await Future.wait(
        batch.map((room) async {
          try {
            await syncRoomMessages(room);
          } catch (error) {
            appLog.warn(
              'room',
              'history sync failed ${room.roomType}/${room.id}: $error',
            );
          }
        }),
      );
    }
  }

  Future<List<RoomMessage>> loadCachedMessages(RoomSummary room) async {
    final username = await _ensureAccountDatabase();
    if (username == null) return const [];
    final rows = await DbService.instance.getRoomMessages(roomDialogKey(room));
    if (_dbInitUser != username) return const [];
    final messages = rows.map(_roomMessageFromMap).toList(growable: false);
    if (messages.isNotEmpty) _lastMessages[roomDialogKey(room)] = messages.last;
    return messages;
  }

  Future<void> syncRoomMessages(RoomSummary room) async {
    final key = roomDialogKey(room);
    final existing = _roomSyncs[key];
    if (existing != null) return existing;
    final future = _syncRoomMessagesImpl(room);
    _roomSyncs[key] = future;
    try {
      await future;
    } finally {
      if (identical(_roomSyncs[key], future)) _roomSyncs.remove(key);
    }
  }

  Future<void> _syncRoomMessagesImpl(RoomSummary room) async {
    final username = await _ensureAccountDatabase();
    if (username == null) return;
    final key = roomDialogKey(room);
    // Hydrate the last-message indicator from the local cache before fetching
    // newer pages. This keeps private-room time/receipts visible across restarts
    // even when an older server omits the summary fields.
    await loadCachedMessages(room);
    if (_dbInitUser != username) return;
    await _flushPendingRoomDeliveries(room, key, username);
    var cursor = await DbService.instance.lastRoomMessageId(key);
    while (_dbInitUser == username) {
      final page = await _loadMessagePage(
        room,
        username.toLowerCase(),
        afterId: cursor,
      );
      if (page.nextAfterId <= cursor && page.messages.isEmpty) break;
      if (_dbInitUser != username) return;
      await DbService.instance.upsertRoomMessages(
        key,
        page.messages.map(_roomMessageToMap).toList(growable: false),
      );
      if (page.messages.isNotEmpty) {
        _lastMessages[key] = page.messages.last;
        for (final message in page.messages) {
          _markActivity(room, message.createdAt);
        }
        activityRevision.value++;
      }
      if (page.receivedMessageIds.isNotEmpty) {
        try {
          await _sendRoomReceipts(
            room,
            page.receivedMessageIds,
            status: 'delivered',
          );
          await DbService.instance.markRoomDeliveryReceiptsSent(
            key,
            page.receivedMessageIds,
          );
        } catch (error) {
          appLog.warn('room', 'delivery receipt retry queued: $error');
        }
      }
      if (!page.hasMore || page.nextAfterId <= cursor) break;
      cursor = page.nextAfterId;
    }
    if (_dbInitUser == username) {
      await _flushPendingRoomDeliveries(room, key, username);
    }
  }

  Future<void> _flushPendingRoomDeliveries(
    RoomSummary room,
    String roomKey,
    String username,
  ) async {
    final ids = await DbService.instance.pendingRoomDeliveryReceiptIds(roomKey);
    for (var offset = 0; offset < ids.length; offset += 200) {
      if (_dbInitUser != username) return;
      final batch = ids.skip(offset).take(200).toList(growable: false);
      try {
        await _sendRoomReceipts(room, batch, status: 'delivered');
        await DbService.instance.markRoomDeliveryReceiptsSent(roomKey, batch);
      } catch (error) {
        appLog.warn('room', 'pending delivery receipt failed: $error');
        return;
      }
    }
  }

  Future<void> markRoomMessagesRead(
    RoomSummary room,
    Iterable<int> messageIds,
  ) async {
    final ids = messageIds.where((id) => id > 0).toSet().toList();
    if (ids.isEmpty) return;
    await _sendRoomReceipts(room, ids, status: 'read');
  }

  Future<void> _sendRoomReceipts(
    RoomSummary room,
    List<int> messageIds, {
    required String status,
  }) async {
    for (var offset = 0; offset < messageIds.length; offset += 200) {
      final ids = messageIds.skip(offset).take(200).toList(growable: false);
      await _api.chatPost('/v2/rooms/${room.roomType}/${room.id}/receipts', {
        'message_ids': ids,
        'status': status,
      });
    }
  }

  void _onRoomReceipt(Map<String, dynamic> data) {
    final type = data['room_type']?.toString();
    final id = _asInt(data['room_id']);
    if ((type != 'channel' && type != 'group') || id <= 0) return;
    unawaited(loadMy().catchError((_) => const <RoomSummary>[]));
  }

  void _onRoomEvent(Map<String, dynamic> data) {
    final event = RoomEvent.fromMap(data);
    if ((event.roomType != 'channel' && event.roomType != 'group') ||
        event.roomId <= 0) {
      return;
    }
    final known = rooms.value.where(
      (room) => room.roomType == event.roomType && room.id == event.roomId,
    );
    if (known.isNotEmpty) {
      _markActivity(known.first, DateTime.now().millisecondsSinceEpoch ~/ 1000);
    }
    _roomEvents.add(event);
    // Keep the unified chat list fresh even while the room is closed.
    if (known.isNotEmpty) unawaited(syncRoomMessages(known.first));
    unawaited(loadMy().catchError((_) => const <RoomSummary>[]));
  }

  void _onRoomPinEvent(Map<String, dynamic> data) {
    final event = RoomEvent.fromMap(data);
    if ((event.roomType != 'channel' && event.roomType != 'group') ||
        event.roomId <= 0) {
      return;
    }
    _roomEvents.add(event);
  }

  DateTime lastActivityFor(RoomSummary room) {
    return _lastActivity[roomDialogKey(room)] ??
        DateTime.fromMillisecondsSinceEpoch((room.updatedAt ?? 0) * 1000);
  }

  void _markActivity(RoomSummary room, int seconds) {
    if (seconds <= 0) return;
    final next = DateTime.fromMillisecondsSinceEpoch(seconds * 1000);
    final key = roomDialogKey(room);
    final previous = _lastActivity[key];
    if (previous != null && !next.isAfter(previous)) return;
    _lastActivity[key] = next;
    activityRevision.value++;
  }

  Future<List<RoomSummary>> loadMy() async {
    final username = await _ensureAccountDatabase();
    if (username == null) {
      rooms.value = const [];
      return const [];
    }
    final raw = await _api.chatGet('/v2/rooms/my');
    if (_dbInitUser != username) return rooms.value;
    final map = Map<String, dynamic>.from(raw as Map);
    final values = map['rooms'];
    final loaded = values is List
        ? values
              .whereType<Map>()
              .map(
                (item) => RoomSummary.fromMap(Map<String, dynamic>.from(item)),
              )
              .toList(growable: false)
        : const <RoomSummary>[];
    rooms.value = loaded;
    for (final room in loaded) {
      if (room.lastMessageAt != null) {
        _markActivity(room, room.lastMessageAt!);
      }
    }
    activityRevision.value++;
    return loaded;
  }

  int get ownedChannelCount =>
      RoomLimits.ownedCount(rooms.value, roomType: 'channel');

  int get ownedGroupCount =>
      RoomLimits.ownedCount(rooms.value, roomType: 'group');

  Future<dynamic> _createRoomWithLimit({
    required String roomType,
    required String path,
    required Map<String, dynamic> body,
  }) async {
    final limit = RoomLimits.limitFor(roomType);
    if (!RoomLimits.canCreate(rooms.value, roomType: roomType)) {
      throw RoomLimitExceededException(roomType, limit);
    }
    try {
      return await _api.chatPost(path, body);
    } on DioException catch (error) {
      final response = error.response?.data;
      final detail = response is Map ? response['detail'] : null;
      final code = detail is Map ? detail['code']?.toString() : null;
      if (code == '${roomType}_limit_reached') {
        throw RoomLimitExceededException(roomType, limit);
      }
      rethrow;
    }
  }

  Future<RoomSummary> createChannel({
    required String username,
    required String title,
    String about = '',
    String visibility = 'private',
    String historyMode = 'new_only',
  }) async {
    final raw = await _createRoomWithLimit(
      roomType: 'channel',
      path: '/v2/channels',
      body: {
        'username': username,
        'title': title,
        'about': about,
        'visibility': visibility,
        'history_mode': historyMode,
      },
    );
    final room = RoomSummary.fromMap({
      ...Map<String, dynamic>.from(raw as Map),
      'room_type': 'channel',
    });
    await loadMy();
    return room;
  }

  Future<RoomSummary> createGroup({
    required String username,
    required String title,
    String about = '',
    String visibility = 'private',
    String historyMode = 'new_only',
  }) async {
    final raw = await _createRoomWithLimit(
      roomType: 'group',
      path: '/v2/rooms/groups',
      body: {
        'username': username,
        'title': title,
        'about': about,
        'visibility': visibility,
        'history_mode': historyMode,
      },
    );
    final room = RoomSummary.fromMap(Map<String, dynamic>.from(raw as Map));
    await loadMy();
    return room;
  }

  Future<RoomSummary> joinChannel(String username) async {
    final raw = await _api.chatPost('/v2/channels/$username/join');
    final room = RoomSummary.fromMap({
      ...Map<String, dynamic>.from(raw as Map),
      'room_type': 'channel',
    });
    await loadMy();
    return room;
  }

  Future<RoomSummary> joinGroup(String username) async {
    final normalized = username.trim().replaceFirst('@', '').toLowerCase();
    final numericId = int.tryParse(normalized);
    final path = numericId != null
        ? '/v2/rooms/groups/$numericId/join'
        : '/v2/rooms/groups/handle/${Uri.encodeComponent(normalized)}/join';
    final raw = await _api.chatPost(path);
    final room = RoomSummary.fromMap(Map<String, dynamic>.from(raw as Map));
    await loadMy();
    return room;
  }

  Future<RoomSummary> loadRoom(RoomSummary room) async {
    final path = room.isChannel
        ? '/v2/channels/${Uri.encodeComponent(room.username ?? '')}'
        : '/v2/rooms/groups/${room.id}';
    final raw = await _api.chatGet(path);
    final map = Map<String, dynamic>.from(raw as Map);
    return RoomSummary.fromMap({...map, 'room_type': room.roomType});
  }

  Future<RoomPreview> loadPublicPreview(String username) async {
    final raw = await _api.chatGet(
      '/v2/rooms/public/${Uri.encodeComponent(username.trim().replaceFirst('@', ''))}',
      {'limit': 30},
    );
    return RoomPreview.fromMap(Map<String, dynamic>.from(raw as Map));
  }

  Future<RoomPreview> loadInvitePreview(String token) async {
    final raw = await _api.chatGet(
      '/v2/rooms/invite-links/preview/${Uri.encodeComponent(token.trim())}',
    );
    return RoomPreview.fromMap(Map<String, dynamic>.from(raw as Map));
  }

  Future<List<RoomSearchResult>> searchRooms(
    String query, {
    String? roomType,
  }) async {
    final normalized = query.trim();
    if (normalized.isEmpty) return const [];
    final raw = await _api.chatGet('/v2/rooms/search', {
      'q': normalized,
      'room_type': ?roomType,
    });
    final values = raw is Map ? raw['rooms'] : null;
    if (values is! List) return const [];
    return values
        .whereType<Map>()
        .map((item) {
          final map = Map<String, dynamic>.from(item);
          return RoomSearchResult(
            room: RoomSummary.fromMap(map),
            isMember: map['is_member'] == true || map['is_member'] == 1,
          );
        })
        .toList(growable: false);
  }

  Future<Map<String, dynamic>> requestJoin(RoomSummary room) async {
    final raw = await _api.chatPost(
      '/v2/rooms/${room.roomType}/${room.id}/request-join',
    );
    await loadMy();
    return Map<String, dynamic>.from(raw as Map);
  }

  Future<RoomInviteLink> createInviteLink(
    RoomSummary room, {
    int? expiresHours,
    int? maxUses,
    bool requestJoin = false,
    List<String> usernames = const [],
  }) async {
    final raw = await _api
        .chatPost('/v2/rooms/${room.roomType}/${room.id}/invite-links', {
          'expires_hours': ?expiresHours,
          'max_uses': ?maxUses,
          'request_join': requestJoin,
          'usernames': usernames,
        });
    return RoomInviteLink.fromMap(Map<String, dynamic>.from(raw as Map));
  }

  Future<List<RoomInviteLink>> listInviteLinks(RoomSummary room) async {
    final raw = await _api.chatGet(
      '/v2/rooms/${room.roomType}/${room.id}/invite-links',
    );
    final values = raw is Map ? raw['links'] : null;
    if (values is! List) return const [];
    return values
        .whereType<Map>()
        .map((item) => RoomInviteLink.fromMap(Map<String, dynamic>.from(item)))
        .where((link) => link.link.isNotEmpty)
        .toList(growable: false);
  }

  Future<void> revokeInviteLinks(RoomSummary room) async {
    await _api.chatDelete('/v2/rooms/${room.roomType}/${room.id}/invite-links');
  }

  Future<Map<String, dynamic>> redeemInvite(String token) async {
    final raw = await _api.chatPost('/v2/rooms/invite-links/redeem', {
      'token': token.trim(),
    });
    await loadMy();
    return Map<String, dynamic>.from(raw as Map);
  }

  Future<RoomSummary> updateRoom(
    RoomSummary room, {
    String? username,
    String? title,
    String? about,
    String? historyMode,
    String? visibility,
    Map<String, dynamic>? banner,
    bool clearBanner = false,
  }) async {
    final body = <String, dynamic>{
      if (room.isChannel || room.isGroup) 'username': ?username,
      'title': ?title,
      'about': ?about,
      'history_mode': ?historyMode,
      'visibility': ?visibility,
      'banner': ?banner,
      if (clearBanner) 'banner_clear': true,
    };
    final path = room.isChannel
        ? '/v2/channels/id/${room.id}'
        : '/v2/rooms/groups/${room.id}';
    final raw = await _api.chatPatch(path, body);
    final updated = RoomSummary.fromMap({
      ...Map<String, dynamic>.from(raw as Map),
      'room_type': room.roomType,
    });
    await loadMy();
    return updated;
  }

  /// Changes the room kind while keeping the public identity, members,
  /// messages and invite links on the server. The response is the new room
  /// entity because channel and group ids are stored in separate tables.
  Future<RoomSummary> convertRoom(RoomSummary room, String targetType) async {
    final normalized = targetType.trim().toLowerCase();
    if (normalized != 'channel' && normalized != 'group') {
      throw const FormatException('Неизвестный тип комнаты');
    }
    if (normalized == room.roomType) return room;
    final raw = await _api.chatPost(
      '/v2/rooms/${room.roomType}/${room.id}/convert',
      {'room_type': normalized},
    );
    final updated = RoomSummary.fromMap(Map<String, dynamic>.from(raw as Map));
    await loadMy();
    return updated;
  }

  Future<RoomSummary> uploadRoomAvatar(
    RoomSummary room, {
    required List<int> bytes,
    required String filename,
    String? mime,
  }) async {
    final raw = await _api.uploadChatFile(
      path: '/v2/rooms/${room.roomType}/${room.id}/avatar',
      bytes: bytes,
      filename: filename,
      mime: mime,
    );
    final updated = RoomSummary.fromMap({...raw, 'room_type': room.roomType});
    await loadMy();
    return updated;
  }

  Future<Map<String, dynamic>> addGroupMember(
    int groupId,
    String username,
  ) async {
    final raw = await _api.chatPost('/v2/rooms/groups/$groupId/members', {
      'username': username.trim().replaceFirst('@', ''),
    });
    await loadMy();
    return Map<String, dynamic>.from(raw as Map);
  }

  Future<Map<String, dynamic>> addMember(
    RoomSummary room,
    String username,
  ) async {
    final normalized = username.trim().replaceFirst('@', '').toLowerCase();
    if (normalized.length < 3) {
      throw const FormatException('Username должен быть не короче 3 символов');
    }
    final path = room.isChannel
        ? '/v2/rooms/channels/${room.id}/members'
        : '/v2/rooms/groups/${room.id}/members';
    final raw = await _api.chatPost(path, {'username': normalized});
    await loadMy();
    return Map<String, dynamic>.from(raw as Map);
  }

  /// Loads the members visible to the current account. The server applies the
  /// room's privacy rules; the profile screen only renders the returned rows.
  Future<List<Map<String, dynamic>>> loadMembers(RoomSummary room) {
    return _loadMembers(room);
  }

  /// Pending admission requests are visible only to room administrators and
  /// the owner. Keep the raw user fields here so the profile sheet can remain
  /// lightweight and can later add moderation actions without another API
  /// round-trip.
  Future<List<Map<String, dynamic>>> loadJoinRequests(RoomSummary room) async {
    final raw = await _api.chatGet(
      '/v2/rooms/${room.roomType}/${room.id}/join-requests',
    );
    final values = raw is Map ? raw['requests'] : null;
    if (values is! List) return const [];
    return values
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList(growable: false);
  }

  Future<Map<String, dynamic>> reviewJoinRequest(
    RoomSummary room,
    int requestId, {
    required bool accept,
  }) async {
    final raw = await _api.chatPost(
      '/v2/rooms/${room.roomType}/${room.id}/join-requests/$requestId',
      {'action': accept ? 'accept' : 'reject'},
    );
    await loadMy();
    return Map<String, dynamic>.from(raw as Map);
  }

  Future<List<RoomPinnedMessage>> loadPinnedMessages(RoomSummary room) async {
    final raw = await _api.chatGet(
      '/v2/rooms/${room.roomType}/${room.id}/pins',
    );
    final values = raw is Map ? raw['pins'] : null;
    if (values is! List) return const [];
    return values
        .whereType<Map>()
        .map((item) {
          final map = Map<String, dynamic>.from(item);
          var text = '';
          final payload = map['payload']?.toString();
          if (payload != null && payload.isNotEmpty) {
            try {
              final decoded = jsonDecode(payload);
              if (decoded is Map && decoded['type'] == 'msg') {
                text = decoded['text']?.toString() ?? '';
              }
            } catch (_) {}
          }
          return RoomPinnedMessage(
            messageId: _asInt(map['message_id']),
            text: text,
            senderUsername: map['sender_username']?.toString() ?? '',
            senderDisplayName: map['sender_display_name']?.toString() ?? '',
            senderAvatarUrl: _nonEmpty(map['sender_avatar_url']),
            createdAt: _asInt(map['created_at']),
            pinnedAt: _asInt(map['pinned_at']),
            notify: map['notify'] == true || map['notify'] == 1,
          );
        })
        .toList(growable: false);
  }

  Future<void> pinMessage(
    RoomSummary room,
    int messageId, {
    bool notify = true,
  }) async {
    await _api.chatPost('/v2/rooms/${room.roomType}/${room.id}/pins', {
      'message_id': messageId,
      'notify': notify,
    });
  }

  Future<void> unpinMessage(RoomSummary room, int messageId) async {
    await _api.chatDelete(
      '/v2/rooms/${room.roomType}/${room.id}/pins/$messageId',
    );
  }

  Future<List<RoomMessage>> loadMessages(
    RoomSummary room, {
    int afterId = 0,
  }) async {
    final username = (await AuthService.username())?.toLowerCase() ?? '';
    return (await _loadMessagePage(room, username, afterId: afterId)).messages;
  }

  Future<RoomMessagesPage> _loadMessagePage(
    RoomSummary room,
    String username, {
    int afterId = 0,
    int limit = 100,
  }) async {
    final raw = await _api.chatGet(
      '/v2/rooms/${room.roomType}/${room.id}/messages',
      {'after_id': afterId, 'limit': limit},
    );
    final values =
        (Map<String, dynamic>.from(raw as Map)['messages'] as List?) ??
        const [];
    final result = <RoomMessage>[];
    final receivedIds = <int>[];
    var nextAfterId = afterId;
    for (final value in values.whereType<Map>()) {
      final map = Map<String, dynamic>.from(value);
      final id = _asInt(map['id']);
      if (id > nextAfterId) nextAfterId = id;
      final senderUsername = _nonEmpty(map['sender_username']) ?? '';
      final fromMe =
          username.isNotEmpty && senderUsername.toLowerCase() == username;
      if (id > 0 && !fromMe && senderUsername.isNotEmpty) {
        receivedIds.add(id);
      }
      String? payload = map['payload']?.toString();
      if (payload == null && map['envelope'] != null) {
        try {
          final clear = await CryptoV2.instance.decryptForMe(
            map['envelope'].toString(),
          );
          if (clear == null) continue;
          payload = utf8.decode(clear, allowMalformed: false);
        } catch (_) {
          // A malformed or undecryptable envelope must not block later pages.
          continue;
        }
      }
      if (payload == null) continue;
      try {
        final decoded = jsonDecode(payload);
        if (decoded is! Map || decoded['type'] != 'msg') continue;
        final text = decoded['text']?.toString() ?? '';
        final attachment = decoded['attachment'] is Map
            ? Map<String, dynamic>.from(decoded['attachment'] as Map)
            : null;
        if (text.isEmpty && attachment == null) continue;
        result.add(
          RoomMessage(
            id: id,
            senderUsername: senderUsername,
            senderDisplayName: map['sender_display_name']?.toString() ?? '',
            senderAvatarUrl:
                _nonEmpty(map['sender_avatar_url']) ??
                _nonEmpty(map['avatar_url']) ??
                ChatRepo.instance.getPeerAvatarCached(senderUsername),
            text: text,
            attachment: attachment,
            forwardedFrom: decoded['forwarded_from']?.toString(),
            createdAt: _asInt(map['created_at']),
            fromMe: fromMe,
            deliveredCount: _asInt(map['delivered_count']),
            readCount: _asInt(map['read_count']),
          ),
        );
      } on FormatException {
        // Do not render malformed server data as a chat message.
      }
    }

    // Group messages always use the author's profile avatar. If an older
    // response did not include sender_avatar_url, warm the user cache from
    // /keys/{username}. Keep this bounded so a large group cannot trigger a
    // request storm while opening the chat.
    if (room.isGroup) {
      final missing = <String>{
        for (final message in result)
          if (message.senderAvatarUrl == null &&
              message.senderUsername.trim().isNotEmpty)
            message.senderUsername.trim().toLowerCase(),
      }.take(20).toList();
      await Future.wait(
        missing.map((username) async {
          try {
            await ChatRepo.instance.warmPeerInfo(username);
          } catch (_) {
            // An avatar lookup must never hide or delay the message itself.
          }
        }),
      );
      for (var i = 0; i < result.length; i++) {
        final message = result[i];
        if (message.senderAvatarUrl != null) continue;
        final avatar = ChatRepo.instance.getPeerAvatarCached(
          message.senderUsername,
        );
        if (avatar == null) continue;
        result[i] = RoomMessage(
          id: message.id,
          senderUsername: message.senderUsername,
          senderDisplayName: message.senderDisplayName,
          senderAvatarUrl: avatar,
          text: message.text,
          attachment: message.attachment,
          forwardedFrom: message.forwardedFrom,
          createdAt: message.createdAt,
          fromMe: message.fromMe,
          deliveredCount: message.deliveredCount,
          readCount: message.readCount,
          pending: message.pending,
          sendFailed: message.sendFailed,
        );
      }
    }
    return RoomMessagesPage(
      messages: result,
      nextAfterId: nextAfterId,
      receivedMessageIds: receivedIds.toSet().toList(growable: false),
      hasMore: values.length >= limit,
    );
  }

  Map<String, dynamic> _roomMessageToMap(RoomMessage message) => {
    'message_id': message.id,
    'sender_username': message.senderUsername,
    'sender_display_name': message.senderDisplayName,
    'sender_avatar_url': message.senderAvatarUrl,
    'text': message.text,
    'attachment_json': message.attachment == null
        ? null
        : jsonEncode(message.attachment),
    'forwarded_from': message.forwardedFrom,
    'created_at': message.createdAt,
    'from_me': message.fromMe ? 1 : 0,
    'delivered_count': message.deliveredCount,
    'read_count': message.readCount,
    'delivered_ack_sent': message.fromMe ? 1 : 0,
    'pending': message.pending ? 1 : 0,
    'send_failed': message.sendFailed ? 1 : 0,
  };

  RoomMessage _roomMessageFromMap(Map<String, Object?> map) => RoomMessage(
    id: _asInt(map['message_id']),
    senderUsername: map['sender_username']?.toString() ?? '',
    senderDisplayName: map['sender_display_name']?.toString() ?? '',
    senderAvatarUrl: _nonEmpty(map['sender_avatar_url']),
    text: map['text']?.toString() ?? '',
    attachment: _decodeAttachment(map['attachment_json']),
    forwardedFrom: _nonEmpty(map['forwarded_from']),
    createdAt: _asInt(map['created_at']),
    fromMe: _asInt(map['from_me']) == 1,
    deliveredCount: _asInt(map['delivered_count']),
    readCount: _asInt(map['read_count']),
    pending: _asInt(map['pending']) == 1,
    sendFailed: _asInt(map['send_failed']) == 1,
  );

  Future<void> _rememberSentMessage(
    RoomSummary room,
    Map<String, dynamic> response,
    String text, {
    required String senderUsername,
    int? temporaryId,
    String? forwardedFrom,
    Map<String, dynamic>? attachment,
  }) async {
    final username = await _ensureAccountDatabase();
    final id = _asInt(response['message_id']);
    if (username == null ||
        senderUsername.isEmpty ||
        username.toLowerCase() != senderUsername ||
        id <= 0) {
      return;
    }
    final message = RoomMessage(
      id: id,
      senderUsername: senderUsername,
      senderDisplayName: senderUsername,
      senderAvatarUrl: ChatRepo.instance.getPeerAvatarCached(senderUsername),
      text: text,
      attachment: attachment,
      forwardedFrom: forwardedFrom,
      createdAt: _asInt(response['created_at']) > 0
          ? _asInt(response['created_at'])
          : DateTime.now().millisecondsSinceEpoch ~/ 1000,
      fromMe: true,
    );
    _lastMessages[roomDialogKey(room)] = message;
    _markActivity(room, message.createdAt);
    try {
      if (temporaryId != null) {
        await DbService.instance.promoteRoomOptimistic(
          roomKey: roomDialogKey(room),
          temporaryId: temporaryId,
          messageId: id,
          createdAt: message.createdAt,
        );
      } else {
        await DbService.instance.upsertRoomMessages(roomDialogKey(room), [
          _roomMessageToMap(message),
        ]);
      }
    } catch (error) {
      // A successful server send must not be reported as failed merely
      // because local caching encountered a storage error.
      appLog.warn('room', 'sent message cache failed: $error');
    }
    activityRevision.value++;
    _roomEvents.add(
      RoomEvent(roomType: room.roomType, roomId: room.id, messageId: id),
    );
    unawaited(loadMy().catchError((_) => const <RoomSummary>[]));
  }

  Future<void> sendText(
    RoomSummary room,
    String text, {
    String? forwardedFrom,
  }) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty || trimmed.length > 10_000) return;
    final ownUsername =
        (await AuthService.username())?.trim().toLowerCase() ?? '';
    if (ownUsername.isEmpty) throw StateError('Нет активного аккаунта');
    final clientMessageId = const Uuid().v4();
    final temporaryId = -DateTime.now().microsecondsSinceEpoch;
    final createdAt = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final optimistic = RoomMessage(
      id: temporaryId,
      senderUsername: ownUsername,
      senderDisplayName: ownUsername,
      senderAvatarUrl: ChatRepo.instance.getPeerAvatarCached(ownUsername),
      text: trimmed,
      forwardedFrom: forwardedFrom,
      createdAt: createdAt,
      fromMe: true,
      pending: true,
    );
    final draft = <String, dynamic>{
      'room_type': room.roomType,
      'room_id': room.id,
      'temporary_id': temporaryId,
      'sender_username': ownUsername,
      'text': trimmed,
      'sid': DateTime.now().microsecondsSinceEpoch,
      if (forwardedFrom != null && forwardedFrom.isNotEmpty)
        'forwarded_from': forwardedFrom,
    };
    await _ensureAccountDatabase();
    await DbService.instance.enqueueRoomText(
      id: clientMessageId,
      roomKey: roomDialogKey(room),
      target: '${room.roomType}/${room.id}',
      payload: draft,
      optimisticMessage: _roomMessageToMap(optimistic),
    );
    _lastMessages[roomDialogKey(room)] = optimistic;
    _markActivity(room, createdAt);
    activityRevision.value++;
    unawaited(_drainRoomOutbox());
  }

  Future<void> sendAttachment(
    RoomSummary room, {
    required Uint8List bytes,
    required String mime,
    required String fileName,
    String caption = '',
  }) async {
    if (bytes.isEmpty) return;
    if (bytes.length > 50 * 1024 * 1024 - 64) {
      throw StateError('Файл больше 50 МБ');
    }
    if (room.isChannel && !room.canManage) {
      throw StateError('В канале вложения отправляют только администраторы');
    }
    final ownUsername =
        (await AuthService.username())?.trim().toLowerCase() ?? '';
    if (ownUsername.isEmpty) throw StateError('Нет активного аккаунта');
    final cipher = await CryptoV2.instance.encryptAttachment(bytes);
    final uploaded = await _api.uploadChatFile(
      path: '/v2/rooms/${room.roomType}/${room.id}/files',
      bytes: List<int>.from(cipher['blob'] as Uint8List),
      filename: 'encrypted.bin',
      mime: 'application/octet-stream',
    );
    final fileId = uploaded['file_id']?.toString();
    if (fileId == null || fileId.isEmpty) {
      throw StateError('Сервер не вернул идентификатор вложения');
    }
    final attachment = <String, dynamic>{
      'file_id': fileId,
      'file_name': fileName,
      'mime': mime,
      'size': bytes.length,
      'key': cipher['key'],
      'iv': cipher['iv'],
    };
    final clientMessageId = const Uuid().v4();
    final temporaryId = -DateTime.now().microsecondsSinceEpoch;
    final createdAt = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final optimistic = RoomMessage(
      id: temporaryId,
      senderUsername: ownUsername,
      senderDisplayName: ownUsername,
      senderAvatarUrl: ChatRepo.instance.getPeerAvatarCached(ownUsername),
      text: caption.trim(),
      attachment: attachment,
      forwardedFrom: null,
      createdAt: createdAt,
      fromMe: true,
      pending: true,
    );
    final draft = <String, dynamic>{
      'room_type': room.roomType,
      'room_id': room.id,
      'temporary_id': temporaryId,
      'sender_username': ownUsername,
      'text': caption.trim(),
      'attachment': attachment,
      'attachment_file_ids': [fileId],
      'sid': DateTime.now().microsecondsSinceEpoch,
    };
    await _ensureAccountDatabase();
    await DbService.instance.enqueueRoomText(
      id: clientMessageId,
      roomKey: roomDialogKey(room),
      target: '${room.roomType}/${room.id}',
      payload: draft,
      optimisticMessage: _roomMessageToMap(optimistic),
    );
    _lastMessages[roomDialogKey(room)] = optimistic;
    _markActivity(room, createdAt);
    activityRevision.value++;
    unawaited(_drainRoomOutbox());
  }

  Future<Uint8List> downloadAttachment(
    RoomSummary room,
    Map<String, dynamic> attachment,
  ) async {
    final fileId = attachment['file_id']?.toString();
    final key = attachment['key']?.toString();
    final iv = attachment['iv']?.toString();
    if (fileId == null || key == null || iv == null) {
      throw const FormatException('Неполные данные вложения');
    }
    final raw = await _api.downloadChatFile(
      '/v2/rooms/${room.roomType}/${room.id}/files/${Uri.encodeComponent(fileId)}',
    );
    if (raw == null) throw StateError('Файл удалён или срок хранения истёк');
    return CryptoV2.instance.decryptAttachment(
      blob: Uint8List.fromList(raw),
      key: key,
      iv: iv,
    );
  }

  Future<void> _drainRoomOutbox() {
    final running = _outboxDrain;
    if (running != null) return running;
    late final Future<void> drain;
    drain = _drainRoomOutboxImpl().whenComplete(() {
      if (identical(_outboxDrain, drain)) _outboxDrain = null;
    });
    _outboxDrain = drain;
    return drain;
  }

  Future<void> _drainRoomOutboxImpl() async {
    final username = await _ensureAccountDatabase();
    if (username == null) return;
    try {
      if (rooms.value.isEmpty) await loadMy();
      final entries = await DbService.instance.dueOutboxEntries(
        limit: 100,
        kind: 'room_text',
      );
      for (final entry in entries) {
        final draft = entry.payload;
        final roomType = draft['room_type']?.toString();
        final roomId = _asInt(draft['room_id']);
        final temporaryId = _asInt(draft['temporary_id']);
        RoomSummary? room;
        for (final candidate in rooms.value) {
          if (candidate.roomType == roomType && candidate.id == roomId) {
            room = candidate;
            break;
          }
        }
        if (room == null) continue;
        try {
          final response = await _sendQueuedRoomText(room, entry);
          await _rememberSentMessage(
            room,
            response,
            draft['text']?.toString() ?? '',
            senderUsername: username.toLowerCase(),
            forwardedFrom: draft['forwarded_from']?.toString(),
            attachment: draft['attachment'] is Map
                ? Map<String, dynamic>.from(draft['attachment'] as Map)
                : null,
            temporaryId: temporaryId,
          );
          await DbService.instance.deleteOutboxEntry(entry.id);
        } catch (error) {
          final staleKey =
              error is ApiException &&
              error.status == 409 &&
              error.message.toLowerCase().contains('stale');
          if (staleKey) await DbService.instance.clearOutboxRequest(entry.id);
          if (!_isTransientOutboxError(error)) {
            await DbService.instance.markRoomSendFailed(
              roomDialogKey(room),
              temporaryId,
            );
            await DbService.instance.deleteOutboxEntry(entry.id);
            final current = _lastMessages[roomDialogKey(room)];
            if (current?.id == temporaryId) {
              _lastMessages[roomDialogKey(room)] = RoomMessage(
                id: current!.id,
                senderUsername: current.senderUsername,
                senderDisplayName: current.senderDisplayName,
                senderAvatarUrl: current.senderAvatarUrl,
                text: current.text,
                attachment: current.attachment,
                forwardedFrom: current.forwardedFrom,
                createdAt: current.createdAt,
                fromMe: true,
                sendFailed: true,
              );
            }
            activityRevision.value++;
            _roomEvents.add(
              RoomEvent(
                roomType: room.roomType,
                roomId: room.id,
                messageId: temporaryId,
              ),
            );
            appLog.warn('outbox', 'permanent room send failure: $error');
            continue;
          }
          final attempts = entry.attempts + 1;
          final seconds = (1 << attempts.clamp(0, 8)).clamp(2, 300);
          await DbService.instance.scheduleOutboxRetry(
            id: entry.id,
            attempts: attempts,
            nextAttemptAt: DateTime.now()
                .add(Duration(seconds: staleKey ? 1 : seconds))
                .millisecondsSinceEpoch,
            error: error.toString(),
          );
          appLog.warn('outbox', 'queued room retry in ${seconds}s: $error');
          return;
        }
      }
    } catch (error) {
      appLog.warn('outbox', 'room queue scan failed: $error');
    }
  }

  bool _isTransientOutboxError(Object error) {
    if (error is ApiException) {
      return error.status == 408 ||
          error.status == 429 ||
          error.status >= 500 ||
          (error.status == 409 &&
              error.message.toLowerCase().contains('stale'));
    }
    final message = error.toString().toLowerCase();
    return !message.contains('forbidden') &&
        !message.contains('не найден') &&
        !message.contains('invalid') &&
        !message.contains('запрещ') &&
        !message.contains('422');
  }

  Future<Map<String, dynamic>> _sendQueuedRoomText(
    RoomSummary room,
    OutboxEntry entry,
  ) async {
    final draft = entry.payload;
    if (entry.requestPayload != null) {
      try {
        return await _sendRoomPayload(room, entry.requestPayload!);
      } on ApiException catch (error) {
        if (error.status != 409 ||
            !error.message.toLowerCase().contains('stale')) {
          rethrow;
        }
        await DbService.instance.clearOutboxRequest(entry.id);
      }
    }

    final payload = jsonEncode({
      'v': 2,
      'type': 'msg',
      'text': draft['text']?.toString() ?? '',
      'sid': _asInt(draft['sid']),
      if (draft['attachment'] is Map)
        'attachment': Map<String, dynamic>.from(draft['attachment'] as Map),
      if (draft['forwarded_from'] != null)
        'forwarded_from': draft['forwarded_from'],
    });
    late final Map<String, dynamic> request;
    if (!room.isEncrypted) {
      request = {
        'payload': payload,
        'client_message_id': entry.id,
        if (draft['attachment_file_ids'] is List)
          'attachment_file_ids': draft['attachment_file_ids'],
      };
    } else {
      final ownUsername =
          (await AuthService.username())?.trim().toLowerCase() ?? '';
      final members = await _loadMembers(room);
      final usernames = <String>{
        ...members.map((member) => member['username']?.toString() ?? ''),
        if (ownUsername.isNotEmpty) ownUsername,
      }..removeWhere((value) => value.isEmpty);
      final envelopes = <Map<String, dynamic>>[];
      for (final memberUsername in usernames) {
        final keys = await ChatRepo.instance.getPeerV2Keys(
          memberUsername,
          forceRefresh: true,
        );
        final devices = (keys?['devices'] as List?) ?? const [];
        for (final rawDevice in devices.whereType<Map>()) {
          final device = Map<String, dynamic>.from(rawDevice);
          final pub = device['device_pub']?.toString();
          final deviceId = _asInt(device['device_id']);
          if (pub == null || pub.isEmpty || deviceId <= 0) continue;
          try {
            final envelope = await CryptoV2.instance.encryptV2(
              Uint8List.fromList(base64.decode(pub)),
              utf8.encode(payload),
            );
            envelopes.add({
              'target_device_id': deviceId,
              'target_device_pub': pub,
              'envelope': envelope,
            });
          } on FormatException {
            // Ignore one malformed device key; a valid device can still receive.
          }
        }
      }
      if (envelopes.isEmpty) {
        throw StateError('У участников нет доступных V2-ключей');
      }
      request = {
        'envelopes': envelopes,
        'client_message_id': entry.id,
        if (draft['attachment_file_ids'] is List)
          'attachment_file_ids': draft['attachment_file_ids'],
      };
    }
    await DbService.instance.saveOutboxRequest(entry.id, request);
    return _sendRoomPayload(room, request);
  }

  Future<Map<String, dynamic>> _sendRoomPayload(
    RoomSummary room,
    Map<String, dynamic> body,
  ) async {
    final path = '/v2/rooms/${room.roomType}/${room.id}/send';
    appLog.info(
      'room',
      'send ${room.roomType}/${room.id} '
          'via=http visibility=${room.visibility} encrypted=${room.isEncrypted}',
    );
    // HTTP gives each send a direct response. A timed-out WS RPC can leave us
    // unable to tell whether the server stored the message; retrying it over
    // HTTP could create a duplicate. The HTTP handler still broadcasts the
    // room.v2.new event to connected members.
    final raw = await _api.chatPost(path, body);
    if (raw is! Map || raw['message_id'] == null) {
      throw StateError('Сервер не подтвердил отправку сообщения комнаты');
    }
    return Map<String, dynamic>.from(raw);
  }

  Future<List<Map<String, dynamic>>> _loadMembers(RoomSummary room) async {
    final path = room.isChannel
        ? '/v2/rooms/channels/${room.id}/members'
        : '/v2/rooms/groups/${room.id}/members';
    final raw = await _api.chatGet(path);
    final values = Map<String, dynamic>.from(raw as Map)['members'];
    return values is List
        ? values
              .whereType<Map>()
              .map((item) => Map<String, dynamic>.from(item))
              .toList(growable: false)
        : const <Map<String, dynamic>>[];
  }

  static int _asInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }

  static String? _nonEmpty(Object? value) {
    final text = value?.toString().trim();
    return text == null || text.isEmpty ? null : text;
  }

  static Map<String, dynamic>? _decodeAttachment(Object? raw) {
    if (raw is Map) return Map<String, dynamic>.from(raw);
    final text = raw?.toString();
    if (text == null || text.isEmpty) return null;
    try {
      final decoded = jsonDecode(text);
      return decoded is Map ? Map<String, dynamic>.from(decoded) : null;
    } catch (_) {
      return null;
    }
  }
}
