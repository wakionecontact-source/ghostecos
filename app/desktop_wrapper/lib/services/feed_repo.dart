// FeedRepo — оркестратор ленты. Тянет /post/feed, держит локальный кэш,
// нотифицирует UI через ValueNotifier-ы. Поддерживает простую модель поста.

import 'dart:async';
import 'package:flutter/foundation.dart';
import 'api_client.dart';

class FeedMedia {
  final String type; // 'image' | 'video' | 'audio'
  final String url;
  const FeedMedia({required this.type, required this.url});
  static FeedMedia? tryParse(dynamic m) {
    if (m is! Map) return null;
    final t = m['type'];
    final u = m['url'];
    if (t is! String || u is! String) return null;
    return FeedMedia(type: t, url: u);
  }
}

class FromChannel {
  final int id;
  final String name;
  final String? username;
  const FromChannel({required this.id, required this.name, this.username});
}

/// Опрос/викторина под постом.
/// Бэкенд: /post/{id}/vote → {question, options, counts, total, my_vote, is_quiz, correct_idx}.
class PollData {
  final String question;
  final List<String> options;
  Map<int, int> counts; // option_idx → voters
  int total;
  int? myVote;
  final bool isQuiz;
  final int? correctIdx; // только после голосования в quiz

  PollData({
    required this.question,
    required this.options,
    Map<int, int>? counts,
    this.total = 0,
    this.myVote,
    this.isQuiz = false,
    this.correctIdx,
  }) : counts = counts ?? <int, int>{};

  static PollData? tryParse(dynamic raw) {
    if (raw is! Map) return null;
    final q = raw['question'] as String?;
    final opts = raw['options'];
    if (q == null || opts is! List) return null;
    final options = opts.map((o) => o?.toString() ?? '').toList();
    final counts = <int, int>{};
    final rc = raw['counts'];
    if (rc is Map) {
      rc.forEach((k, v) {
        final ki = k is int ? k : int.tryParse(k.toString());
        if (ki != null && v is num) counts[ki] = v.toInt();
      });
    }
    int? mv;
    final mvRaw = raw['my_vote'];
    if (mvRaw is num) mv = mvRaw.toInt();
    int? ci;
    final ciRaw = raw['correct_idx'];
    if (ciRaw is num) ci = ciRaw.toInt();
    return PollData(
      question: q,
      options: options,
      counts: counts,
      total: (raw['total'] is num) ? (raw['total'] as num).toInt() : 0,
      myVote: mv,
      isQuiz: (raw['is_quiz'] == true),
      correctIdx: ci,
    );
  }
}

class FeedPost {
  final int id;
  final int? userId;
  final String content;
  final String authorUsername;
  final String authorDisplayName;
  final dynamic createdAt;
  final dynamic editedAt;
  final List<FeedMedia> media;
  final bool isNsfw;
  final bool nsfwSetByAdmin;
  final int commentsCount;
  final int viewsCount;
  final int repostsCount;
  int activity;
  final Map<String, int> reactions;
  String? myReaction;
  bool reposted;
  /// true → я подписан на автора (`am_following` с сервера).
  bool followed;
  final bool isRepost;
  final FromChannel? fromChannel;
  PollData? poll;

  FeedPost({
    required this.id,
    this.userId,
    required this.content,
    required this.authorUsername,
    required this.authorDisplayName,
    required this.createdAt,
    this.editedAt,
    List<FeedMedia>? media,
    this.isNsfw = false,
    this.nsfwSetByAdmin = false,
    this.commentsCount = 0,
    this.viewsCount = 0,
    this.repostsCount = 0,
    this.activity = 0,
    Map<String, int>? reactions,
    this.myReaction,
    this.reposted = false,
    this.followed = false,
    this.isRepost = false,
    this.fromChannel,
    this.poll,
  }) : reactions = reactions ?? {},
       media = media ?? const [];

  /// Толерантно приводит значение к bool — принимает bool / int (0,1) / null.
  static bool _asBool(dynamic v) {
    if (v is bool) return v;
    if (v is num) return v != 0;
    if (v is String) return v == '1' || v.toLowerCase() == 'true';
    return false;
  }

  /// Толерантно приводит к int — принимает num / bool / null.
  static int _asInt(dynamic v) {
    if (v is num) return v.toInt();
    if (v is bool) return v ? 1 : 0;
    if (v is String) return int.tryParse(v) ?? 0;
    return 0;
  }

  factory FeedPost.fromMap(Map<String, dynamic> m) {
    // /post/feed возвращает reactions в формате
    //   {counts: {emoji: int}, your_emoji: str|null, total: int}
    // или плоско {emoji: int} (для тестов / старых ручек). Поддерживаем оба.
    Map<String, int> reacs = <String, int>{};
    String? mine;
    final raw = m['reactions'];
    if (raw is Map) {
      final counts = raw['counts'];
      if (counts is Map) {
        // hydrated формат
        counts.forEach((k, v) {
          if (v is num) reacs[k.toString()] = v.toInt();
        });
        if (raw['your_emoji'] is String) mine = raw['your_emoji'] as String;
      } else {
        // плоский формат {emoji: int}
        raw.forEach((k, v) {
          if (v is num) reacs[k.toString()] = v.toInt();
        });
      }
    }
    mine ??= m['my_reaction'] as String?;
    final mediaList = <FeedMedia>[];
    if (m['media'] is List) {
      for (final mm in (m['media'] as List)) {
        final mo = FeedMedia.tryParse(mm);
        if (mo != null) mediaList.add(mo);
      }
    }
    FromChannel? fc;
    if (m['from_channel'] is Map) {
      final fm = m['from_channel'] as Map;
      final cid = _asInt(fm['id']);
      final cname = fm['name'] as String?;
      if (cid > 0 && cname != null) {
        fc = FromChannel(id: cid, name: cname, username: fm['username'] as String?);
      }
    }
    return FeedPost(
      id: _asInt(m['id']),
      userId: _asInt(m['user_id']) > 0 ? _asInt(m['user_id']) : null,
      content: (m['content'] as String?) ?? '',
      authorUsername: (m['username'] as String?) ?? 'anon',
      authorDisplayName: (m['display_name'] as String?) ??
          (m['username'] as String?) ?? 'anon',
      createdAt: m['created_at'],
      editedAt: m['edited_at'],
      media: mediaList,
      // is_nsfw приходит как bool с сервера (fmt_post: bool(is_nsfw))
      isNsfw: _asBool(m['is_nsfw']),
      nsfwSetByAdmin: _asBool(m['nsfw_set_by_admin']),
      commentsCount: _asInt(m['comments_count']),
      viewsCount: _asInt(m['views_count']),
      repostsCount: _asInt(m['reposts_count']),
      activity: _asInt(m['activity']),
      reactions: reacs,
      myReaction: mine,
      // am_following — серверное имя; followed оставляем для legacy/тестов
      followed: _asBool(m['am_following']) || _asBool(m['followed']),
      isRepost: _asBool(m['is_repost']),
      fromChannel: fc,
      poll: PollData.tryParse(m['poll']),
    );
  }
}

/// Локальный helper — int|num|null → int? без cast-exception.
int? _maybeInt(dynamic v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v);
  return null;
}

class FeedRepo {
  FeedRepo._();
  static final FeedRepo instance = FeedRepo._();
  final _api = ApiClient();

  final ValueNotifier<List<FeedPost>> postsNotifier = ValueNotifier([]);
  /// Последняя ошибка загрузки (null если успех / ещё не пробовали).
  final ValueNotifier<String?> errorNotifier = ValueNotifier(null);
  final Set<int> _seen = {};
  bool _loading = false;
  bool _exhausted = false;
  int _offset = 0;
  String _sort = 'foryou';
  int _randomSeed = 1;
  String? _tag;

  String get sort => _sort;
  String? get tag => _tag;

  void setSort(String sort) {
    if (_sort == sort) return;
    _sort = sort;
    if (sort == 'random') {
      _randomSeed = (DateTime.now().microsecondsSinceEpoch % 999983).abs() + 1;
    }
  }

  void setTag(String? tag) {
    final t = (tag ?? '').trim();
    _tag = t.isEmpty ? null : t.toLowerCase();
  }

  /// Загрузить следующую пачку постов (исключая уже виденные).
  /// sort: foryou / new / top / old / random / following
  Future<void> loadMore({int batch = 30}) async {
    if (_loading || _exhausted) return;
    _loading = true;
    try {
      late dynamic r;
      if (_sort == 'foryou') {
        // Алгоритмическая лента: candidate-pool с эксклюдом.
        final exclude = _seen.isEmpty ? '' : _seen.take(400).join(',');
        r = await _api.socGet('/post/feed', {
          'limit': batch,
          'offset': _offset,
          if (exclude.isNotEmpty) 'exclude': exclude,
        });
      } else {
        // Классическая лента /post?sort=...
        final q = <String, dynamic>{
          'sort': _sort,
          'offset': _offset,
        };
        if (_tag != null) q['tag'] = _tag;
        if (_sort == 'random') q['seed'] = _randomSeed;
        r = await _api.socGet('/post', q);
      }
      // /post возвращает чистый список постов; /post/feed тоже список
      // (см. _hydrate_posts → return). Старые ручки могли отдавать {posts}.
      List rawList;
      if (r is List) {
        rawList = r;
      } else if (r is Map && r['posts'] is List) {
        rawList = r['posts'] as List;
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
      String? firstSkipErr;
      int skipped = 0;
      for (final raw in rawList) {
        if (raw is! Map) { skipped++; continue; }
        try {
          final m = Map<String, dynamic>.from(raw);
          final id = _maybeInt(m['id']);
          if (id == null || _seen.contains(id)) continue;
          _seen.add(id);
          newPosts.add(FeedPost.fromMap(m));
        } catch (e) {
          skipped++;
          firstSkipErr ??= e.toString();
          if (kDebugMode) print('[FeedRepo] skip bad post: $e');
        }
      }
      postsNotifier.value = [...postsNotifier.value, ...newPosts];
      _offset += rawList.length;
      // Если пришло N постов и ВСЕ не разобрались — это парсинг-баг, надо
      // показать юзеру, иначе он увидит "лента пуста" и подумает что нет данных.
      if (postsNotifier.value.isEmpty && rawList.isNotEmpty && skipped > 0) {
        errorNotifier.value = 'Не удалось разобрать ответ ленты ($skipped шт). $firstSkipErr';
      } else {
        errorNotifier.value = null;
      }
    } catch (e) {
      if (kDebugMode) print('[FeedRepo.loadMore] $e');
      errorNotifier.value = e.toString();
    } finally {
      _loading = false;
    }
  }

  /// Перезагрузить ленту с нуля.
  Future<void> refresh() async {
    _seen.clear();
    _exhausted = false;
    _offset = 0;
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

  /// Опубликовать новый пост с медиа и NSFW.
  /// media — список объектов {type, url} (после _uploadMedia).
  Future<int?> publish(
    String text, {
    List<FeedMedia> media = const [],
    bool isNsfw = false,
  }) async {
    try {
      final r = await _api.socPost('/post/new', {
        'text': text,                                          // ВАЖНО: text, не content
        if (media.isNotEmpty)
          'media': media.map((m) => {'type': m.type, 'url': m.url}).toList(),
        'is_nsfw': isNsfw,
      });
      if (r is! Map) return null;
      final id = _asInt(r['id']);
      if (id <= 0) return null;
      // Оптимистично вставляем новый пост в начало ленты — пользователь
      // сразу видит результат, не ждёт перезагрузку. Дальше в фоне
      // дотягиваем настоящий ответ сервера (если refresh жив).
      try {
        final m = Map<String, dynamic>.from(r);
        // Если сервер не вернул структуру поста — собираем минимальную
        // карту чтобы FeedPost.fromMap не упал.
        m['id'] = id;
        m.putIfAbsent('content', () => text);
        m.putIfAbsent('media',
            () => media.map((mm) => {'type': mm.type, 'url': mm.url}).toList());
        m.putIfAbsent('is_nsfw', () => isNsfw);
        m.putIfAbsent('created_at',
            () => DateTime.now().toUtc().toIso8601String());
        m.putIfAbsent('username', () => m['username'] ?? 'you');
        m.putIfAbsent('display_name', () => m['display_name'] ?? 'Вы');
        final post = FeedPost.fromMap(m);
        if (!_seen.contains(id)) {
          _seen.add(id);
          postsNotifier.value = [post, ...postsNotifier.value];
        }
      } catch (e) {
        if (kDebugMode) print('[FeedRepo.publish] optimistic skip: $e');
      }
      // refresh в фоне — даже если упадёт, пост уже в ленте.
      unawaited(refresh().catchError((e) {
        if (kDebugMode) print('[FeedRepo.publish] refresh ignored: $e');
      }));
      return id;
    } catch (e) {
      if (kDebugMode) print('[FeedRepo.publish] $e');
      rethrow;
    }
  }

  /// Голосование в опросе. Возвращает обновлённый state опроса.
  Future<PollData?> votePoll(int postId, int optionIdx) async {
    final r = await _api.socPost('/post/$postId/vote', {'option_idx': optionIdx});
    if (r is! Map) return null;
    final updated = PollData.tryParse(r);
    if (updated != null) {
      final list = [...postsNotifier.value];
      final i = list.indexWhere((p) => p.id == postId);
      if (i >= 0) {
        list[i].poll = updated;
        postsNotifier.value = list;
      }
    }
    return updated;
  }

  /// Аплоад файла (картинка/видео/аудио) → возвращает FeedMedia.
  Future<FeedMedia> uploadMedia(List<int> bytes, String filename, String mime) async {
    final r = await _api.uploadSocFile(bytes: bytes, filename: filename, mime: mime);
    final type = r['type'] as String? ?? 'image';
    final url = r['url'] as String? ?? '';
    if (url.isEmpty) throw Exception('Сервер не вернул URL медиа');
    return FeedMedia(type: type, url: url);
  }

  /// Удалить пост (только свой).
  Future<void> deletePost(int postId) async {
    await _api.socDelete('/post/$postId');
    final list = postsNotifier.value.where((p) => p.id != postId).toList();
    postsNotifier.value = list;
  }

  /// Редактировать пост (только свой, окно времени).
  Future<void> editPost(int postId, {String? text, bool? isNsfw}) async {
    await _api.socPatch('/post/$postId', {
      if (text != null) 'text': text,
      if (isNsfw != null) 'is_nsfw': isNsfw,
    });
    // Не делаем refresh — обновим только этот пост из локального состояния.
    final list = [...postsNotifier.value];
    final i = list.indexWhere((p) => p.id == postId);
    if (i >= 0 && text != null) {
      // Создаём «обновлённый» FeedPost (FeedPost immutable text/createdAt — пересоздаём).
      final old = list[i];
      list[i] = FeedPost(
        id: old.id, userId: old.userId, content: text,
        authorUsername: old.authorUsername, authorDisplayName: old.authorDisplayName,
        createdAt: old.createdAt, editedAt: DateTime.now().toUtc().toIso8601String(),
        media: old.media, isNsfw: isNsfw ?? old.isNsfw,
        nsfwSetByAdmin: old.nsfwSetByAdmin,
        commentsCount: old.commentsCount, viewsCount: old.viewsCount,
        repostsCount: old.repostsCount, activity: old.activity,
        reactions: Map<String, int>.from(old.reactions), myReaction: old.myReaction,
        reposted: old.reposted, followed: old.followed,
        isRepost: old.isRepost, fromChannel: old.fromChannel,
      );
      postsNotifier.value = list;
    }
  }

  /// Подписаться / отписаться от автора. Обновляет followed во всех его постах.
  Future<void> toggleFollow(String username) async {
    final list = postsNotifier.value;
    final currentlyFollowing = list
        .firstWhere((p) => p.authorUsername == username,
            orElse: () => FeedPost(
              id: 0, content: '', authorUsername: '', authorDisplayName: '',
              createdAt: null,
            ))
        .followed;
    try {
      if (currentlyFollowing) {
        await _api.socDelete('/follow/$username');
      } else {
        await _api.socPost('/follow/$username');
      }
      final updated = list.map((p) {
        if (p.authorUsername != username) return p;
        p.followed = !currentlyFollowing;
        return p;
      }).toList();
      postsNotifier.value = updated;
    } catch (e) {
      if (kDebugMode) print('[FeedRepo.toggleFollow] $e');
      rethrow;
    }
  }

  /// Отметить пост просмотренным (для алгоритмической ленты).
  Future<void> markViewed(int postId) async {
    try {
      await _api.socPost('/post/view', {'post_id': postId});
    } catch (_) { /* best effort */ }
  }

  static int _asInt(dynamic v) {
    if (v is num) return v.toInt();
    if (v is bool) return v ? 1 : 0;
    if (v is String) return int.tryParse(v) ?? 0;
    return 0;
  }
}
