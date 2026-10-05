import 'package:flutter/foundation.dart';

import 'api_client.dart';

/// Metadata of a GhostChat 1.2 channel.
///
/// This deliberately does not contain a message key. Public channels have no
/// E2EE payload; private channels will receive their V2 epoch material through
/// a separate key protocol once the membership/invite flow is implemented.
class ChannelSummary {
  final int id;
  final String username;
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

  const ChannelSummary({
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
  });

  bool get isPublic => visibility == 'public';
  bool get isPrivate => visibility == 'private';
  bool get isEncrypted => encryptionMode == 'e2ee_v2';
  bool get canManage => role == 'owner' || role == 'admin';

  factory ChannelSummary.fromMap(Map<String, dynamic> map) {
    int asInt(Object? value, [int fallback = 0]) {
      if (value is int) return value;
      if (value is num) return value.toInt();
      return int.tryParse(value?.toString() ?? '') ?? fallback;
    }

    return ChannelSummary(
      id: asInt(map['id']),
      username: map['username']?.toString() ?? '',
      title: map['title']?.toString() ?? '',
      about: map['about']?.toString() ?? '',
      ownerId: asInt(map['owner_id']),
      visibility: map['visibility']?.toString() ?? 'private',
      historyMode: map['history_mode']?.toString() ?? 'new_only',
      encryptionMode: map['encryption_mode']?.toString() ?? 'e2ee_v2',
      keyEpoch: asInt(map['key_epoch'], 1),
      membersCount: asInt(map['members_count']),
      role: map['role']?.toString(),
      createdAt: map['created_at'] == null ? null : asInt(map['created_at']),
      updatedAt: map['updated_at'] == null ? null : asInt(map['updated_at']),
      avatarUrl: map['avatar_url']?.toString(),
    );
  }
}

class ChannelHandleCheck {
  final String handle;
  final bool available;
  final String? occupiedBy;

  const ChannelHandleCheck({
    required this.handle,
    required this.available,
    required this.occupiedBy,
  });

  factory ChannelHandleCheck.fromMap(Map<String, dynamic> map) =>
      ChannelHandleCheck(
        handle: map['handle']?.toString() ?? '',
        available: map['available'] == true,
        occupiedBy: map['occupied_by']?.toString(),
      );
}

/// Client facade for the new channel API. No legacy /group/* calls belong
/// here; that separation is intentional while the 1.2 protocol is rebuilt.
class ChannelService {
  ChannelService._();
  static final ChannelService instance = ChannelService._();

  final ApiClient _api = ApiClient();
  final ValueNotifier<List<ChannelSummary>> myChannels = ValueNotifier(
    const [],
  );

  Future<ChannelHandleCheck> checkHandle(String username) async {
    final raw = await _api.chatGet('/v2/channels/handle/check', {
      'username': username,
    });
    return ChannelHandleCheck.fromMap(Map<String, dynamic>.from(raw as Map));
  }

  Future<ChannelSummary> create({
    required String username,
    required String title,
    String about = '',
    String visibility = 'private',
    String historyMode = 'new_only',
  }) async {
    final raw = await _api.chatPost('/v2/channels', {
      'username': username,
      'title': title,
      'about': about,
      'visibility': visibility,
      'history_mode': historyMode,
    });
    final channel = ChannelSummary.fromMap(
      Map<String, dynamic>.from(raw as Map),
    );
    await loadMy();
    return channel;
  }

  Future<List<ChannelSummary>> loadMy() async {
    final raw = await _api.chatGet('/v2/channels/my');
    final map = Map<String, dynamic>.from(raw as Map);
    final values = map['channels'];
    final channels = values is List
        ? values
              .whereType<Map>()
              .map(
                (item) =>
                    ChannelSummary.fromMap(Map<String, dynamic>.from(item)),
              )
              .toList(growable: false)
        : const <ChannelSummary>[];
    myChannels.value = channels;
    return channels;
  }

  Future<ChannelSummary> getByUsername(String username) async {
    final raw = await _api.chatGet('/v2/channels/$username');
    return ChannelSummary.fromMap(Map<String, dynamic>.from(raw as Map));
  }

  Future<ChannelSummary> join(String username) async {
    final raw = await _api.chatPost('/v2/channels/$username/join');
    final channel = ChannelSummary.fromMap(
      Map<String, dynamic>.from(raw as Map),
    );
    await loadMy();
    return channel;
  }

  Future<ChannelSummary> update(
    int channelId, {
    String? username,
    String? title,
    String? about,
    String? visibility,
    String? historyMode,
  }) async {
    final raw = await _api.chatPatch('/v2/channels/id/$channelId', {
      if (username != null) 'username': username,
      if (title != null) 'title': title,
      if (about != null) 'about': about,
      if (visibility != null) 'visibility': visibility,
      if (historyMode != null) 'history_mode': historyMode,
    });
    final channel = ChannelSummary.fromMap(
      Map<String, dynamic>.from(raw as Map),
    );
    await loadMy();
    return channel;
  }

  void dispose() {
    myChannels.dispose();
  }
}
