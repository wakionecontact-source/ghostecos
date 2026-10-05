// Кэш профилей (свой + чужие) — "покажи сохранённое сразу, спроси сервер
// в фоне, обнови если поменялось" (stale-while-revalidate). SharedPreferences
// достаточно: профиль — маленький JSON, не медиа (медиа кэшируется отдельно
// в db_service.dart::filecache).
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ProfileCache {
  ProfileCache._();
  static final ProfileCache instance = ProfileCache._();
  static const _profileCacheTtl = Duration(minutes: 5);

  String _profileKey(String username) => 'profile_cache_v1_$username';
  String _profileUpdatedKey(String username) =>
      'profile_cache_updated_v1_$username';
  String _postsKey(String username) => 'profile_cache_posts_v1_$username';

  // In-memory слой поверх SharedPreferences — SharedPreferences всегда async
  // (минимум 1 кадр задержки), из-за чего при каждом визите на вкладку
  // "Профиль" на миг мелькал skeleton, даже с диска подтягивая мгновенно.
  // Память же читается синхронно прямо в initializer поля State — ноль
  // кадров задержки для уже посещённого в этой сессии профиля.
  final Map<String, Map<String, dynamic>> _memProfiles = {};
  final Map<String, List<Map<String, dynamic>>> _memPosts = {};

  /// Rebuilds lightweight profile consumers (for example the bottom bar)
  /// when a background profile refresh changes the cached avatar URL.
  final ValueNotifier<int> revision = ValueNotifier<int>(0);

  Map<String, dynamic>? getProfileSync(String username) =>
      _memProfiles[username];
  List<Map<String, dynamic>>? getPostsSync(String username) =>
      _memPosts[username];

  Future<Map<String, dynamic>?> getProfile(String username) async {
    final mem = _memProfiles[username];
    if (mem != null) return mem;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_profileKey(username));
    if (raw == null) return null;
    try {
      final parsed = Map<String, dynamic>.from(jsonDecode(raw) as Map);
      _memProfiles[username] = parsed;
      revision.value++;
      return parsed;
    } catch (_) {
      return null;
    }
  }

  /// Профили из списка чатов можно показывать сразу с диска, а сеть дёргать
  /// только для устаревшей записи. Это сохраняет stale-while-revalidate и не
  /// превращает каждое переключение вкладки в пачку одинаковых запросов.
  Future<bool> isProfileFresh(String username) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedAt = prefs.getInt(_profileUpdatedKey(username));
      if (savedAt == null) return false;
      final age = DateTime.now().millisecondsSinceEpoch - savedAt;
      return age >= 0 && age < _profileCacheTtl.inMilliseconds;
    } catch (_) {
      return false;
    }
  }

  Future<void> setProfile(String username, Map<String, dynamic> profile) async {
    final next = Map<String, dynamic>.from(profile);
    final previous = _memProfiles[username];
    // Не теряем поля при частичных ответах старых API. В частности, старый
    // /prof endpoint не возвращал about, а его ответ затем сохранялся целиком.
    if (!next.containsKey('about') &&
        previous?['about'] is String &&
        (previous!['about'] as String).trim().isNotEmpty) {
      next['about'] = previous['about'];
    }
    _memProfiles[username] = next;
    revision.value++;
    final prefs = await SharedPreferences.getInstance();
    await Future.wait([
      prefs.setString(_profileKey(username), jsonEncode(next)),
      prefs.setInt(
        _profileUpdatedKey(username),
        DateTime.now().millisecondsSinceEpoch,
      ),
    ]);
  }

  Future<List<Map<String, dynamic>>?> getPosts(String username) async {
    final mem = _memPosts[username];
    if (mem != null) return mem;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_postsKey(username));
    if (raw == null) return null;
    try {
      final list = jsonDecode(raw) as List;
      final parsed = list
          .whereType<Map>()
          .map((m) => Map<String, dynamic>.from(m))
          .toList();
      _memPosts[username] = parsed;
      return parsed;
    } catch (_) {
      return null;
    }
  }

  /// Храним только первую "страницу" (сколько грузим на старте) — не
  /// разрастаемся бесконечно от подгруженной при скролле ленты.
  Future<void> setPosts(
    String username,
    List<Map<String, dynamic>> items,
  ) async {
    final page = items.take(40).toList();
    _memPosts[username] = page;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_postsKey(username), jsonEncode(page));
  }

  /// Вызывать при выходе из аккаунта — на общем устройстве следующий
  /// залогинившийся не должен видеть кэш профилей/постов, оставшийся от
  /// предыдущего аккаунта (найдено ревью 2026-07-20: логаут не чистил ни
  /// in-memory, ни SharedPreferences-записи этого кэша).
  Future<void> clearAll() async {
    _memProfiles.clear();
    _memPosts.clear();
    revision.value++;
    final prefs = await SharedPreferences.getInstance();
    final keys = prefs.getKeys().where(
      (k) =>
          k.startsWith('profile_cache_v1_') ||
          k.startsWith('profile_cache_updated_v1_') ||
          k.startsWith('profile_cache_posts_v1_'),
    );
    for (final k in keys) {
      await prefs.remove(k);
    }
  }
}
