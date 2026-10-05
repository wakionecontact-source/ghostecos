import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Device-local security state for the app and its hidden chat spaces.
///
/// Only salted SHA-256 digests are persisted.  This is deliberately separate
/// from account/E2EE passwords: these codes unlock local UI state and never go
/// to the server.  The primary code is required before a safe environment can
/// be created.
class SecurityScenario {
  final String id;
  final String name;
  final String salt;
  final String digest;
  final String? parentId;

  const SecurityScenario({
    required this.id,
    required this.name,
    required this.salt,
    required this.digest,
    this.parentId,
  });

  SecurityScenario copyWith({String? name}) => SecurityScenario(
    id: id,
    name: name ?? this.name,
    salt: salt,
    digest: digest,
    parentId: parentId,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'salt': salt,
    'digest': digest,
    'parent_id': parentId,
  };

  factory SecurityScenario.fromJson(Map<String, dynamic> json) =>
      SecurityScenario(
        id: json['id']?.toString() ?? '',
        name: json['name']?.toString() ?? '',
        salt: json['salt']?.toString() ?? '',
        digest: json['digest']?.toString() ?? '',
        parentId: json['parent_id']?.toString(),
      );
}

enum SecurityUnlockMode { normal, scenario, wrong }

class SecurityUnlockResult {
  final SecurityUnlockMode mode;
  final String? scenarioId;

  const SecurityUnlockResult._(this.mode, [this.scenarioId]);

  const SecurityUnlockResult.normal() : this._(SecurityUnlockMode.normal);
  const SecurityUnlockResult.scenario(String id)
    : this._(SecurityUnlockMode.scenario, id);
  const SecurityUnlockResult.wrong() : this._(SecurityUnlockMode.wrong);
}

class AppSecurityStore {
  AppSecurityStore._();
  static final AppSecurityStore instance = AppSecurityStore._();

  static const _storageKey = 'ghostchat_app_security_v2';
  static final Random _random = Random.secure();

  final ValueNotifier<int> revision = ValueNotifier(0);
  final List<SecurityScenario> _scenarios = [];
  String? _primarySalt;
  String? _primaryDigest;
  String? _activeScenarioId;
  bool _loaded = false;

  bool get isLoaded => _loaded;
  bool get hasPrimaryCode => _primaryDigest != null && _primarySalt != null;
  bool get isInSafeMode => _activeScenarioId != null;
  String? get activeScenarioId => _activeScenarioId;
  List<SecurityScenario> get scenarios => List.unmodifiable(_scenarios);

  SecurityScenario? scenarioById(String id) {
    for (final scenario in _scenarios) {
      if (scenario.id == id) return scenario;
    }
    return null;
  }

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_storageKey);
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          _primarySalt = decoded['primary_salt']?.toString();
          _primaryDigest = decoded['primary_digest']?.toString();
          final rawScenarios = decoded['scenarios'];
          if (rawScenarios is List) {
            _scenarios.addAll(
              rawScenarios
                  .whereType<Map>()
                  .map(
                    (item) => SecurityScenario.fromJson(
                      Map<String, dynamic>.from(item),
                    ),
                  )
                  .where(
                    (item) =>
                        item.id.isNotEmpty &&
                        item.name.isNotEmpty &&
                        item.salt.isNotEmpty &&
                        item.digest.isNotEmpty,
                  ),
            );
          }
        }
      }
    } catch (_) {
      // Corrupt optional local security data must fail closed, not crash boot.
      _primarySalt = null;
      _primaryDigest = null;
      _scenarios.clear();
    }
    revision.value++;
  }

  Future<void> setPrimaryCode(String code) async {
    final normalized = code.trim();
    if (normalized.length < 4) {
      throw ArgumentError('Код должен содержать минимум 4 символа');
    }
    final salt = _newSalt();
    _primarySalt = salt;
    _primaryDigest = await _digest(salt, normalized);
    _activeScenarioId = null;
    revision.value++;
    await _save();
  }

  Future<void> clearPrimaryCode() async {
    _primarySalt = null;
    _primaryDigest = null;
    _activeScenarioId = null;
    _scenarios.clear();
    revision.value++;
    await _save();
  }

  Future<SecurityScenario?> createScenario(
    String name,
    String code, {
    String? parentId,
  }) async {
    if (!hasPrimaryCode) return null;
    final normalizedName = name.trim();
    final normalizedCode = code.trim();
    if (normalizedName.isEmpty || normalizedCode.length < 4) return null;
    if (parentId != null && scenarioById(parentId) == null) return null;
    final salt = _newSalt();
    final scenario = SecurityScenario(
      id: 'safe_${DateTime.now().microsecondsSinceEpoch}',
      name: normalizedName,
      salt: salt,
      digest: await _digest(salt, normalizedCode),
      parentId: parentId,
    );
    _scenarios.add(scenario);
    revision.value++;
    await _save();
    return scenario;
  }

  Future<void> renameScenario(String id, String name) async {
    final index = _scenarios.indexWhere((item) => item.id == id);
    final normalized = name.trim();
    if (index < 0 || normalized.isEmpty) return;
    _scenarios[index] = _scenarios[index].copyWith(name: normalized);
    revision.value++;
    await _save();
  }

  Future<void> removeScenario(String id) async {
    final removed = <String>{id};
    var changed = true;
    while (changed) {
      changed = false;
      for (final scenario in _scenarios) {
        if (scenario.parentId != null && removed.contains(scenario.parentId)) {
          changed = removed.add(scenario.id) || changed;
        }
      }
    }
    _scenarios.removeWhere((item) => removed.contains(item.id));
    if (_activeScenarioId != null && removed.contains(_activeScenarioId)) {
      _activeScenarioId = null;
    }
    revision.value++;
    await _save();
  }

  Future<SecurityUnlockResult> unlock(String code) async {
    if (!hasPrimaryCode) return const SecurityUnlockResult.normal();
    final normalized = code.trim();
    if (_primarySalt != null &&
        _primaryDigest == await _digest(_primarySalt!, normalized)) {
      _activeScenarioId = null;
      revision.value++;
      return const SecurityUnlockResult.normal();
    }
    for (final scenario in List<SecurityScenario>.from(_scenarios.reversed)) {
      if (scenario.digest == await _digest(scenario.salt, normalized)) {
        _activeScenarioId = scenario.id;
        revision.value++;
        return SecurityUnlockResult.scenario(scenario.id);
      }
    }
    return const SecurityUnlockResult.wrong();
  }

  Future<Set<String>> leaveToNormal() async {
    final removed = _scenarios
        .where((scenario) => scenario.parentId != null)
        .map((scenario) => scenario.id)
        .toSet();
    if (removed.isNotEmpty) {
      _scenarios.removeWhere((scenario) => removed.contains(scenario.id));
    }
    if (_activeScenarioId != null || removed.isNotEmpty) {
      _activeScenarioId = null;
      revision.value++;
      await _save();
    }
    return removed;
  }

  bool canSeeSecureFolder(String? scenarioId) =>
      scenarioId == null || scenarioId == _activeScenarioId;

  String _newSalt() =>
      base64UrlEncode(List<int>.generate(16, (_) => _random.nextInt(256)));

  Future<String> _digest(String salt, String code) async {
    final bytes = await Sha256().hash(utf8.encode('$salt:$code'));
    return base64UrlEncode(bytes.bytes);
  }

  Future<void> _save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _storageKey,
        jsonEncode({
          'primary_salt': _primarySalt,
          'primary_digest': _primaryDigest,
          'scenarios': _scenarios.map((item) => item.toJson()).toList(),
        }),
      );
    } catch (_) {
      // Security preferences are best-effort to persist; the in-memory state
      // remains active for the current process.
    }
  }
}
