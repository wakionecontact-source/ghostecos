import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/local/app_logger.dart';

const _securityPbkdf2DigestPrefix = 'pbkdf2-sha256-v1:';

Future<String> _deriveSecurityCodeDigest(List<String> input) async {
  final key =
      await Pbkdf2(
        macAlgorithm: Hmac.sha256(),
        iterations: 260000,
        bits: 256,
      ).deriveKey(
        secretKey: SecretKey(utf8.encode(input[1])),
        nonce: base64Url.decode(input[0]),
      );
  return '$_securityPbkdf2DigestPrefix${base64UrlEncode(await key.extractBytes())}';
}

/// Device-local security state for the app and its hidden chat spaces.
///
/// Only salted PBKDF2 digests are persisted. This is deliberately separate
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
  final Set<String> removedScenarioIds;

  const SecurityUnlockResult._(
    this.mode, [
    this.scenarioId,
    this.removedScenarioIds = const <String>{},
  ]);

  const SecurityUnlockResult.normal({
    Set<String> removedScenarioIds = const <String>{},
  }) : this._(SecurityUnlockMode.normal, null, removedScenarioIds);
  const SecurityUnlockResult.scenario(String id)
    : this._(SecurityUnlockMode.scenario, id);
  const SecurityUnlockResult.wrong() : this._(SecurityUnlockMode.wrong);
}

class AppSecurityStore {
  AppSecurityStore._();
  static final AppSecurityStore instance = AppSecurityStore._();

  static const _storageKey = 'ghostchat_app_security_v2';
  static const _pbkdf2DigestPrefix = _securityPbkdf2DigestPrefix;
  static const maxScenarioDepth = 5;
  static const autoLockDelayOptionsSeconds = <int>[0, 15, 30, 60, 300, 600];
  static final Random _random = Random.secure();

  final ValueNotifier<int> revision = ValueNotifier(0);
  final List<SecurityScenario> _scenarios = [];
  String? _primarySalt;
  String? _primaryDigest;
  String? _activeScenarioId;
  int _autoLockDelaySeconds = 0;
  bool _biometricUnlockEnabled = false;
  bool _loaded = false;

  bool get isLoaded => _loaded;
  bool get hasPrimaryCode => _primaryDigest != null && _primarySalt != null;
  bool get isInSafeMode => _activeScenarioId != null;
  String? get activeScenarioId => _activeScenarioId;
  int get autoLockDelaySeconds => _autoLockDelaySeconds;
  bool get biometricUnlockEnabled => _biometricUnlockEnabled;
  List<SecurityScenario> get scenarios => List.unmodifiable(_scenarios);

  SecurityScenario? scenarioById(String id) {
    for (final scenario in _scenarios) {
      if (scenario.id == id) return scenario;
    }
    return null;
  }

  int scenarioDepth(String id) {
    var current = scenarioById(id);
    final visited = <String>{};
    var depth = 0;
    while (current != null) {
      if (!visited.add(current.id)) return maxScenarioDepth + 1;
      depth++;
      if (depth > maxScenarioDepth) return depth;
      final parentId = current.parentId;
      if (parentId == null) return depth;
      current = scenarioById(parentId);
    }
    return 0;
  }

  bool canCreateScenario({String? parentId}) {
    if (!hasPrimaryCode || parentId != _activeScenarioId) return false;
    if (parentId == null) return true;
    final parentDepth = scenarioDepth(parentId);
    return parentDepth > 0 && parentDepth < maxScenarioDepth;
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
          _biometricUnlockEnabled =
              decoded['biometric_unlock_enabled'] == true && hasPrimaryCode;
          final savedDelay = decoded['auto_lock_delay_seconds'];
          if (savedDelay is num &&
              autoLockDelayOptionsSeconds.contains(savedDelay.toInt())) {
            _autoLockDelaySeconds = savedDelay.toInt();
          }
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
    for (final scenario in _scenarios) {
      appLog.clearProtectedScope(scenario.id);
    }
    _primarySalt = null;
    _primaryDigest = null;
    _activeScenarioId = null;
    _biometricUnlockEnabled = false;
    _scenarios.clear();
    revision.value++;
    await _save();
  }

  Future<void> setAutoLockDelaySeconds(int seconds) async {
    if (!autoLockDelayOptionsSeconds.contains(seconds)) {
      throw ArgumentError.value(
        seconds,
        'seconds',
        'Unsupported auto-lock delay',
      );
    }
    if (_autoLockDelaySeconds == seconds) return;
    _autoLockDelaySeconds = seconds;
    revision.value++;
    await _save();
  }

  Future<void> setBiometricUnlockEnabled(bool enabled) async {
    if (enabled && !hasPrimaryCode) {
      throw StateError('Сначала установите основной код');
    }
    if (_biometricUnlockEnabled == enabled) return;
    _biometricUnlockEnabled = enabled;
    revision.value++;
    await _save();
  }

  Future<SecurityScenario?> createScenario(
    String name,
    String code, {
    String? parentId,
  }) async {
    if (!canCreateScenario(parentId: parentId)) return null;
    final normalizedName = name.trim();
    final normalizedCode = code.trim();
    if (normalizedName.isEmpty || normalizedCode.length < 4) return null;
    final salt = _newSalt();
    final scenario = SecurityScenario(
      id: 'safe_${DateTime.now().microsecondsSinceEpoch}_${_newSalt()}',
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
    for (final scenarioId in removed) {
      appLog.clearProtectedScope(scenarioId);
    }
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
        await _matches(_primarySalt!, _primaryDigest!, normalized)) {
      if (!_usesPbkdf2(_primaryDigest!)) {
        _primarySalt = _newSalt();
        _primaryDigest = await _digest(_primarySalt!, normalized);
        await _save();
      }
      final removedScenarioIds = await leaveToNormal();
      return SecurityUnlockResult.normal(
        removedScenarioIds: removedScenarioIds,
      );
    }
    for (final scenario in List<SecurityScenario>.from(_scenarios.reversed)) {
      // Nested codes are only valid while their parent environment is active.
      // This keeps a child code from opening that environment directly from
      // the ordinary mode or from an unrelated safe environment.
      if (scenario.parentId != _activeScenarioId) continue;
      if (await _matches(scenario.salt, scenario.digest, normalized)) {
        if (!_usesPbkdf2(scenario.digest)) {
          final salt = _newSalt();
          final index = _scenarios.indexWhere((item) => item.id == scenario.id);
          if (index >= 0) {
            _scenarios[index] = SecurityScenario(
              id: scenario.id,
              name: scenario.name,
              salt: salt,
              digest: await _digest(salt, normalized),
              parentId: scenario.parentId,
            );
            await _save();
          }
        }
        _activeScenarioId = scenario.id;
        revision.value++;
        return SecurityUnlockResult.scenario(scenario.id);
      }
    }
    return const SecurityUnlockResult.wrong();
  }

  Future<SecurityUnlockResult> unlockWithBiometrics() async {
    if (!_biometricUnlockEnabled || !hasPrimaryCode) {
      return const SecurityUnlockResult.wrong();
    }
    final removedScenarioIds = await leaveToNormal();
    return SecurityUnlockResult.normal(removedScenarioIds: removedScenarioIds);
  }

  Future<Set<String>> leaveToNormal() async {
    final activeId = _activeScenarioId;
    final active = activeId == null ? null : scenarioById(activeId);
    final removed = <String>{};
    if (active != null) {
      // A top-level environment survives leaving it; only its descendants
      // were created inside it. If the active environment is itself nested,
      // remove that environment and its descendants on exit to normal mode.
      if (active.parentId != null) removed.add(active.id);
      var parents = <String>{active.id};
      while (parents.isNotEmpty) {
        final next = <String>{};
        for (final scenario in _scenarios) {
          if (parents.contains(scenario.parentId) && removed.add(scenario.id)) {
            next.add(scenario.id);
          }
        }
        parents = next;
      }
    }
    if (removed.isNotEmpty) {
      _scenarios.removeWhere((scenario) => removed.contains(scenario.id));
      for (final scenarioId in removed) {
        appLog.clearProtectedScope(scenarioId);
      }
    }
    if (_activeScenarioId != null || removed.isNotEmpty) {
      _activeScenarioId = null;
      revision.value++;
      await _save();
    }
    return removed;
  }

  bool canSeeSecureFolder(String? scenarioId) {
    if (scenarioId == null) return true;
    var active = scenarioById(_activeScenarioId ?? '');
    final visited = <String>{};
    while (active != null && visited.add(active.id)) {
      if (active.id == scenarioId) return true;
      final parentId = active.parentId;
      active = parentId == null ? null : scenarioById(parentId);
    }
    return false;
  }

  String _newSalt() =>
      base64UrlEncode(List<int>.generate(16, (_) => _random.nextInt(256)));

  Future<bool> _matches(String salt, String digest, String code) async {
    final computed = _usesPbkdf2(digest)
        ? await _digest(salt, code)
        : await _legacyDigest(salt, code);
    return digest == computed;
  }

  bool _usesPbkdf2(String digest) => digest.startsWith(_pbkdf2DigestPrefix);

  Future<String> _digest(String salt, String code) async {
    return compute(_deriveSecurityCodeDigest, [salt, code]);
  }

  Future<String> _legacyDigest(String salt, String code) async {
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
          'auto_lock_delay_seconds': _autoLockDelaySeconds,
          'biometric_unlock_enabled': _biometricUnlockEnabled,
          'scenarios': _scenarios.map((item) => item.toJson()).toList(),
        }),
      );
    } catch (_) {
      // Security preferences are best-effort to persist; the in-memory state
      // remains active for the current process.
    }
  }
}
