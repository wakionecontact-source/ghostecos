// Комбинированный поиск: локальные диалоги/сообщения + удалённые юзеры.
//
// Дебаунс 500мс (на стороне виджета). При @-префиксе сначала ищет юзеров
// по username, иначе — диалоги/сообщения/юзеры параллельно.

import 'dart:async';
import 'api_client.dart';
import 'auth_service.dart';
import 'db_service.dart';
import '../core/local/app_logger.dart';

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

/// Результат поиска + флаг "серверная часть не ответила" — чтобы UI мог
/// показать "нет соединения", а не молча выдать "ничего не найдено" (эти
/// два состояния раньше визуально не отличались, что маскировало сетевые
/// проблемы под "юзера не существует").
class SearchOutcome {
  final List<SearchHit> hits;
  final bool remoteFailed;
  const SearchOutcome(this.hits, {this.remoteFailed = false});
}

class SearchService {
  SearchService._();
  static final SearchService instance = SearchService._();
  final _api = ApiClient();

  /// Главный метод. Возвращает сгруппированные результаты:
  /// 1) Diaлоги — локально
  /// 2) Юзеры с сервера (без локального диалога)
  /// 3) Сообщения локально
  Future<SearchOutcome> search(String rawQuery) async {
    final q = rawQuery.trim();
    if (q.isEmpty) return const SearchOutcome([]);
    // Если префикс @ — стрипаем для поиска по username, но запоминаем
    // приоритет юзеров.
    final hasAt = q.startsWith('@');
    final stripped = hasAt ? q.substring(1) : q;
    if (stripped.isEmpty) return const SearchOutcome([]);

    // Параллельно: локальные диалоги, локальные сообщения, серверный поиск юзеров.
    bool remoteFailed = false;
    final results = await Future.wait([
      DbService.instance.searchDialogs(stripped),
      DbService.instance.searchMessages(stripped),
      _searchUsersRemote(stripped).catchError((Object e) {
        remoteFailed = true;
        appLog.warn('search', 'Серверный поиск юзеров не удался: $e');
        return <FoundUser>[];
      }),
    ]);
    final dialogs = results[0] as List<StoredDialog>;
    final messages = results[1] as List<StoredMessage>;
    final users = results[2] as List<FoundUser>;

    // Уберём дубли юзеров которые уже есть в диалогах (чтобы не показывать
    // одного и того же дважды) И самого себя (нельзя «написать себе же» —
    // для своих заметок будет отдельное «Избранное/Заметки»).
    final me = (await AuthService.username())?.toLowerCase();
    final knownUsernames = dialogs.map((d) => d.username.toLowerCase()).toSet();
    final newUsers = users
        .where(
          (u) =>
              !knownUsernames.contains(u.username.toLowerCase()) &&
              u.username.toLowerCase() != me,
        )
        .toList();

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
    return SearchOutcome(hits, remoteFailed: remoteFailed);
  }

  Future<List<FoundUser>> _searchUsersRemote(String q) async {
    // Ошибку намеренно НЕ глушим тут — её ловит catchError в search(), чтобы
    // отличить "сеть отвалилась" от "юзера правда нет" (см. SearchOutcome).
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
  }
}
