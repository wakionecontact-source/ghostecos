import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'api_client.dart';
import 'auth_service.dart';

class GhostContact {
  final String username;
  final String displayName;
  final String? avatarUrl;
  final String? addedAt;

  const GhostContact({
    required this.username,
    required this.displayName,
    this.avatarUrl,
    this.addedAt,
  });

  factory GhostContact.fromJson(Map<String, dynamic> json) {
    final username = (json['username'] ?? '').toString().trim();
    final displayName = (json['display_name'] ?? username).toString().trim();
    return GhostContact(
      username: username,
      displayName: displayName.isEmpty ? username : displayName,
      avatarUrl: json['avatar_url']?.toString(),
      addedAt: json['added_at']?.toString(),
    );
  }

  GhostContact copyWith({
    String? username,
    String? displayName,
    String? avatarUrl,
    String? addedAt,
  }) => GhostContact(
    username: username ?? this.username,
    displayName: displayName ?? this.displayName,
    avatarUrl: avatarUrl ?? this.avatarUrl,
    addedAt: addedAt ?? this.addedAt,
  );
}

abstract interface class ContactApi {
  Future<dynamic> get(String path);
  Future<dynamic> post(String path);
  Future<dynamic> delete(String path);
}

class ContactService {
  ContactService({ContactApi? api}) : _api = api ?? _ApiContactApi();

  static final ContactService instance = ContactService();
  final ContactApi _api;

  static const _cachePrefix = 'ghostchat_contacts_cache_v2_';
  static const _outboxPrefix = 'ghostchat_contacts_outbox_v2_';
  final Map<String, GhostContact> _memory = {};
  final List<Map<String, dynamic>> _outbox = [];
  bool _loaded = false;
  String? _accountKey;

  List<GhostContact> get cached => _sorted(_memory.values);

  Future<String> _key() async {
    final username = await AuthService.username();
    final normalized = username?.trim().toLowerCase();
    return normalized == null || normalized.isEmpty ? 'anonymous' : normalized;
  }

  String _cacheKey(String account) => '$_cachePrefix$account';
  String _outboxKey(String account) => '$_outboxPrefix$account';

  Future<void> _loadLocal() async {
    final account = await _key();
    if (_loaded && _accountKey == account) return;
    // The singleton survives account switching. Never expose the previous
    // account's contacts while the new account is being hydrated.
    _accountKey = account;
    _loaded = true;
    _memory.clear();
    _outbox.clear();
    final prefs = await SharedPreferences.getInstance();
    final rawContacts = prefs.getString(_cacheKey(account));
    if (rawContacts != null) {
      try {
        final decoded = jsonDecode(rawContacts);
        if (decoded is List) {
          for (final item in decoded.whereType<Map>()) {
            final contact = GhostContact.fromJson(
              Map<String, dynamic>.from(item),
            );
            if (contact.username.isNotEmpty) {
              _memory[contact.username.toLowerCase()] = contact;
            }
          }
        }
      } catch (_) {
        // A damaged cache must not prevent a fresh server refresh.
      }
    }
    final rawOutbox = prefs.getString(_outboxKey(account));
    if (rawOutbox != null) {
      try {
        final decoded = jsonDecode(rawOutbox);
        if (decoded is List) {
          _outbox
            ..clear()
            ..addAll(
              decoded.whereType<Map>().map(
                (item) => Map<String, dynamic>.from(item),
              ),
            );
        }
      } catch (_) {}
    }
    _applyPendingToMemory();
  }

  Future<void> _persist() async {
    final account = await _key();
    final prefs = await SharedPreferences.getInstance();
    await Future.wait([
      prefs.setString(
        _cacheKey(account),
        jsonEncode(_sorted(_memory.values).map(_contactJson).toList()),
      ),
      prefs.setString(_outboxKey(account), jsonEncode(_outbox)),
    ]);
  }

  Map<String, dynamic> _contactJson(GhostContact contact) => {
    'username': contact.username,
    'display_name': contact.displayName,
    if (contact.avatarUrl != null) 'avatar_url': contact.avatarUrl,
    if (contact.addedAt != null) 'added_at': contact.addedAt,
  };

  List<GhostContact> _sorted(Iterable<GhostContact> contacts) =>
      contacts.where((contact) => contact.username.trim().isNotEmpty).toList()
        ..sort(
          (a, b) => a.displayName.toLowerCase().compareTo(
            b.displayName.toLowerCase(),
          ),
        );

  void _applyPendingToMemory() {
    for (final operation in _outbox) {
      final username = operation['username']?.toString().toLowerCase() ?? '';
      if (username.isEmpty) continue;
      if (operation['action'] == 'remove') {
        _memory.remove(username);
      } else if (operation['contact'] is Map) {
        _memory[username] = GhostContact.fromJson(
          Map<String, dynamic>.from(operation['contact'] as Map),
        );
      }
    }
  }

  /// Returns the locally persisted list without waiting for the network.
  Future<List<GhostContact>> loadCached() async {
    await _loadLocal();
    return cached;
  }

  Future<List<GhostContact>> _fetchRemote() async {
    final raw = await _api.get('/contacts');
    final rows = raw is List
        ? raw
        : raw is Map && raw['contacts'] is List
        ? raw['contacts'] as List
        : const <dynamic>[];
    return rows
        .whereType<Map>()
        .map((row) => GhostContact.fromJson(Map<String, dynamic>.from(row)))
        .where((contact) => contact.username.isNotEmpty)
        .toList(growable: false);
  }

  Future<List<GhostContact>> list() async {
    await _loadLocal();
    await _drainOutbox();
    try {
      final remote = await _fetchRemote();
      _memory
        ..clear()
        ..addEntries(
          remote.map(
            (contact) => MapEntry(contact.username.toLowerCase(), contact),
          ),
        );
      _applyPendingToMemory();
      await _persist();
    } catch (_) {
      // Offline is a normal state here: the caller receives the local list.
    }
    return cached;
  }

  Future<GhostContact> add({
    required String username,
    String? displayName,
    String? avatarUrl,
    bool isBot = false,
  }) async {
    final normalized = username.trim().replaceFirst(RegExp(r'^@'), '');
    if (normalized.isEmpty) throw ArgumentError.value(username, 'username');
    if (isBot) {
      throw StateError('Ботов нельзя добавлять в контакты');
    }
    await _loadLocal();
    final local = GhostContact(
      username: normalized,
      displayName: displayName?.trim().isNotEmpty == true
          ? displayName!.trim()
          : normalized,
      avatarUrl: avatarUrl,
    );
    _memory[normalized.toLowerCase()] = local;
    await _persist();
    try {
      final raw = await _api.post(
        '/contacts/${Uri.encodeComponent(normalized)}',
      );
      final response = raw is Map
          ? Map<String, dynamic>.from(raw)
          : <String, dynamic>{};
      final saved = GhostContact.fromJson({
        ...response,
        'username': response['username'] ?? normalized,
        'display_name': response['display_name'] ?? local.displayName,
        'avatar_url': response['avatar_url'] ?? local.avatarUrl,
      });
      _memory[normalized.toLowerCase()] = saved;
      _removePending('add', normalized);
      await _persist();
      return saved;
    } catch (_) {
      _outbox.add({
        'action': 'add',
        'username': normalized,
        'contact': _contactJson(local),
      });
      await _persist();
      return local;
    }
  }

  Future<void> remove(String username) async {
    final normalized = username.trim().replaceFirst(RegExp(r'^@'), '');
    if (normalized.isEmpty) throw ArgumentError.value(username, 'username');
    await _loadLocal();
    _memory.remove(normalized.toLowerCase());
    await _persist();
    try {
      await _api.delete('/contacts/${Uri.encodeComponent(normalized)}');
      _removePending('remove', normalized);
      await _persist();
    } catch (_) {
      _outbox.add({'action': 'remove', 'username': normalized});
      await _persist();
    }
  }

  void _removePending(String action, String username) {
    final normalized = username.toLowerCase();
    _outbox.removeWhere(
      (operation) =>
          operation['action'] == action &&
          operation['username']?.toString().toLowerCase() == normalized,
    );
  }

  Future<void> _drainOutbox() async {
    if (_outbox.isEmpty) return;
    while (_outbox.isNotEmpty) {
      final operation = Map<String, dynamic>.from(_outbox.first);
      final username = operation['username']?.toString() ?? '';
      if (username.isEmpty) {
        _outbox.removeAt(0);
        continue;
      }
      try {
        if (operation['action'] == 'remove') {
          await _api.delete('/contacts/${Uri.encodeComponent(username)}');
        } else {
          await _api.post('/contacts/${Uri.encodeComponent(username)}');
        }
        _outbox.removeAt(0);
        await _persist();
      } catch (_) {
        // Preserve order. A later remove must not overtake a failed add.
        break;
      }
    }
  }
}

class _ApiContactApi implements ContactApi {
  final ApiClient _client = ApiClient();

  @override
  Future<dynamic> get(String path) => _client.chatGet(path);

  @override
  Future<dynamic> post(String path) => _client.chatPost(path);

  @override
  Future<dynamic> delete(String path) => _client.chatDelete(path);
}
