// Комбинированный поиск: локальные диалоги/сообщения + удалённые юзеры.
//
// Дебаунс 500мс (на стороне виджета). При @-префиксе сначала ищет юзеров
// по username, иначе — диалоги/сообщения/юзеры параллельно.

import 'dart:async';
import 'package:flutter/foundation.dart';
import 'api_client.dart';
import 'db_service.dart';

class FoundUser {
  final String username;
  final String displayName;
  final bool isGuest;
  FoundUser({required this.username, required this.displayName, this.isGuest = false});
}

class SearchHit {
  /// Диалог (вверху списка результатов)
  final StoredDialog? dialog;
  /// Найденное сообщение (для тапа → открыть чат + scroll к sid)
  final StoredMessage? message;
  /// Юзер с сервера (тот с кем ещё нет переписки)
  final FoundUser? user;
  SearchHit.dialog(this.dialog) : message = null, user = null;
  SearchHit.message(this.message) : dialog = null, user = null;
  SearchHit.user(this.user) : dialog = null, message = null;
}

class SearchService {
  SearchService._();
  static final SearchService instance = SearchService._();
  final _api = ApiClient();

  /// Главный метод. Возвращает сгруппированные результаты:
  /// 1) Diaлоги — локально
  /// 2) Юзеры с сервера (без локального диалога)
  /// 3) Сообщения локально
  Future<List<SearchHit>> search(String rawQuery) async {
    final q = rawQuery.trim();
    if (q.isEmpty) return [];
    // Если префикс @ — стрипаем для поиска по username, но запоминаем
    // приоритет юзеров.
    final hasAt = q.startsWith('@');
    final stripped = hasAt ? q.substring(1) : q;
    if (stripped.isEmpty) return [];

    // Параллельно: локальные диалоги, локальные сообщения, серверный поиск юзеров.
    final results = await Future.wait([
      DbService.instance.searchDialogs(stripped),
      DbService.instance.searchMessages(stripped),
      _searchUsersRemote(stripped),
    ]);
    final dialogs = results[0] as List<StoredDialog>;
    final messages = results[1] as List<StoredMessage>;
    final users = results[2] as List<FoundUser>;

    // Уберём дубли юзеров которые уже есть в диалогах (чтобы не показывать
    // одного и того же дважды).
    final knownUsernames = dialogs.map((d) => d.username.toLowerCase()).toSet();
    final newUsers = users.where((u) => !knownUsernames.contains(u.username.toLowerCase())).toList();

    final hits = <SearchHit>[];
    if (hasAt) {
      // Приоритет юзерам — сначала те у кого с тобой ещё нет диалога,
      // потом диалоги, потом сообщения.
      for (final u in newUsers) hits.add(SearchHit.user(u));
      for (final d in dialogs) hits.add(SearchHit.dialog(d));
    } else {
      // Обычный порядок: диалоги (наиболее релевантны), затем новые юзеры.
      for (final d in dialogs) hits.add(SearchHit.dialog(d));
      for (final u in newUsers) hits.add(SearchHit.user(u));
    }
    for (final m in messages) hits.add(SearchHit.message(m));
    return hits;
  }

  Future<List<FoundUser>> _searchUsersRemote(String q) async {
    try {
      // Отдельный chat-endpoint: всегда юзеры (не посты ленты), игнорирует @,
      // отсортированы exact > prefix > contains, с флагом has_keys.
      final r = await _api.chatGet('/users/search', {'q': q});
      final list = (r is Map ? (r['results'] as List?) : null) ?? const [];
      return list
          .whereType<Map>()
          .map((m) => FoundUser(
                username: (m['username'] as String?) ?? '',
                displayName: (m['display_name'] as String?) ?? (m['username'] as String? ?? ''),
                isGuest: (m['is_guest'] as bool?) ?? false,
              ))
          .where((u) => u.username.isNotEmpty)
          .toList();
    } catch (e) {
      if (kDebugMode) print('[search-remote] $e');
      return [];
    }
  }
}
