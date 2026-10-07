import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/local/app_logger.dart';
import 'app_security_store.dart';

/// Account-local organization for the unified chat list.
///
/// A chat can belong to several folders. The system folder `main` is always
/// available and is the safety net that keeps every chat visible somewhere.
/// LAN dialogs are persisted by device/account storage just like the rest of
/// the local list; they are never sent to the server.
class ChatOrganizationFolder {
  final String id;
  final String name;
  final String? parentId;
  final String? securityScenarioId;
  final Set<String> chatIds;

  const ChatOrganizationFolder({
    required this.id,
    required this.name,
    this.parentId,
    this.securityScenarioId,
    this.chatIds = const {},
  });

  bool get isSecure => securityScenarioId != null;

  ChatOrganizationFolder copyWith({
    String? name,
    String? parentId,
    String? securityScenarioId,
    Set<String>? chatIds,
  }) => ChatOrganizationFolder(
    id: id,
    name: name ?? this.name,
    parentId: parentId ?? this.parentId,
    securityScenarioId: securityScenarioId ?? this.securityScenarioId,
    chatIds: chatIds ?? this.chatIds,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'parent_id': parentId,
    'security_scenario_id': securityScenarioId,
    'chat_ids': chatIds.toList(),
  };

  factory ChatOrganizationFolder.fromJson(Map<String, dynamic> json) =>
      ChatOrganizationFolder(
        id: json['id']?.toString() ?? '',
        name: json['name']?.toString() ?? '',
        parentId: json['parent_id']?.toString(),
        securityScenarioId: json['security_scenario_id']?.toString(),
        chatIds: (json['chat_ids'] as List? ?? const [])
            .whereType<String>()
            .toSet(),
      );
}

class ChatOrganizationHistoryEntry {
  final String action;
  final String chatId;
  final int at;

  const ChatOrganizationHistoryEntry({
    required this.action,
    required this.chatId,
    required this.at,
  });

  factory ChatOrganizationHistoryEntry.fromJson(Map<String, dynamic> json) =>
      ChatOrganizationHistoryEntry(
        action: json['action']?.toString() ?? 'change',
        chatId: json['chat_id']?.toString() ?? '',
        at: json['at'] is num
            ? (json['at'] as num).toInt()
            : int.tryParse('${json['at']}') ?? 0,
      );

  Map<String, dynamic> toJson() => {
    'action': action,
    'chat_id': chatId,
    'at': at,
  };
}

class ChatOrganizationTemplate {
  final String mode;
  final Set<String> types;

  const ChatOrganizationTemplate({required this.mode, required this.types});

  factory ChatOrganizationTemplate.fromJson(Map<String, dynamic> json) =>
      ChatOrganizationTemplate(
        mode: json['mode']?.toString() == 'all_except'
            ? 'all_except'
            : 'selected',
        types: (json['types'] as List? ?? const []).whereType<String>().toSet(),
      );

  Map<String, dynamic> toJson() => {'mode': mode, 'types': types.toList()};
}

class ChatOrganizationStore {
  ChatOrganizationStore._() {
    AppSecurityStore.instance.revision.addListener(_onSecurityChanged);
  }
  static final ChatOrganizationStore instance = ChatOrganizationStore._();

  final ValueNotifier<int> revision = ValueNotifier(0);
  final ValueNotifier<String> activeFolder = ValueNotifier('main');
  final List<ChatOrganizationFolder> _folders = [];
  final Set<String> _archived = {};
  final Set<String> _mainHidden = {};
  final Map<String, int> _archivedAt = {};
  final Map<String, int> _activityAt = {};
  final Map<String, List<ChatOrganizationHistoryEntry>> _history = {};
  final Map<String, ChatOrganizationTemplate> _templates = {};
  final Map<String, List<String>> _manualOrder = {};
  String _storageKey = 'chat_organization_v2_guest';
  bool _loaded = false;
  String chatSortMode = 'activity';
  bool archiveAutoDelete = true;
  int? archiveRetentionDays = 5;
  String archiveAnchor = 'archived_at';
  String archiveDeleteMode = 'local';

  List<ChatOrganizationFolder> get folders => visibleFolders;
  List<ChatOrganizationFolder> get visibleFolders =>
      _folders.where(_canSeeFolder).toList(growable: false);
  Set<String> get secureChatIds => _folders
      .where((folder) => _securityScopesForFolder(folder).isNotEmpty)
      .expand((folder) => folder.chatIds)
      .toSet();
  Set<String> get archived => Set.unmodifiable(_archived);
  Set<String> get mainHidden => Set.unmodifiable(_mainHidden);
  ChatOrganizationTemplate? templateFor(String folderId) =>
      visibleFolders.any((folder) => folder.id == folderId)
      ? _templates[folderId]
      : null;

  ChatOrganizationFolder? _folderById(String? id) {
    if (id == null) return null;
    for (final folder in _folders) {
      if (folder.id == id) return folder;
    }
    return null;
  }

  Set<String> _securityScopesForFolder(ChatOrganizationFolder folder) {
    final scopes = <String>{};
    final visited = <String>{};
    ChatOrganizationFolder? current = folder;
    while (current != null) {
      if (!visited.add(current.id)) {
        scopes.add('\u0000invalid_folder_cycle');
        break;
      }
      final scenarioId = current.securityScenarioId;
      if (scenarioId != null) scopes.add(scenarioId);
      final parentId = current.parentId;
      if (parentId == null) {
        current = null;
      } else {
        current = _folderById(parentId);
        if (current == null) scopes.add('\u0000missing_folder_parent');
      }
    }
    return scopes;
  }

  bool _canSeeFolder(ChatOrganizationFolder folder) => _securityScopesForFolder(
    folder,
  ).every(AppSecurityStore.instance.canSeeSecureFolder);

  bool canSeeChatInActiveScenario(String chatId) {
    final key = chatId.trim().toLowerCase();
    final secureFolders = _folders.where((folder) {
      return _securityScopesForFolder(folder).isNotEmpty &&
          folder.chatIds.any((id) => id.trim().toLowerCase() == key);
    });
    return secureFolders.isEmpty || secureFolders.any(_canSeeFolder);
  }

  bool isChatProtected(String chatId) {
    final key = chatId.trim().toLowerCase();
    return _folders.any(
      (folder) =>
          _securityScopesForFolder(folder).isNotEmpty &&
          folder.chatIds.any((id) => id.trim().toLowerCase() == key),
    );
  }

  void _onSecurityChanged() {
    final selected = activeFolder.value;
    if (selected != 'main' &&
        selected != 'archive' &&
        !visibleFolders.any((folder) => folder.id == selected)) {
      activeFolder.value = 'main';
    }
    _refreshLogPrivacy();
    revision.value++;
  }

  void _refreshLogPrivacy() {
    final hiddenChatIds = <String>{};
    for (final folder in _folders) {
      if (_securityScopesForFolder(folder).isEmpty) continue;
      for (final chatId in folder.chatIds) {
        if (!canSeeChatInActiveScenario(chatId)) hiddenChatIds.add(chatId);
      }
    }
    appLog.sensitiveValues = hiddenChatIds;
  }

  Future<void> load({String? account}) async {
    final normalized = (account ?? 'guest').trim().toLowerCase();
    final key =
        'chat_organization_v2_${normalized.isEmpty ? 'guest' : normalized}';
    if (_loaded && key == _storageKey) return;
    _storageKey = key;
    _loaded = true;
    _folders.clear();
    _archived.clear();
    _mainHidden.clear();
    _archivedAt.clear();
    _activityAt.clear();
    _history.clear();
    _templates.clear();
    _manualOrder.clear();
    chatSortMode = 'activity';
    archiveAutoDelete = true;
    archiveRetentionDays = 5;
    archiveAnchor = 'archived_at';
    archiveDeleteMode = 'local';
    activeFolder.value = 'main';
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_storageKey);
      if (raw != null && raw.isNotEmpty) {
        final json = jsonDecode(raw);
        if (json is Map) {
          final rawFolders = json['folders'];
          if (rawFolders is List) {
            _folders.addAll(
              rawFolders
                  .whereType<Map>()
                  .map(
                    (item) => ChatOrganizationFolder.fromJson(
                      Map<String, dynamic>.from(item),
                    ),
                  )
                  .where(
                    (folder) => folder.id.isNotEmpty && folder.name.isNotEmpty,
                  ),
            );
          }
          _archived.addAll(
            (json['archived'] as List? ?? const []).whereType<String>(),
          );
          _mainHidden.addAll(
            (json['main_hidden'] as List? ?? const []).whereType<String>(),
          );
          final rawHistory = json['history'];
          if (rawHistory is Map) {
            for (final entry in rawHistory.entries) {
              final rows = entry.value;
              if (rows is! List) continue;
              _history[entry.key.toString()] = rows
                  .whereType<Map>()
                  .map(
                    (item) => ChatOrganizationHistoryEntry.fromJson(
                      Map<String, dynamic>.from(item),
                    ),
                  )
                  .where((item) => item.chatId.isNotEmpty)
                  .take(100)
                  .toList();
            }
          }
          final rawArchivedAt = json['archived_at'];
          if (rawArchivedAt is Map) {
            for (final entry in rawArchivedAt.entries) {
              final value = entry.value;
              final timestamp = value is num
                  ? value.toInt()
                  : int.tryParse('$value');
              if (timestamp != null && timestamp > 0) {
                _archivedAt[entry.key.toString()] = timestamp;
              }
            }
          }
          final rawActivityAt = json['activity_at'];
          if (rawActivityAt is Map) {
            for (final entry in rawActivityAt.entries) {
              final value = entry.value;
              final timestamp = value is num
                  ? value.toInt()
                  : int.tryParse('$value');
              if (timestamp != null && timestamp > 0) {
                _activityAt[entry.key.toString()] = timestamp;
              }
            }
          }
          final rawTemplates = json['templates'];
          if (rawTemplates is Map) {
            for (final entry in rawTemplates.entries) {
              if (entry.value is Map) {
                _templates[entry.key
                    .toString()] = ChatOrganizationTemplate.fromJson(
                  Map<String, dynamic>.from(entry.value as Map),
                );
              }
            }
          }
          final rawManualOrder = json['manual_order'];
          if (rawManualOrder is Map) {
            for (final entry in rawManualOrder.entries) {
              if (entry.value is List) {
                _manualOrder[entry.key.toString()] = (entry.value as List)
                    .whereType<String>()
                    .toList();
              }
            }
          }
          chatSortMode = json['chat_sort_mode']?.toString() == 'manual'
              ? 'manual'
              : 'activity';
          archiveAutoDelete = json['archive_auto_delete'] != false;
          final rawDays = json['archive_retention_days'];
          archiveRetentionDays = rawDays == null
              ? null
              : (rawDays is num ? rawDays.toInt() : int.tryParse('$rawDays'));
          archiveAnchor = json['archive_anchor']?.toString() == 'activity'
              ? 'activity'
              : 'archived_at';
          archiveDeleteMode =
              json['archive_delete_mode']?.toString() == 'contact'
              ? 'contact'
              : 'local';
          final selected = json['active_folder']?.toString();
          if (selected == 'main' ||
              selected == 'archive' ||
              visibleFolders.any((folder) => folder.id == selected)) {
            activeFolder.value = selected!;
          }
        }
      }
      _refreshLogPrivacy();
      revision.value++;
    } catch (_) {
      // Optional local organization data must never block the chat list.
    }
  }

  bool isArchived(String chatId) => _archived.contains(chatId);

  List<String> manualOrderFor(String viewId) =>
      List.unmodifiable(_manualOrder[viewId] ?? const <String>[]);

  Future<void> setChatSortMode(String mode) async {
    final normalized = mode == 'manual' ? 'manual' : 'activity';
    if (chatSortMode == normalized) return;
    chatSortMode = normalized;
    revision.value++;
    await _save();
  }

  Future<void> setManualOrder(String viewId, List<String> order) async {
    _manualOrder[viewId] = List<String>.of(order);
    revision.value++;
    await _save();
  }

  bool isMainHidden(String chatId) => _mainHidden.contains(chatId);

  bool hasCustomFolder(String chatId) =>
      visibleFolders.any((folder) => folder.chatIds.contains(chatId));

  List<ChatOrganizationHistoryEntry> historyFor(String folderId) =>
      visibleFolders.any((folder) => folder.id == folderId)
      ? List.unmodifiable(_history[folderId] ?? const [])
      : const [];

  bool matchesTemplate(String folderId, String chatId, {bool isBot = false}) {
    final template = _templates[folderId];
    if (template == null || template.types.isEmpty) return false;
    final type = isBot ? 'bot' : _chatType(chatId);
    final selected = template.types.contains(type);
    return template.mode == 'all_except' ? !selected : selected;
  }

  String _chatType(String chatId) {
    if (chatId.startsWith('room:channel:')) return 'channel';
    if (chatId.startsWith('room:group:')) return 'group';
    if (chatId.startsWith('bm:')) return 'bookmark';
    if (chatId.startsWith('lan:')) return 'lan';
    return 'dm';
  }

  bool contains(String folderId, String chatId) => visibleFolders
      .where((folder) => folder.id == folderId)
      .any((folder) => folder.chatIds.contains(chatId));

  Future<void> select(String folderId) async {
    if (folderId != 'main' &&
        folderId != 'archive' &&
        !visibleFolders.any((folder) => folder.id == folderId)) {
      return;
    }
    activeFolder.value = folderId;
    revision.value++;
    await _save();
  }

  Future<String?> createFolder(
    String name, {
    String? parentId,
    String? securityScenarioId,
  }) async {
    final normalized = name.trim();
    if (normalized.isEmpty || _folders.length >= 50) return null;
    if (_depth(parentId) >= 5) return null;
    final parent = _folderById(parentId);
    if (parentId != null && (parent == null || !_canSeeFolder(parent))) {
      return null;
    }
    final activeScenarioId = AppSecurityStore.instance.activeScenarioId;
    if (activeScenarioId == null && securityScenarioId != null) return null;
    if (activeScenarioId != null &&
        securityScenarioId != null &&
        securityScenarioId != activeScenarioId) {
      return null;
    }
    var assignedScenarioId = activeScenarioId ?? securityScenarioId;
    if (parent != null) {
      final parentScopes = _securityScopesForFolder(parent);
      if (parentScopes.isNotEmpty) {
        if (securityScenarioId != null &&
            !parentScopes.contains(securityScenarioId)) {
          return null;
        }
        assignedScenarioId = parent.securityScenarioId ?? parentScopes.first;
      }
    }
    if (assignedScenarioId != null &&
        AppSecurityStore.instance.scenarioById(assignedScenarioId) == null) {
      return null;
    }
    final id = 'folder_${DateTime.now().microsecondsSinceEpoch}';
    _folders.add(
      ChatOrganizationFolder(
        id: id,
        name: normalized,
        parentId: parentId,
        securityScenarioId: assignedScenarioId,
      ),
    );
    revision.value++;
    await _save();
    return id;
  }

  Future<void> renameFolder(String id, String name) async {
    final normalized = name.trim();
    if (normalized.isEmpty) return;
    final index = _folders.indexWhere((folder) => folder.id == id);
    if (index < 0) return;
    _folders[index] = _folders[index].copyWith(name: normalized);
    revision.value++;
    await _save();
  }

  Future<void> deleteFolder(String id) async {
    final descendants = <String>{id};
    var changed = true;
    while (changed) {
      changed = false;
      for (final folder in _folders) {
        if (folder.parentId != null && descendants.contains(folder.parentId)) {
          changed = descendants.add(folder.id) || changed;
        }
      }
    }
    _folders.removeWhere((folder) => descendants.contains(folder.id));
    for (final folderId in descendants) {
      _history.remove(folderId);
      _templates.remove(folderId);
    }
    if (descendants.contains(activeFolder.value)) activeFolder.value = 'main';
    revision.value++;
    await _save();
  }

  Future<void> setArchived(String chatId, bool value) async {
    if (value) {
      _archived.add(chatId);
      _archivedAt[chatId] = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    } else {
      _archived.remove(chatId);
      _archivedAt.remove(chatId);
    }
    _recordHistory('archive', chatId, value ? 'archived' : 'restored');
    revision.value++;
    await _save();
  }

  /// Remembers the latest known local/server activity for archive expiry.
  /// This is deliberately best-effort: it never blocks rendering the list.
  Future<void> noteActivity(String chatId, int seconds) async {
    if (seconds <= 0 || _activityAt[chatId] == seconds) return;
    _activityAt[chatId] = seconds;
    if (archiveAnchor == 'activity' && _archived.contains(chatId)) {
      await _save();
    }
  }

  Future<void> setArchivePolicy({
    required bool autoDelete,
    required int? retentionDays,
    required String anchor,
    required String deleteMode,
  }) async {
    archiveAutoDelete = autoDelete;
    archiveRetentionDays = retentionDays;
    archiveAnchor = anchor == 'activity' ? 'activity' : 'archived_at';
    archiveDeleteMode = deleteMode == 'contact' ? 'contact' : 'local';
    revision.value++;
    await _save();
  }

  Future<List<String>> expireArchived({
    int? nowSeconds,
    bool Function(String chatId)? canExpire,
  }) async {
    final expired = expiredArchivedChatIds(
      nowSeconds: nowSeconds,
      canExpire: canExpire,
    );
    if (expired.isEmpty) return const [];
    for (final chatId in expired) {
      _archived.remove(chatId);
      _archivedAt.remove(chatId);
      _activityAt.remove(chatId);
      _mainHidden.remove(chatId);
      for (var index = 0; index < _folders.length; index++) {
        final folder = _folders[index];
        if (!folder.chatIds.contains(chatId)) continue;
        _folders[index] = folder.copyWith(
          chatIds: {...folder.chatIds}..remove(chatId),
        );
      }
      _recordHistory('archive', chatId, 'expired');
    }
    revision.value++;
    await _save();
    return expired;
  }

  List<String> expiredArchivedChatIds({
    int? nowSeconds,
    bool Function(String chatId)? canExpire,
  }) {
    if (!archiveAutoDelete || archiveRetentionDays == null) return const [];
    final now = nowSeconds ?? DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final threshold = now - archiveRetentionDays! * 24 * 60 * 60;
    return _archived
        .where((chatId) {
          if (canExpire != null && !canExpire(chatId)) return false;
          final anchor = archiveAnchor == 'activity'
              ? (_activityAt[chatId] ?? _archivedAt[chatId])
              : _archivedAt[chatId];
          return (anchor ?? now) <= threshold;
        })
        .toList(growable: false);
  }

  Future<void> setInFolder(String folderId, String chatId, bool value) async {
    final index = _folders.indexWhere((folder) => folder.id == folderId);
    if (index < 0) return;
    final folder = _folders[index];
    if (!_canSeeFolder(folder)) return;
    final ids = {..._folders[index].chatIds};
    if (value) {
      ids.add(chatId);
    } else {
      ids.remove(chatId);
      if (ids.isEmpty && isMainHidden(chatId)) return;
    }
    _folders[index] = _folders[index].copyWith(chatIds: ids);
    final folderIsSecure = _securityScopesForFolder(folder).isNotEmpty;
    if (value && folderIsSecure) {
      _mainHidden.add(chatId);
    } else if (!value && folderIsSecure) {
      final remainsSecure = _folders.any(
        (item) =>
            item.id != folderId &&
            _securityScopesForFolder(item).isNotEmpty &&
            item.chatIds.contains(chatId),
      );
      if (!remainsSecure) _mainHidden.remove(chatId);
    }
    _recordHistory(folderId, chatId, value ? 'added' : 'removed');
    revision.value++;
    await _save();
  }

  Future<void> removeFoldersForSecurityScenarios(
    Set<String> scenarioIds,
  ) async {
    if (scenarioIds.isEmpty) return;
    final removed = _folders
        .where(
          (folder) =>
              _securityScopesForFolder(folder).any(scenarioIds.contains),
        )
        .map((folder) => folder.id)
        .toSet();
    var changed = true;
    while (changed) {
      changed = false;
      for (final folder in _folders) {
        if (folder.parentId != null && removed.contains(folder.parentId)) {
          changed = removed.add(folder.id) || changed;
        }
      }
    }
    if (removed.isEmpty) return;
    final affectedChats = _folders
        .where((folder) => removed.contains(folder.id))
        .expand((folder) => folder.chatIds)
        .toSet();
    _folders.removeWhere((folder) => removed.contains(folder.id));
    for (final chatId in affectedChats) {
      final remainsSecure = _folders.any(
        (folder) =>
            _securityScopesForFolder(folder).isNotEmpty &&
            folder.chatIds.contains(chatId),
      );
      if (!remainsSecure) _mainHidden.remove(chatId);
    }
    for (final folderId in removed) {
      _history.remove(folderId);
      _templates.remove(folderId);
    }
    if (removed.contains(activeFolder.value)) activeFolder.value = 'main';
    revision.value++;
    await _save();
  }

  Future<bool> setMainHidden(String chatId, bool value) async {
    if (value && !hasCustomFolder(chatId)) return false;
    if (value) {
      _mainHidden.add(chatId);
    } else {
      _mainHidden.remove(chatId);
    }
    _recordHistory('main', chatId, value ? 'hidden' : 'shown');
    revision.value++;
    await _save();
    return true;
  }

  Future<void> setTemplate(
    String folderId, {
    required String mode,
    required Set<String> types,
  }) async {
    if (!_folders.any((folder) => folder.id == folderId)) return;
    final normalized = types
        .where(
          (type) => {
            'dm',
            'group',
            'channel',
            'bot',
            'bookmark',
            'lan',
          }.contains(type),
        )
        .toSet();
    if (normalized.isEmpty) {
      _templates.remove(folderId);
    } else {
      _templates[folderId] = ChatOrganizationTemplate(
        mode: mode == 'all_except' ? 'all_except' : 'selected',
        types: normalized,
      );
    }
    revision.value++;
    await _save();
  }

  void _recordHistory(String folderId, String chatId, String action) {
    final entries = _history.putIfAbsent(
      folderId,
      () => <ChatOrganizationHistoryEntry>[],
    );
    entries.insert(
      0,
      ChatOrganizationHistoryEntry(
        action: action,
        chatId: chatId,
        at: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      ),
    );
    if (entries.length > 100) entries.removeRange(100, entries.length);
  }

  int _depth(String? parentId) {
    var depth = 0;
    var current = parentId;
    final seen = <String>{};
    while (current != null && seen.add(current)) {
      depth++;
      String? next;
      for (final folder in _folders) {
        if (folder.id == current) {
          next = folder.parentId;
          break;
        }
      }
      current = next;
    }
    return depth;
  }

  Future<void> _save() async {
    _refreshLogPrivacy();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _storageKey,
        jsonEncode({
          'folders': _folders.map((folder) => folder.toJson()).toList(),
          'archived': _archived.toList(),
          'main_hidden': _mainHidden.toList(),
          'archived_at': _archivedAt,
          'activity_at': _activityAt,
          'history': _history.map(
            (key, value) =>
                MapEntry(key, value.map((item) => item.toJson()).toList()),
          ),
          'templates': _templates.map(
            (key, value) => MapEntry(key, value.toJson()),
          ),
          'chat_sort_mode': chatSortMode,
          'manual_order': _manualOrder,
          'archive_auto_delete': archiveAutoDelete,
          'archive_retention_days': archiveRetentionDays,
          'archive_anchor': archiveAnchor,
          'archive_delete_mode': archiveDeleteMode,
          'active_folder': activeFolder.value,
        }),
      );
    } catch (_) {
      // The feature is local-only; a storage hiccup must not break navigation.
    }
  }
}
