// FeedRepo — оркестратор ленты. Тянет /post/feed, держит локальный кэш,
// нотифицирует UI через ValueNotifier-ы. Поддерживает простую модель поста.

import 'dart:async';
import 'package:flutter/foundation.dart';
import 'api_client.dart';

class FeedPost {
  final int id;
  final String content;
  final String authorUsername;
  final String authorDisplayName;
  final dynamic createdAt;
  final dynamic editedAt;
  final List<dynamic>? media;
  final bool isNsfw;
  final int commentsCount;
  int activity;
  final Map<String, int> reactions;
  String? myReaction;
  bool reposted;
  bool followed;

  FeedPost({
    required this.id,
    required this.content,
    required this.authorUsername,
    required this.authorDisplayName,
    required this.createdAt,
    this.editedAt,
    this.media,
    this.isNsfw = false,
    this.commentsCount = 0,
    this.activity = 0,
    Map<String, int>? reactions,
    this.myReaction,
    this.reposted = false,
    this.followed = false,
  }) : reactions = reactions ?? {};

  factory FeedPost.fromMap(Map<String, dynamic> m) => FeedPost(
        id: m['id'] as int,
        content: (m['content'] as String?) ?? '',
        authorUsername: (m['username'] as String?) ?? 'anon',
        authorDisplayName: (m['display_name'] as String?) ??
            (m['username'] as String?) ?? 'anon',
        createdAt: m['created_at'],
        editedAt: m['edited_at'],
        media: (m['media'] is List) ? m['media'] as List : null,
        isNsfw: (m['is_nsfw'] as int? ?? 0) == 1,
        commentsCount: (m['comments_count'] as int?) ?? 0,
        activity: (m['activity'] as int?) ?? 0,
        reactions: (m['reactions'] is Map)
            ? Map<String, int>.from((m['reactions'] as Map).map((k, v) =>
                MapEntry(k.toString(), (v as num).toInt())))
            : <String, int>{},
        myReaction: m['my_reaction'] as String?,
      );
}

class FeedRepo {
  FeedRepo._();
  static final FeedRepo instance = FeedRepo._();
  final _api = ApiClient();

  final ValueNotifier<List<FeedPost>> postsNotifier = ValueNotifier([]);
  final Set<int> _seen = {};
  bool _loading = false;
  bool _exhausted = false;

  /// Загрузить следующую пачку постов (исключая уже виденные).
  Future<void> loadMore({int batch = 30}) async {
    if (_loading || _exhausted) return;
    _loading = true;
    try {
      final exclude = _seen.isEmpty ? '' : _seen.take(400).join(',');
      final r = await _api.socGet('/post/feed', {
        'limit': batch,
        if (exclude.isNotEmpty) 'exclude': exclude,
      });
      // /post/feed возвращает {posts: [...]}, либо просто список
      List rawList;
      if (r is Map && r['posts'] is List) {
        rawList = r['posts'] as List;
      } else if (r is List) {
        rawList = r;
      } else if (r is Map && r['candidates'] is List) {
        rawList = r['candidates'] as List;
      } else {
        rawList = const [];
      }
      if (rawList.isEmpty) {
        _exhausted = true;
        return;
      }
      final newPosts = <FeedPost>[];
      for (final raw in rawList) {
        if (raw is! Map) continue;
        final m = Map<String, dynamic>.from(raw);
        final id = m['id'] as int?;
        if (id == null || _seen.contains(id)) continue;
        _seen.add(id);
        newPosts.add(FeedPost.fromMap(m));
      }
      postsNotifier.value = [...postsNotifier.value, ...newPosts];
    } catch (e) {
      if (kDebugMode) print('[FeedRepo.loadMore] $e');
    } finally {
      _loading = false;
    }
  }

  /// Перезагрузить ленту с нуля.
  Future<void> refresh() async {
    _seen.clear();
    _exhausted = false;
    postsNotifier.value = [];
    await loadMore();
  }

  /// Поставить/снять реакцию.
  Future<void> react(int postId, String emoji) async {
    final list = [...postsNotifier.value];
    final i = list.indexWhere((p) => p.id == postId);
    if (i < 0) return;
    final p = list[i];
    // optimistic
    final prev = p.myReaction;
    if (prev == emoji) {
      p.reactions.update(emoji, (v) => (v - 1).clamp(0, 9999), ifAbsent: () => 0);
      p.myReaction = null;
    } else {
      if (prev != null) {
        p.reactions.update(prev, (v) => (v - 1).clamp(0, 9999), ifAbsent: () => 0);
      }
      p.reactions.update(emoji, (v) => v + 1, ifAbsent: () => 1);
      p.myReaction = emoji;
    }
    postsNotifier.value = list;
    try {
      await _api.socPost('/react/$postId', {'emoji': emoji});
    } catch (e) {
      if (kDebugMode) print('[FeedRepo.react] $e');
    }
  }

  /// Репостнуть пост в свой профиль.
  Future<void> repost(int postId) async {
    try {
      await _api.socPost('/post/$postId/repost');
      final list = [...postsNotifier.value];
      final i = list.indexWhere((p) => p.id == postId);
      if (i >= 0) {
        list[i].reposted = true;
        postsNotifier.value = list;
      }
    } catch (e) {
      if (kDebugMode) print('[FeedRepo.repost] $e');
      rethrow;
    }
  }

  /// Опубликовать новый пост.
  Future<int?> publish(String text) async {
    try {
      final r = await _api.socPost('/post/new', {'content': text});
      final id = (r as Map)['id'] as int?;
      if (id != null) {
        await refresh();
      }
      return id;
    } catch (e) {
      if (kDebugMode) print('[FeedRepo.publish] $e');
      rethrow;
    }
  }
}
