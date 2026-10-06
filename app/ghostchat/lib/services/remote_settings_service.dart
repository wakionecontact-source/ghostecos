import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/api/http_client.dart';
import '../core/app_version.dart';
import '../core/local/app_logger.dart';

/// A setting schema delivered by GhostChat's own server. This is declarative
/// data only: the app never evaluates scripts, HTML, or downloaded code.
class RemoteSettingOption {
  final String value;
  final String label;

  const RemoteSettingOption({required this.value, required this.label});

  Map<String, dynamic> toJson() => {'value': value, 'label': label};

  static RemoteSettingOption parse(dynamic raw) {
    if (raw is! Map) throw const FormatException('option must be an object');
    final value = '${raw['value'] ?? ''}'.trim();
    final label = '${raw['label'] ?? ''}'.trim();
    if (value.isEmpty ||
        value.length > 80 ||
        label.isEmpty ||
        label.length > 80) {
      throw const FormatException('invalid setting option');
    }
    return RemoteSettingOption(value: value, label: label);
  }
}

class RemoteSettingDefinition {
  final String id;
  final String type;
  final String title;
  final String description;
  final Object? defaultValue;
  final List<RemoteSettingOption> options;
  final double minimum;
  final double maximum;
  final int maxLength;
  final int? divisions;

  const RemoteSettingDefinition({
    required this.id,
    required this.type,
    required this.title,
    required this.description,
    required this.defaultValue,
    this.options = const [],
    this.minimum = 0,
    this.maximum = 1,
    this.maxLength = 160,
    this.divisions,
  });

  factory RemoteSettingDefinition.parse(dynamic raw) {
    if (raw is! Map) throw const FormatException('setting must be an object');
    final id = '${raw['id'] ?? ''}'.trim();
    final type = '${raw['type'] ?? ''}'.trim();
    final title = '${raw['title'] ?? ''}'.trim();
    final description = '${raw['description'] ?? ''}'.trim();
    if (!_validId(id) ||
        title.isEmpty ||
        title.length > 100 ||
        description.length > 240) {
      throw const FormatException('invalid setting metadata');
    }

    switch (type) {
      case 'toggle':
        return RemoteSettingDefinition(
          id: id,
          type: type,
          title: title,
          description: description,
          defaultValue: raw['default'] is bool ? raw['default'] : false,
        );
      case 'select':
        final rawOptions = raw['options'];
        if (rawOptions is! List ||
            rawOptions.isEmpty ||
            rawOptions.length > 30) {
          throw const FormatException('select requires 1..30 options');
        }
        final options = rawOptions.map(RemoteSettingOption.parse).toList();
        if (options.map((option) => option.value).toSet().length !=
            options.length) {
          throw const FormatException('duplicate select option');
        }
        final requestedDefault = '${raw['default'] ?? options.first.value}';
        final defaultValue =
            options.any((option) => option.value == requestedDefault)
            ? requestedDefault
            : options.first.value;
        return RemoteSettingDefinition(
          id: id,
          type: type,
          title: title,
          description: description,
          defaultValue: defaultValue,
          options: List.unmodifiable(options),
        );
      case 'slider':
        final minimum = _finiteNumber(raw['min']);
        final maximum = _finiteNumber(raw['max']);
        final defaultValue = _finiteNumber(raw['default']);
        if (minimum == null ||
            maximum == null ||
            defaultValue == null ||
            minimum >= maximum ||
            minimum < -10000 ||
            maximum > 10000 ||
            defaultValue < minimum ||
            defaultValue > maximum) {
          throw const FormatException('invalid slider range');
        }
        final stepsRaw = raw['steps'];
        final steps = stepsRaw is int && stepsRaw >= 1 && stepsRaw <= 100
            ? stepsRaw
            : null;
        return RemoteSettingDefinition(
          id: id,
          type: type,
          title: title,
          description: description,
          defaultValue: defaultValue,
          minimum: minimum,
          maximum: maximum,
          divisions: steps,
        );
      case 'text':
        final requestedMax = raw['max_length'];
        final maxLength = requestedMax is int
            ? requestedMax.clamp(1, 512).toInt()
            : 160;
        final defaultValue = '${raw['default'] ?? ''}';
        return RemoteSettingDefinition(
          id: id,
          type: type,
          title: title,
          description: description,
          defaultValue: defaultValue.length <= maxLength
              ? defaultValue
              : defaultValue.substring(0, maxLength),
          maxLength: maxLength,
        );
      default:
        throw const FormatException('unsupported setting type');
    }
  }

  bool acceptsValue(Object? value) => switch (type) {
    'toggle' => value is bool,
    'select' =>
      value is String && options.any((option) => option.value == value),
    'slider' =>
      value is num && value.isFinite && value >= minimum && value <= maximum,
    'text' => value is String && value.length <= maxLength,
    _ => false,
  };

  Map<String, dynamic> toJson() => {
    'id': id,
    'type': type,
    'title': title,
    'description': description,
    'default': defaultValue,
    if (type == 'select')
      'options': options.map((option) => option.toJson()).toList(),
    if (type == 'slider') ...{
      'min': minimum,
      'max': maximum,
      if (divisions != null) 'steps': divisions,
    },
    if (type == 'text') 'max_length': maxLength,
  };
}

class RemoteSettingsBundle {
  final String id;
  final int revision;
  final String title;
  final String category;
  final String minAppVersion;
  final List<RemoteSettingDefinition> settings;

  const RemoteSettingsBundle({
    required this.id,
    required this.revision,
    required this.title,
    required this.category,
    required this.minAppVersion,
    required this.settings,
  });

  factory RemoteSettingsBundle.parse(dynamic raw) {
    if (raw is! Map) throw const FormatException('bundle must be an object');
    final id = '${raw['id'] ?? ''}'.trim();
    final revision = raw['revision'];
    final title = '${raw['title'] ?? ''}'.trim();
    final category = '${raw['category'] ?? ''}'.trim();
    final minAppVersion = '${raw['min_app_version'] ?? '1.2.2'}'.trim();
    final rawSettings = raw['settings'];
    if (!_validId(id) ||
        revision is! int ||
        revision < 1 ||
        title.isEmpty ||
        title.length > 100 ||
        !const {'network', 'appearance'}.contains(category) ||
        rawSettings is! List ||
        rawSettings.isEmpty ||
        rawSettings.length > 30) {
      throw const FormatException('invalid settings bundle');
    }
    final settings = rawSettings.map(RemoteSettingDefinition.parse).toList();
    if (settings.map((setting) => setting.id).toSet().length !=
        settings.length) {
      throw const FormatException('duplicate setting id');
    }
    return RemoteSettingsBundle(
      id: id,
      revision: revision,
      title: title,
      category: category,
      minAppVersion: minAppVersion,
      settings: List.unmodifiable(settings),
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'revision': revision,
    'title': title,
    'category': category,
    'min_app_version': minAppVersion,
    'settings': settings.map((setting) => setting.toJson()).toList(),
  };
}

class RemoteSettingsService {
  RemoteSettingsService._();
  static final RemoteSettingsService instance = RemoteSettingsService._();

  static const _bundlesKey = 'gc_ota_settings_bundles_v1';
  static const _valuesKey = 'gc_ota_settings_values_v1';

  final ValueNotifier<int> revisionNotifier = ValueNotifier(0);
  Map<String, RemoteSettingsBundle> _bundles = {};
  Map<String, Object?> _values = {};
  Future<void>? _refreshInFlight;
  Future<void> _valueWrites = Future<void>.value();
  bool _loaded = false;
  String _clientVersion = '0.0.0';

  List<RemoteSettingsBundle> get bundles =>
      _bundles.values.toList()..sort((a, b) => a.id.compareTo(b.id));

  List<RemoteSettingsBundle> bundlesForCategory(String category) => bundles
      .where(
        (bundle) =>
            bundle.category == category &&
            _versionAtLeast(_clientVersion, bundle.minAppVersion),
      )
      .toList(growable: false);

  String searchableTextForCategory(String category) =>
      bundlesForCategory(category)
          .expand((bundle) sync* {
            yield bundle.title;
            for (final setting in bundle.settings) {
              yield setting.title;
              yield setting.description;
            }
          })
          .join(' ');

  Object? valueFor(
    RemoteSettingsBundle bundle,
    RemoteSettingDefinition setting,
  ) {
    final value = _values[_valueKey(bundle, setting)];
    return setting.acceptsValue(value) ? value : setting.defaultValue;
  }

  /// Read a persisted OTA setting from existing app logic. New definitions can
  /// only affect behavior when the installed APK already consumes this ID.
  Object? valueForIds(String bundleId, String settingId, {Object? fallback}) {
    final bundle = _bundles[bundleId];
    if (bundle == null ||
        !_versionAtLeast(_clientVersion, bundle.minAppVersion)) {
      return fallback;
    }
    for (final setting in bundle.settings) {
      if (setting.id == settingId) return valueFor(bundle, setting);
    }
    return fallback;
  }

  Future<void> loadLocal() async {
    if (_loaded) return;
    _loaded = true;
    try {
      _clientVersion = await GhostChatAppVersion.current();
      final prefs = await SharedPreferences.getInstance();
      final rawBundles = prefs.getString(_bundlesKey);
      if (rawBundles != null) {
        final decoded = jsonDecode(rawBundles);
        if (decoded is List) {
          for (final raw in decoded) {
            try {
              final bundle = RemoteSettingsBundle.parse(raw);
              _bundles[bundle.id] = bundle;
            } catch (_) {
              // Ignore a malformed cached bundle; the server can resend it.
            }
          }
        }
      }
      final rawValues = prefs.getString(_valuesKey);
      if (rawValues != null) {
        final decoded = jsonDecode(rawValues);
        if (decoded is Map) {
          _values = Map<String, Object?>.from(decoded);
        }
      }
      revisionNotifier.value++;
    } catch (error) {
      appLog.warn('ota-settings', 'local config could not be loaded: $error');
    }
  }

  Future<void> refresh() async {
    await loadLocal();
    final running = _refreshInFlight;
    if (running != null) return running;
    final future = _refreshFromServer();
    _refreshInFlight = future;
    try {
      await future;
    } finally {
      if (identical(_refreshInFlight, future)) _refreshInFlight = null;
    }
  }

  Future<void> _refreshFromServer() async {
    try {
      final installed = bundles
          .map((bundle) => {'id': bundle.id, 'revision': bundle.revision})
          .toList(growable: false);
      final response = await HttpClient.I.dio.post(
        '/api/app-config/check',
        data: {'installed': installed},
        options: Options(
          extra: const {'skipAuth': true},
          responseType: ResponseType.json,
          headers: const {'Cache-Control': 'no-store'},
        ),
      );
      if (response.statusCode != 200 || response.data is! Map) return;
      final payload = Map<String, dynamic>.from(response.data as Map);
      if (payload['protocol'] != 1 || payload['bundles'] is! List) return;

      final next = Map<String, RemoteSettingsBundle>.from(_bundles);
      var changed = false;
      for (final raw in payload['bundles'] as List) {
        try {
          final bundle = RemoteSettingsBundle.parse(raw);
          next[bundle.id] = bundle;
          changed = true;
        } catch (error) {
          appLog.warn('ota-settings', 'ignored invalid server bundle: $error');
        }
      }
      final retired = payload['retired'];
      if (retired is List) {
        for (final id in retired.whereType<String>()) {
          changed = next.remove(id) != null || changed;
        }
      }
      if (!changed) return;

      _bundles = next;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _bundlesKey,
        jsonEncode(bundles.map((bundle) => bundle.toJson()).toList()),
      );
      revisionNotifier.value++;
    } on DioException catch (error) {
      appLog.warn('ota-settings', 'config check failed: ${error.message}');
    } catch (error, stack) {
      appLog.warn('ota-settings', 'config refresh failed: $error\n$stack');
    }
  }

  Future<void> setValue(
    RemoteSettingsBundle bundle,
    RemoteSettingDefinition setting,
    Object? value,
  ) async {
    if (!setting.acceptsValue(value)) {
      throw ArgumentError.value(value, 'value', 'invalid remote setting value');
    }
    _values[_valueKey(bundle, setting)] = value;
    revisionNotifier.value++;
    final snapshot = jsonEncode(_values);
    final write = _valueWrites.then((_) async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_valuesKey, snapshot);
    });
    _valueWrites = write.catchError((Object error) {
      appLog.warn('ota-settings', 'setting value could not be saved: $error');
    });
    await _valueWrites;
  }

  String _valueKey(
    RemoteSettingsBundle bundle,
    RemoteSettingDefinition setting,
  ) => '${bundle.id}.${setting.id}';
}

bool _validId(String value) =>
    value.isNotEmpty &&
    value.length <= 80 &&
    RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]*$').hasMatch(value);

double? _finiteNumber(dynamic value) {
  if (value is! num || !value.isFinite) return null;
  return value.toDouble();
}

bool _versionAtLeast(String current, String minimum) {
  final currentParts = _versionParts(current);
  final minimumParts = _versionParts(minimum);
  if (currentParts == null || minimumParts == null) return false;
  for (var index = 0; index < currentParts.length; index++) {
    if (currentParts[index] != minimumParts[index]) {
      return currentParts[index] > minimumParts[index];
    }
  }
  return true;
}

List<int>? _versionParts(String value) {
  final match = RegExp(
    r'^v?(\d+(?:\.\d+){0,3})(?:\+\d+)?$',
  ).firstMatch(value.trim());
  if (match == null) return null;
  final parts = match.group(1)!.split('.').map(int.tryParse).toList();
  if (parts.any((part) => part == null)) return null;
  return [...parts.cast<int>(), ...List<int>.filled(4 - parts.length, 0)];
}
