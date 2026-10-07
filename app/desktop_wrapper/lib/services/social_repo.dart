// SocialRepo — поиск, уведомления, миниски. Лента живёт в FeedRepo отдельно.
import 'package:flutter/foundation.dart';
import 'api_client.dart';
import 'feed_repo.dart';

class SearchResult {
  final String type; // 'users' | 'posts'
  final List<dynamic> results;
  const SearchResult({required this.type, required this.results});
}

class NotifItem {
  final int id;
  final String type;
  final int? postId;
  final String? preview;
  final bool isRead;
  final dynamic createdAt;
  final String? actorUsername;
  final String? actorName;
  NotifItem({
    required this.id,
    required this.type,
    this.postId,
    this.preview,
    this.isRead = false,
    this.createdAt,
    this.actorUsername,
    this.actorName,
  });
  factory NotifItem.fromMap(Map<String, dynamic> m) => NotifItem(
        id: (m['id'] as num).toInt(),
        type: (m['type'] as String?) ?? 'unknown',
        postId: m['post_id'] is num ? (m['post_id'] as num).toInt() : null,
        preview: m['preview'] as String?,
        isRead: m['is_read'] == true || m['is_read'] == 1,
        createdAt: m['created_at'],
        actorUsername: m['actor_username'] as String?,
        actorName: m['actor_name'] as String?,
      );
}

class SocialRepo {
  SocialRepo._();
  static final SocialRepo instance = SocialRepo._();
  final _api = ApiClient();

  final ValueNotifier<int> unreadNotifNotifier = ValueNotifier(0);

  Future<SearchResult> search(String q, {int offset = 0}) async {
    final r = await _api.socGet('/search', {'q': q, 'offset': offset});
    if (r is Map) {
      return SearchResult(
        type: (r['type'] as String?) ?? 'posts',
        results: (r['results'] as List?) ?? const [],
      );
    }
    return const SearchResult(type: 'posts', results: []);
  }

  Future<({List<NotifItem> items, bool hasMore})> fetchNotifications({int offset = 0}) async {
    final r = await _api.socGet('/notif', {'offset': offset});
    if (r is Map) {
      final list = (r['notifications'] as List?) ?? const [];
      final items = list
          .whereType<Map>()
          .map((m) => NotifItem.fromMap(Map<String, dynamic>.from(m)))
          .toList();
      return (items: items, hasMore: (r['has_more'] as bool?) ?? false);
    }
    return (items: <NotifItem>[], hasMore: false);
  }

  Future<int> fetchUnreadCount() async {
    try {
      final r = await _api.socGet('/notif/unread');
      if (r is Map) {
        final n = (r['count'] as num?)?.toInt() ?? 0;
        unreadNotifNotifier.value = n;
        return n;
      }
    } catch (_) {}
    return 0;
  }

  Future<void> markRead(List<int> ids) async {
    if (ids.isEmpty) return;
    try {
      await _api.socPost('/notif/read', {'ids': ids});
      final cur = unreadNotifNotifier.value;
      unreadNotifNotifier.value = (cur - ids.length).clamp(0, 99999);
    } catch (e) {
      if (kDebugMode) print('[SocialRepo.markRead] $e');
    }
  }

  Future<List<FeedPost>> fetchMiniska({int offset = 0, int limit = 20}) async {
    final r = await _api.socGet('/miniska/feed', {'limit': limit, 'offset': offset});
    if (r is List) {
      final posts = <FeedPost>[];
      for (final raw in r) {
        if (raw is! Map) continue;
        try {
          posts.add(FeedPost.fromMap(Map<String, dynamic>.from(raw)));
        } catch (e) {
          if (kDebugMode) print('[SocialRepo.miniska] skip bad: $e');
        }
      }
      return posts;
    }
    return [];
  }
}
